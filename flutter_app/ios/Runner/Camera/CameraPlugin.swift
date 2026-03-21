import Flutter
import UIKit
import AVFoundation
import Photos
import MetalKit
import CoreImage
import CoreLocation

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// RetroCamPlugin — iOS 相机 MethodChannel 插件
// Channel: com.retrocam.app/camera_control
//
// 与 Android 对等功能：
// - takePhoto: 使用 AVCapturePhotoOutput 高分辨率拍照（非预览帧截图）
// - saveToGallery: 保存到 DAZZ 专属相册，返回 PHAsset.localIdentifier
// - setZoom: AVCaptureDevice videoZoomFactor
// - setExposure: AVCaptureDevice exposureTargetBias
// - setFlash: AVCaptureFlashMode
// ─────────────────────────────────────────────────────────────────────────────
public class RetroCamPlugin: NSObject, FlutterPlugin {
    private static let frameImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        return cache
    }()

    private var cameraManager: CameraSessionManager?
    private var renderer: MetalRenderer?
    private var eventSink: FlutterEventSink?
    private var textureRegistry: FlutterTextureRegistry?
    private var registeredTextureId: Int64 = -1
    private var flutterAssetKeyLookup: ((String) -> String)?

    // 当前闪光灯模式
    private var currentFlashMode: AVCaptureDevice.FlashMode = .off
    private let ciContext = CIContext(options: [.priorityRequestLow: false])
    private lazy var livePhotoColorBiasKernel: CIColorKernel? = {
        CIColorKernel(source: """
        kernel vec4 livePhotoColorBias(
            __sample src,
            float biasR,
            float biasG,
            float biasB
        ) {
            vec3 color = src.rgb;
            color.r = clamp(color.r + biasR, 0.0, 1.0);
            color.g = clamp(color.g + biasG, 0.0, 1.0);
            color.b = clamp(color.b + biasB, 0.0, 1.0);
            return vec4(color, src.a);
        }
        """)
    }()
    private lazy var livePhotoToneKernel: CIColorKernel? = {
        CIColorKernel(source: """
        kernel vec4 livePhotoTone(
            __sample src,
            float highlights,
            float shadows,
            float whites,
            float blacks,
            float highlightRolloff
        ) {
            vec3 color = src.rgb;
            float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
            float hiMask = clamp((luma - 0.5) * 2.0, 0.0, 1.0);
            float shMask = clamp((0.5 - luma) * 2.0, 0.0, 1.0);
            float whMask = clamp((luma - 0.75) * 4.0, 0.0, 1.0);
            float blMask = clamp((0.25 - luma) * 4.0, 0.0, 1.0);
            color += hiMask * highlights * 0.01;
            color += shMask * shadows * 0.01;
            color += whMask * whites * 0.01;
            color += blMask * blacks * 0.01;
            color = clamp(color, 0.0, 1.0);

            if (highlightRolloff > 0.001) {
                float lum = dot(color, vec3(0.2126, 0.7152, 0.0722));
                float threshold = 1.0 - highlightRolloff;
                if (lum > threshold) {
                    float highlight = clamp((lum - threshold) / max(highlightRolloff, 0.0001), 0.0, 1.0);
                    float compress = 1.0 - highlight * highlight * 0.3;
                    color = clamp(color * compress, 0.0, 1.0);
                }
            }

            return vec4(color, src.a);
        }
        """)
    }()
    private lazy var livePhotoVibranceKernel: CIColorKernel? = {
        CIColorKernel(source: """
        kernel vec4 livePhotoVibrance(
            __sample src,
            float vibrance
        ) {
            vec3 color = src.rgb;
            float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
            float maxC = max(max(color.r, color.g), color.b);
            float minC = min(min(color.r, color.g), color.b);
            float sat = maxC > 0.0 ? (maxC - minC) / maxC : 0.0;
            float boost = (1.0 - sat) * vibrance * 0.02;
            color = clamp(mix(vec3(luma), color, 1.0 + boost), 0.0, 1.0);
            return vec4(color, src.a);
        }
        """)
    }()
    private var cachedPresetJson: [String: Any] = [:]
    private var cachedPresetShaderParams: [String: Any] = [:]
    private var cachedRenderParams: [String: Any] = [:]
    private var cachedLensParams: [String: Any] = [:]
    private var cachedZoom: Double = 1.0
    private var cachedRenderVersion: Int = 0
    private var currentCameraId: String = ""
    private var currentSharpenLevel: Float = 0.5
    private var mirrorFrontCameraEnabled = true
    private var mirrorBackCameraEnabled = false

    // takePhoto 的回调（等待 AVCapturePhotoCaptureDelegate）
    private var pendingPhotoResult: FlutterResult?
    private var runtimeStatsTimer: Timer?

    // Metal Compute 成片处理器（懒加载，首次使用时初始化）
    private lazy var captureProcessor: CaptureProcessor? = CaptureProcessor()

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.retrocam.app/camera_control",
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: "com.retrocam.app/camera_events",
            binaryMessenger: registrar.messenger()
        )

        let instance = RetroCamPlugin()
        instance.textureRegistry = registrar.textures()
        instance.flutterAssetKeyLookup = { registrar.lookupKey(forAsset: $0) }

        registrar.addMethodCallDelegate(instance, channel: channel)
        eventChannel.setStreamHandler(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initCamera":
            handleInitCamera(call: call, result: result)
        case "startPreview":
            cameraManager?.startSession()
            reapplyRuntimeStateToRenderer()
            scheduleRendererStateReplay(reason: "startPreview")
            result(nil)
        case "stopPreview":
            cameraManager?.stopSession()
            result(nil)
        case "setPreset":
            handleSetPreset(call: call, result: result)
        case "updateRenderParams":
            handleUpdateRenderParams(call: call, result: result)
        case "takePhoto":
            handleTakePhoto(call: call, result: result)
        case "captureLivePhoto":
            handleCaptureLivePhoto(call: call, result: result)
        case "saveLivePhoto":
            handleSaveLivePhoto(call: call, result: result)
        case "startRecording":
            result(["success": false, "reason": "not_implemented"])
        case "stopRecording":
            result(["filePath": NSNull()])
        case "switchLens":
            handleSwitchLens(call: call, result: result)
        case "setFlash":
            handleSetFlash(call: call, result: result)
        case "setZoom":
            handleSetZoom(call: call, result: result)
        case "setExposure":
            handleSetExposure(call: call, result: result)
        case "setFocus":
            handleSetFocus(call: call, result: result)
        case "setMirrorFrontCamera":
            handleSetMirrorFrontCamera(call: call, result: result)
        case "setMirrorBackCamera":
            handleSetMirrorBackCamera(call: call, result: result)
        case "setWhiteBalance":
            handleSetWhiteBalance(call: call, result: result)
        case "setSharpen":
            handleSetSharpen(call: call, result: result)
        case "updateViewportRatio":
            result([
                "applied": false,
                "platform": "ios",
            ])
        case "updateLensParams":
            handleUpdateLensParams(call: call, result: result)
        case "syncRuntimeState":
            handleSyncRuntimeState(call: call, result: result)
        case "syncCameraState":
            handleSyncCameraState(call: call, result: result)
        case "saveToGallery":
            handleSaveToGallery(call: call, result: result)
        case "processWithGpu":
            handleProcessWithGpu(call: call, result: result)
        case "composeOverlay":
            handleComposeOverlay(call: call, result: result)
        case "blendDoubleExposure":
            handleBlendDoubleExposure(call: call, result: result)
        case "dispose":
            handleDispose(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // ─────────────────────────────────────────────
    // initCamera
    // ─────────────────────────────────────────────
    private func handleInitCamera(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        let lensStr = args?["lens"] as? String ?? "back"
        let resolutionStr = args?["resolution"] as? String ?? "720p"
        let lens: AVCaptureDevice.Position = (lensStr == "front") ? .front : .back
        let previewPreset: AVCaptureSession.Preset =
            (resolutionStr == "1080p") ? .hd1920x1080 : .hd1280x720

        // 释放旧资源
        cameraManager?.stopSession()
        if registeredTextureId != -1 {
            textureRegistry?.unregisterTexture(registeredTextureId)
        }

        cameraManager = CameraSessionManager()
        cameraManager?.setMirrorEnabled(mirrorFrontCameraEnabled, for: .front)
        cameraManager?.setMirrorEnabled(mirrorBackCameraEnabled, for: .back)
        renderer = MetalRenderer(registry: textureRegistry!)
        renderer?.assetLookup = { [weak self] raw in
            guard let self else { return nil }
            return self.flutterAssetKeyLookup?(raw)
        }

        // 向 Flutter 注册 Texture
        let textureId = textureRegistry!.register(renderer!)
        registeredTextureId = textureId
        renderer?.setTextureId(textureId)

        // 设置帧回调并启动相机会话
        cameraManager?.sampleBufferDelegate = renderer!
        cameraManager?.configure(lens: lens, resolution: previewPreset)
        cameraManager?.startSession()
        reapplyRuntimeStateToRenderer()
        startRuntimeStatsTimer()
        let d = UIDevice.current
        emitEvent(type: "onCameraReady", payload: [
            "cameraId": lensStr,
            "sensorSize": "?",
            "sensorMp": "0.0",
            "focalLengths": "?",
            "facing": lensStr,
            "brand": "apple",
            "model": d.model,
            "device": d.name,
            "supportsLivePhoto": cameraManager?.supportsLivePhotoCapture ?? false
        ])

        result(["textureId": textureId])
    }

    // ─────────────────────────────────────────────
    // switchLens
    // ─────────────────────────────────────────────
    private func handleSwitchLens(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        let lensStr = args?["lens"] as? String ?? "back"
        let position: AVCaptureDevice.Position = (lensStr == "front") ? .front : .back
        cameraManager?.switchCamera(to: position)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.reapplyRuntimeStateToRenderer()
        }
        result(nil)
    }

    // ─────────────────────────────────────────────
    // setPreset
    // ─────────────────────────────────────────────
    private func cachePreset(_ presetJson: [String: Any]) -> (cameraId: String, shaderParams: [String: Any]) {
        let cameraId = (presetJson["cameraId"] as? String) ?? (presetJson["id"] as? String) ?? ""
        let cameraChanged = !cameraId.isEmpty && cameraId != currentCameraId
        if cameraChanged {
            cachedRenderParams = [:]
            cachedLensParams = [:]
            cachedRenderVersion = 0
        }
        if !cameraId.isEmpty {
            currentCameraId = cameraId
        }
        cachedPresetJson = presetJson
        let shaderParams = buildShaderParams(from: presetJson)
        cachedPresetShaderParams = shaderParams
        return (cameraId, shaderParams)
    }

    private func handleSetPreset(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let presetJson = args["preset"] as? [String: Any] else {
            result(FlutterError(code: "INVALID_ARG", message: "Invalid preset parameters", details: nil))
            return
        }
        let (_, shaderParams) = cachePreset(presetJson)
        renderer?.updateParams(shaderParams)
        result(["success": true])
    }

    // ─────────────────────────────────────────────
    // updateRenderParams — update shader params only
    // ─────────────────────────────────────────────
    private func handleUpdateRenderParams(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        let params = args?["params"] as? [String: Any] ?? [:]
        let version = (args?["version"] as? Int) ?? cachedRenderVersion
        if !params.isEmpty {
            cachedRenderParams = params
        }
        cachedRenderVersion = max(0, version)
        renderer?.updateParams(params)
        result([
            "success": true,
            "appliedVersion": cachedRenderVersion,
            "rendererReady": renderer != nil,
        ])
    }

    // ─────────────────────────────────────────────
    // setFlash
    // ─────────────────────────────────────────────
    private func handleSetFlash(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        let modeStr = args?["mode"] as? String ?? "off"
        switch modeStr {
        case "on":   currentFlashMode = .on
        case "auto": currentFlashMode = .auto
        default:     currentFlashMode = .off
        }
        result(nil)
    }

    // ─────────────────────────────────────────────
    // setZoom — 与 Android CameraX 对等
    // ─────────────────────────────────────────────
    private func handleSetZoom(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        guard let zoomRatio = args?["zoom"] as? Double else {
            result(nil)
            return
        }
        cameraManager?.setZoom(factor: CGFloat(zoomRatio))
        result(nil)
    }

    // ─────────────────────────────────────────────
    // setExposure — 与 Android CameraX 对等
    // ─────────────────────────────────────────────
    private func handleSetExposure(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        guard let ev = args?["ev"] as? Double else {
            result(nil)
            return
        }
        cameraManager?.setExposure(bias: Float(ev))
        result(nil)
    }

    // ─────────────────────────────────────────────
    // setFocus — 点击对焦 + 对焦点曝光（与 Android CameraX FocusMeteringAction 对等）
    // x, y: 归一化坐标 [0, 1]，原点在左上角
    // ─────────────────────────────────────────────
    private func handleSetFocus(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        guard let x = args?["x"] as? Double,
              let y = args?["y"] as? Double else {
            result(nil)
            return
        }
        cameraManager?.setFocusAndExposure(x: CGFloat(x), y: CGFloat(y))
        result(nil)
    }

    private func handleSetMirrorFrontCamera(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        mirrorFrontCameraEnabled = args?["enabled"] as? Bool ?? true
        cameraManager?.setMirrorEnabled(mirrorFrontCameraEnabled, for: .front)
        result(nil)
    }

    private func handleSetMirrorBackCamera(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        mirrorBackCameraEnabled = args?["enabled"] as? Bool ?? false
        cameraManager?.setMirrorEnabled(mirrorBackCameraEnabled, for: .back)
        result(nil)
    }

    // ─────────────────────────────────────────────
    // setWhiteBalance — 与 Android CameraX AWB 对等
    // ─────────────────────────────────────────────
    private func handleSetWhiteBalance(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        let mode = args?["mode"] as? String ?? "auto"
        let tempK = args?["tempK"] as? Int ?? 5500
        cameraManager?.setWhiteBalance(mode: mode, tempK: tempK)
        result(nil)
    }

    // ─────────────────────────────────────────────
    // setSharpen — 分辨率切换 + Metal shader unsharp mask
    // level: 0.0=低(720p/2MP), 0.5=中(1080p/8MP), 1.0=高(.photo/全像素)
    // 与 Android handleSetSharpen 对等：同时切换分辨率 + GPU 锐化强度
    // ─────────────────────────────────────────────
    private func handleSetSharpen(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        let level = args?["level"] as? Double ?? 0.5
        let floatLevel = Float(level)
        currentSharpenLevel = floatLevel
        // 1. 更新 Metal shader 中的 Unsharp Mask 强度
        renderer?.setSharpen(floatLevel)
        // 2. 动态切换 AVCaptureSession.sessionPreset（影响实际拍摄分辨率）
        // CRITICAL FIX: call result(nil) only AFTER sessionPreset is committed.
        // Previously result(nil) was called immediately, causing Flutter's takePhoto
        // to run before the new sessionPreset was applied — resulting in 2MP output.
        if let mgr = cameraManager {
            mgr.setResolution(level: floatLevel) {
                self.scheduleRendererStateReplay(reason: "setSharpen")
                result(nil)
            }
        } else {
            result(nil)
        }
    }

    // ─────────────────────────────────────────────
    // updateLensParams — 镜头参数（畸变/暗角/缩放/鱼眼模式）
    // ─────────────────────────────────────────────
    private func handleUpdateLensParams(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        let fisheyeMode           = args?["fisheyeMode"] as? Bool ?? false
        let circularFisheye       = args?["circularFisheye"] as? Bool ?? fisheyeMode
        let vignette              = args?["vignette"] as? Double ?? 0.0
        let chromaticAberration   = args?["chromaticAberration"] as? Double ?? 0.0
        let bloom                 = args?["bloom"] as? Double ?? 0.0
        let softFocus             = args?["softFocus"] as? Double ?? 0.0
        let distortion            = args?["distortion"] as? Double ?? 0.0
        cachedLensParams = [
            "fisheyeMode": fisheyeMode,
            "circularFisheye": circularFisheye,
            "vignette": vignette,
            "chromaticAberration": chromaticAberration,
            "bloom": bloom,
            "softFocus": softFocus,
            "distortion": distortion,
        ]

        // 将鱼眼模式传递到 Metal 渲染器
        renderer?.setFisheyeMode(fisheyeMode)
        renderer?.setCircularFisheye(circularFisheye)

        // ── FIX: 将所有镜头参数传递到 Metal 渲染器（之前只传了 vignette）──
        if let r = renderer {
            var p = r.getCCDParams()
            p.vignetteAmount = Float(vignette)
            p.chromaticAberration = Float(chromaticAberration)
            p.bloomAmount = Float(bloom)
            p.lensDistortion = Float(distortion)
            p.circularFisheye = circularFisheye ? 1.0 : 0.0
            // softFocus 暂未下沉到 Metal uniform（由统一 renderParams 管线兜底）
            r.setCCDParams(p)
        }
        result(nil)
    }

    // ─────────────────────────────────────────────
    // syncRuntimeState — 一次性同步镜头参数 + 渲染参数 + 缩放
    // ─────────────────────────────────────────────
    private func handleSyncRuntimeState(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        let lens = args?["lensParams"] as? [String: Any] ?? [:]
        let render = args?["renderParams"] as? [String: Any] ?? [:]
        let zoom = (args?["zoom"] as? Double) ?? 1.0
        let version = (args?["version"] as? Int) ?? cachedRenderVersion

        let fisheyeMode = lens["fisheyeMode"] as? Bool ?? false
        let circularFisheye = lens["circularFisheye"] as? Bool ?? fisheyeMode
        let vignette = lens["vignette"] as? Double ?? 0.0
        let chromaticAberration = lens["chromaticAberration"] as? Double ?? 0.0
        let bloom = lens["bloom"] as? Double ?? 0.0
        let softFocus = lens["softFocus"] as? Double ?? 0.0
        let distortion = lens["distortion"] as? Double ?? 0.0
        cachedLensParams = lens
        cachedRenderParams = render
        cachedZoom = zoom
        cachedRenderVersion = max(0, version)

        cameraManager?.setZoom(factor: CGFloat(zoom))
        renderer?.setFisheyeMode(fisheyeMode)
        renderer?.setCircularFisheye(circularFisheye)

        var merged = render
        merged["vignette"] = Float(vignette)
        merged["chromaticAberration"] = Float(chromaticAberration)
        merged["bloomAmount"] = Float(bloom)
        merged["softFocus"] = Float(softFocus)
        merged["distortion"] = Float(distortion)
        merged["circularFisheye"] = circularFisheye ? 1.0 : 0.0
        renderer?.updateParams(merged)
        result([
            "appliedVersion": cachedRenderVersion,
            "rendererReady": renderer != nil,
        ])
    }

    private func handleSyncCameraState(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        let preset = args?["preset"] as? [String: Any]
        let lens = args?["lensParams"] as? [String: Any] ?? [:]
        let render = args?["renderParams"] as? [String: Any] ?? [:]
        let zoom = (args?["zoom"] as? Double) ?? 1.0
        let version = (args?["version"] as? Int) ?? cachedRenderVersion

        let presetParams: [String: Any]
        let cameraId: String
        if let preset {
            let cached = cachePreset(preset)
            cameraId = cached.cameraId
            presetParams = cached.shaderParams
        } else {
            cameraId = currentCameraId
            presetParams = cachedPresetShaderParams
        }

        let fisheyeMode = lens["fisheyeMode"] as? Bool ?? false
        let circularFisheye = lens["circularFisheye"] as? Bool ?? fisheyeMode
        let vignette = lens["vignette"] as? Double ?? 0.0
        let chromaticAberration = lens["chromaticAberration"] as? Double ?? 0.0
        let bloom = lens["bloom"] as? Double ?? 0.0
        let softFocus = lens["softFocus"] as? Double ?? 0.0
        let distortion = lens["distortion"] as? Double ?? 0.0
        cachedLensParams = lens
        cachedRenderParams = render
        cachedZoom = zoom
        cachedRenderVersion = max(0, version)

        cameraManager?.setZoom(factor: CGFloat(zoom))
        renderer?.setFisheyeMode(fisheyeMode)
        renderer?.setCircularFisheye(circularFisheye)

        var merged = presetParams
        merged.merge(render) { _, new in new }
        merged["vignette"] = Float(vignette)
        merged["chromaticAberration"] = Float(chromaticAberration)
        merged["bloomAmount"] = Float(bloom)
        merged["softFocus"] = Float(softFocus)
        merged["distortion"] = Float(distortion)
        merged["circularFisheye"] = circularFisheye ? 1.0 : 0.0
        if !cameraId.isEmpty {
            merged["cameraId"] = cameraId
        }
        renderer?.updateParams(merged)
        result([
            "appliedVersion": cachedRenderVersion,
            "rendererReady": renderer != nil,
        ])
    }

    // ─────────────────────────────────────────────
    // takePhoto — 使用 AVCapturePhotoOutput 高分辨率拍照
    // 与 Android CameraX takePicture 对等
    // ─────────────────────────────────────────────
    private func handleTakePhoto(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let cameraManager = cameraManager else {
            result(FlutterError(code: "NOT_READY", message: "Camera not initialized", details: nil))
            return
        }
        let args = call.arguments as? [String: Any]
        let deviceQuarter = (args?["deviceQuarter"] as? Int) ?? 0
        let latitude = args?["latitude"] as? Double
        let longitude = args?["longitude"] as? Double
        let assetLocation =
            (latitude != nil && longitude != nil)
                ? CLLocation(latitude: latitude!, longitude: longitude!)
                : nil

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let fileName = "DAZZ_\(timestamp).jpg"
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dazz_captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let fileURL = cacheDir.appendingPathComponent(fileName)

        cameraManager.capturePhoto(
            flashMode: currentFlashMode,
            deviceQuarter: deviceQuarter
        ) { [weak self] imageData in
            guard let data = imageData else {
                DispatchQueue.main.async {
                    self?.reapplyRuntimeStateToRenderer()
                    result(FlutterError(code: "CAPTURE_FAILED", message: "Failed to capture photo", details: nil))
                }
                return
            }
            do {
                try data.write(to: fileURL)
                DispatchQueue.main.async {
                    self?.reapplyRuntimeStateToRenderer()
                    result(["filePath": fileURL.path])
                }
            } catch {
                DispatchQueue.main.async {
                    self?.reapplyRuntimeStateToRenderer()
                    result(FlutterError(code: "WRITE_FAILED", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func handleCaptureLivePhoto(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let cameraManager = cameraManager else {
            result(FlutterError(code: "NOT_READY", message: "Camera not initialized", details: nil))
            return
        }
        guard cameraManager.supportsLivePhotoCapture else {
            result(FlutterError(code: "NOT_SUPPORTED", message: "Live Photo not supported", details: nil))
            return
        }
        let args = call.arguments as? [String: Any]
        let deviceQuarter = (args?["deviceQuarter"] as? Int) ?? 0

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let fileName = "DAZZ_\(timestamp).jpg"
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dazz_captures", isDirectory: true)
        let movieDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dazz_live_photo", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: movieDir, withIntermediateDirectories: true)
        let fileURL = cacheDir.appendingPathComponent(fileName)
        let movieURL = movieDir.appendingPathComponent("DAZZ_LIVE_\(timestamp).mov")

        cameraManager.captureLivePhoto(
            flashMode: currentFlashMode,
            deviceQuarter: deviceQuarter,
            movieURL: movieURL
        ) { [weak self] imageData, pairedMovieURL in
            guard let self else { return }
            guard let data = imageData, let liveMovieURL = pairedMovieURL else {
                DispatchQueue.main.async {
                    self.reapplyRuntimeStateToRenderer()
                    result(FlutterError(code: "CAPTURE_FAILED", message: "Failed to capture live photo", details: nil))
                }
                return
            }
            do {
                try data.write(to: fileURL)
            } catch {
                DispatchQueue.main.async {
                    self.reapplyRuntimeStateToRenderer()
                    result(FlutterError(code: "WRITE_FAILED", message: error.localizedDescription, details: nil))
                }
                return
            }

            DispatchQueue.main.async {
                self.reapplyRuntimeStateToRenderer()
                result([
                    "filePath": fileURL.path,
                    "videoPath": liveMovieURL.path,
                ])
            }
        }
    }

    private func handleSaveLivePhoto(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let imagePath = args["imagePath"] as? String,
              let videoPath = args["videoPath"] as? String else {
            result(FlutterError(code: "INVALID_ARG", message: "imagePath and videoPath required", details: nil))
            return
        }
        let latitude = args["latitude"] as? Double
        let longitude = args["longitude"] as? Double
        let renderParams = args["renderParams"] as? [String: Any]
        let assetLocation =
            (latitude != nil && longitude != nil)
                ? CLLocation(latitude: latitude!, longitude: longitude!)
                : nil
        let imageURL = URL(fileURLWithPath: imagePath)
        let videoURL = URL(fileURLWithPath: videoPath)

        guard FileManager.default.fileExists(atPath: imagePath) else {
            result(FlutterError(code: "FILE_NOT_FOUND", message: "Image not found: \(imagePath)", details: nil))
            return
        }
        guard FileManager.default.fileExists(atPath: videoPath) else {
            result(FlutterError(code: "FILE_NOT_FOUND", message: "Video not found: \(videoPath)", details: nil))
            return
        }

        PHPhotoLibrary.requestAuthorization { status in
            let isGranted: Bool
            if #available(iOS 14, *) {
                isGranted = (status == .authorized || status == .limited)
            } else {
                isGranted = (status == .authorized)
            }
            guard isGranted else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "PERMISSION_DENIED", message: "Photo library access denied", details: nil))
                }
                return
            }

            self.prepareLivePhotoVideoForSaving(
                imageURL: imageURL,
                videoURL: videoURL,
                renderParams: renderParams
            ) { preparedVideoURL in
                var assetPlaceholder: PHObjectPlaceholder?
                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    request.location = assetLocation
                    request.addResource(with: .photo, fileURL: imageURL, options: options)
                    request.addResource(with: .pairedVideo, fileURL: preparedVideoURL, options: options)
                    assetPlaceholder = request.placeholderForCreatedAsset

                    let fetchOptions = PHFetchOptions()
                    fetchOptions.predicate = NSPredicate(format: "title = %@", "DAZZ")
                    let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: fetchOptions)
                    if let album = albums.firstObject,
                       let placeholder = assetPlaceholder,
                       let addRequest = PHAssetCollectionChangeRequest(for: album) {
                        addRequest.addAssets([placeholder] as NSFastEnumeration)
                    }
                }) { success, error in
                    let cleanup = {
                        try? FileManager.default.removeItem(at: imageURL)
                        try? FileManager.default.removeItem(at: videoURL)
                        if preparedVideoURL != videoURL {
                            try? FileManager.default.removeItem(at: preparedVideoURL)
                        }
                    }
                    if !success {
                        cleanup()
                        DispatchQueue.main.async {
                            result(FlutterError(code: "SAVE_FAILED", message: error?.localizedDescription, details: nil))
                        }
                        return
                    }

                    guard let localId = assetPlaceholder?.localIdentifier else {
                        cleanup()
                        DispatchQueue.main.async {
                            result(["success": true, "uri": ""])
                        }
                        return
                    }

                    let fetchOptions = PHFetchOptions()
                    fetchOptions.predicate = NSPredicate(format: "title = %@", "DAZZ")
                    let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: fetchOptions)
                    if albums.firstObject != nil {
                        cleanup()
                        DispatchQueue.main.async {
                            result(["success": true, "uri": localId])
                        }
                        return
                    }

                    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil)
                    guard let asset = assets.firstObject else {
                        cleanup()
                        DispatchQueue.main.async {
                            result(["success": true, "uri": localId])
                        }
                        return
                    }

                    PHPhotoLibrary.shared().performChanges({
                        _ = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "DAZZ")
                    }) { _, _ in
                        let albums2 = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: fetchOptions)
                        if let album = albums2.firstObject {
                            PHPhotoLibrary.shared().performChanges({
                                if let addRequest = PHAssetCollectionChangeRequest(for: album) {
                                    addRequest.addAssets([asset] as NSFastEnumeration)
                                }
                            }) { _, _ in
                                cleanup()
                                DispatchQueue.main.async {
                                    result(["success": true, "uri": localId])
                                }
                            }
                        } else {
                            cleanup()
                            DispatchQueue.main.async {
                                result(["success": true, "uri": localId])
                            }
                        }
                    }
                }
            }
        }
    }

    private func prepareLivePhotoVideoForSaving(
        imageURL: URL,
        videoURL: URL,
        renderParams: [String: Any]?,
        completion: @escaping (URL) -> Void
    ) {
        guard let image = UIImage(contentsOfFile: imageURL.path),
              image.size.width > 0,
              image.size.height > 0 else {
            self.applyLivePhotoVideoEffectsIfNeeded(
                videoURL: videoURL,
                renderParams: renderParams,
                completion: completion
            )
            return
        }

        let targetAspect = image.size.width / image.size.height
        let asset = AVURLAsset(url: videoURL)
        guard let sourceVideoTrack = asset.tracks(withMediaType: .video).first else {
            completion(videoURL)
            return
        }

        let transformedSize = sourceVideoTrack.naturalSize.applying(sourceVideoTrack.preferredTransform)
        let orientedSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
        guard orientedSize.width > 0, orientedSize.height > 0 else {
            completion(videoURL)
            return
        }

        let sourceAspect = orientedSize.width / orientedSize.height
        if abs(sourceAspect - targetAspect) < 0.01 {
            self.applyLivePhotoVideoEffectsIfNeeded(
                videoURL: videoURL,
                renderParams: renderParams,
                completion: completion
            )
            return
        }

        let renderSize: CGSize
        if sourceAspect > targetAspect {
            renderSize = CGSize(width: orientedSize.height * targetAspect, height: orientedSize.height)
        } else {
            renderSize = CGSize(width: orientedSize.width, height: orientedSize.width / targetAspect)
        }

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            completion(videoURL)
            return
        }

        do {
            try compositionVideoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: asset.duration),
                of: sourceVideoTrack,
                at: .zero
            )
            if let sourceAudioTrack = asset.tracks(withMediaType: .audio).first,
               let compositionAudioTrack = composition.addMutableTrack(
                   withMediaType: .audio,
                   preferredTrackID: kCMPersistentTrackID_Invalid
               ) {
                try compositionAudioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: asset.duration),
                    of: sourceAudioTrack,
                    at: .zero
                )
            }
        } catch {
            print("[CameraPlugin] prepareLivePhotoVideoForSaving insert failed: \(error)")
            completion(videoURL)
            return
        }

        let xScale = renderSize.width / orientedSize.width
        let yScale = renderSize.height / orientedSize.height
        let scale = max(xScale, yScale)
        let scaledSize = CGSize(width: orientedSize.width * scale, height: orientedSize.height * scale)
        let tx = (renderSize.width - scaledSize.width) * 0.5
        let ty = (renderSize.height - scaledSize.height) * 0.5

        var finalTransform = sourceVideoTrack.preferredTransform
        finalTransform = finalTransform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        finalTransform = finalTransform.concatenating(
            CGAffineTransform(translationX: tx / scale, y: ty / scale)
        )

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
        layerInstruction.setTransform(finalTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = CGSize(
            width: max(1, round(renderSize.width)),
            height: max(1, round(renderSize.height))
        )
        let nominalFrameRate = sourceVideoTrack.nominalFrameRate
        if nominalFrameRate > 0 {
            videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(nominalFrameRate.rounded()))
        } else {
            videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dazz_live_photo_processed", isDirectory: true)
            .appendingPathComponent("DAZZ_LIVE_PROCESSED_\(Int(Date().timeIntervalSince1970 * 1000)).mov")
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputURL)

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            completion(videoURL)
            return
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = false
        exportSession.exportAsynchronously {
            switch exportSession.status {
            case .completed:
                self.applyLivePhotoVideoEffectsIfNeeded(
                    videoURL: outputURL,
                    renderParams: renderParams,
                    completion: completion
                )
            case .failed, .cancelled:
                print("[CameraPlugin] prepareLivePhotoVideoForSaving export failed: \(exportSession.error?.localizedDescription ?? "unknown")")
                try? FileManager.default.removeItem(at: outputURL)
                self.applyLivePhotoVideoEffectsIfNeeded(
                    videoURL: videoURL,
                    renderParams: renderParams,
                    completion: completion
                )
            default:
                self.applyLivePhotoVideoEffectsIfNeeded(
                    videoURL: videoURL,
                    renderParams: renderParams,
                    completion: completion
                )
            }
        }
    }

    private func applyLivePhotoVideoEffectsIfNeeded(
        videoURL: URL,
        renderParams: [String: Any]?,
        completion: @escaping (URL) -> Void
    ) {
        guard let renderParams,
              shouldApplyLivePhotoVideoEffects(renderParams: renderParams) else {
            completion(videoURL)
            return
        }

        let asset = AVURLAsset(url: videoURL)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dazz_live_photo_effects", isDirectory: true)
            .appendingPathComponent("DAZZ_LIVE_EFFECT_\(Int(Date().timeIntervalSince1970 * 1000)).mov")
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputURL)

        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            completion(videoURL)
            return
        }

        let ciContext = self.ciContext
        let videoComposition = AVVideoComposition(asset: asset) { request in
            autoreleasepool {
                let image = self.applyLivePhotoFilters(
                    to: request.sourceImage,
                    renderParams: renderParams
                )
                let cropped = image.cropped(to: request.sourceImage.extent)
                request.finish(with: cropped, context: ciContext)
            }
        }
        if let track = asset.tracks(withMediaType: .video).first {
            let nominalFrameRate = track.nominalFrameRate
            if nominalFrameRate > 0 {
                videoComposition.frameDuration = CMTime(
                    value: 1,
                    timescale: CMTimeScale(nominalFrameRate.rounded())
                )
            }
            let transformedSize = track.naturalSize.applying(track.preferredTransform)
            videoComposition.renderSize = CGSize(
                width: max(1, abs(transformedSize.width)),
                height: max(1, abs(transformedSize.height))
            )
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = false
        exportSession.exportAsynchronously {
            switch exportSession.status {
            case .completed:
                if outputURL != videoURL {
                    try? FileManager.default.removeItem(at: videoURL)
                }
                completion(outputURL)
            case .failed, .cancelled:
                print("[CameraPlugin] applyLivePhotoVideoEffectsIfNeeded export failed: \(exportSession.error?.localizedDescription ?? "unknown")")
                try? FileManager.default.removeItem(at: outputURL)
                completion(videoURL)
            default:
                try? FileManager.default.removeItem(at: outputURL)
                completion(videoURL)
            }
        }
    }

    private func shouldApplyLivePhotoVideoEffects(renderParams: [String: Any]) -> Bool {
        func value(_ key: String) -> Double {
            return (renderParams[key] as? NSNumber)?.doubleValue ?? 0.0
        }
        return abs(value("exposureOffset")) > 0.01 ||
            abs(value("contrast") - 1.0) > 0.01 ||
            abs(value("saturation") - 1.0) > 0.01 ||
            abs(value("highlights")) > 0.01 ||
            abs(value("shadows")) > 0.01 ||
            abs(value("whites")) > 0.01 ||
            abs(value("blacks")) > 0.01 ||
            abs(value("clarity")) > 0.01 ||
            abs(value("temperatureShift")) > 0.01 ||
            abs(value("tintShift")) > 0.01 ||
            abs(value("colorBiasR")) > 0.001 ||
            abs(value("colorBiasG")) > 0.001 ||
            abs(value("colorBiasB")) > 0.001 ||
            abs(value("highlightRolloff")) > 0.01 ||
            abs(value("vignetteAmount")) > 0.01 ||
            abs(value("bloomAmount")) > 0.01 ||
            abs(value("softFocus")) > 0.01 ||
            abs(value("vibrance")) > 0.01 ||
            abs(value("sharpen")) > 0.01
    }

    private func applyLivePhotoFilters(
        to sourceImage: CIImage,
        renderParams: [String: Any]
    ) -> CIImage {
        func value(_ key: String, _ fallback: Double = 0.0) -> Double {
            return (renderParams[key] as? NSNumber)?.doubleValue ?? fallback
        }

        var image = sourceImage

        let exposure = Float(value("exposureOffset"))
        if abs(exposure) > 0.01,
           let filter = CIFilter(name: "CIExposureAdjust") {
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(exposure, forKey: kCIInputEVKey)
            image = filter.outputImage ?? image
        }

        let temperatureShift = value("temperatureShift")
        let tintShift = value("tintShift")
        if abs(temperatureShift) > 0.01 || abs(tintShift) > 0.01,
           let filter = CIFilter(name: "CITemperatureAndTint") {
            let neutral = CIVector(x: 6500, y: 0)
            let target = CIVector(
                x: CGFloat((6500 + temperatureShift * 35.0).clamped(to: 2500...9500)),
                y: CGFloat((tintShift * 1.2).clamped(to: -150...150))
            )
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(neutral, forKey: "inputNeutral")
            filter.setValue(target, forKey: "inputTargetNeutral")
            image = filter.outputImage ?? image
        }

        let colorBiasR = Float(value("colorBiasR"))
        let colorBiasG = Float(value("colorBiasG"))
        let colorBiasB = Float(value("colorBiasB"))
        if (abs(colorBiasR) > 0.001 ||
            abs(colorBiasG) > 0.001 ||
            abs(colorBiasB) > 0.001),
           let kernel = livePhotoColorBiasKernel {
            image = kernel.apply(
                extent: image.extent,
                arguments: [
                    image,
                    colorBiasR,
                    colorBiasG,
                    colorBiasB,
                ]
            ) ?? image
        }

        let saturation = Float(value("saturation", 1.0))
        let contrast = Float(value("contrast", 1.0))
        if abs(saturation - 1.0) > 0.01 || abs(contrast - 1.0) > 0.01,
           let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(saturation, forKey: kCIInputSaturationKey)
            filter.setValue(contrast, forKey: kCIInputContrastKey)
            filter.setValue(0.0, forKey: kCIInputBrightnessKey)
            image = filter.outputImage ?? image
        }

        let highlights = Float(value("highlights"))
        let shadows = Float(value("shadows"))
        let whites = Float(value("whites"))
        let blacks = Float(value("blacks"))
        let highlightRolloff = Float(value("highlightRolloff"))
        if (abs(highlights) > 0.01 ||
            abs(shadows) > 0.01 ||
            abs(whites) > 0.01 ||
            abs(blacks) > 0.01 ||
            abs(highlightRolloff) > 0.01),
           let kernel = livePhotoToneKernel {
            image = kernel.apply(
                extent: image.extent,
                arguments: [
                    image,
                    highlights,
                    shadows,
                    whites,
                    blacks,
                    highlightRolloff,
                ]
            ) ?? image
        }

        let clarity = value("clarity")
        if abs(clarity) > 0.5 {
            if clarity > 0,
               let filter = CIFilter(name: "CIUnsharpMask") {
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue((clarity / 80.0).clamped(to: 0.08...1.2), forKey: kCIInputIntensityKey)
                filter.setValue(1.1, forKey: kCIInputRadiusKey)
                image = filter.outputImage ?? image
            } else if let filter = CIFilter(name: "CIGaussianBlur") {
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue(abs(clarity / 85.0).clamped(to: 0.08...0.9), forKey: kCIInputRadiusKey)
                let blurred = (filter.outputImage ?? image).cropped(to: image.extent)
                image = blurred
            }
        }

        let vibrance = Float(value("vibrance"))
        if abs(vibrance) > 0.01,
           let kernel = livePhotoVibranceKernel {
            image = kernel.apply(
                extent: image.extent,
                arguments: [
                    image,
                    vibrance,
                ]
            ) ?? image
        }

        let bloomAmount = value("bloomAmount")
        let softFocus = value("softFocus")
        let bloomIntensity = Float((bloomAmount * 0.85 + softFocus * 0.55).clamped(to: 0...1))
        if bloomIntensity > 0.01,
           let filter = CIFilter(name: "CIBloom") {
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(bloomIntensity * 9.0, forKey: kCIInputRadiusKey)
            filter.setValue(bloomIntensity * 0.45, forKey: kCIInputIntensityKey)
            image = filter.outputImage ?? image
        }

        let sharpen = Float(value("sharpen"))
        if sharpen > 0.01,
           let filter = CIFilter(name: "CISharpenLuminance") {
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue((sharpen * 0.35).clamped(to: 0...0.8), forKey: kCIInputSharpnessKey)
            image = filter.outputImage ?? image
        }

        let vignetteAmount = Float(value("vignetteAmount"))
        if vignetteAmount > 0.01,
           let filter = CIFilter(name: "CIVignette") {
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(vignetteAmount * 2.1, forKey: kCIInputIntensityKey)
            filter.setValue(Float(max(sourceImage.extent.width, sourceImage.extent.height)) * 0.65, forKey: kCIInputRadiusKey)
            image = filter.outputImage ?? image
        }

        return image
    }

    // ─────────────────────────────────────────────
    // saveToGallery — 保存到 DAZZ 专属相册
    // 返回 PHAsset.localIdentifier（供 AssetEntity.fromId 使用）
    // ─────────────────────────────────────────────
    private func handleSaveToGallery(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let filePath = args["filePath"] as? String else {
            result(FlutterError(code: "INVALID_ARG", message: "filePath required", details: nil))
            return
        }
        let cameraId = args["cameraId"] as? String ?? ""
        let latitude = args["latitude"] as? Double
        let longitude = args["longitude"] as? Double
        var fileURL = URL(fileURLWithPath: filePath)

        guard FileManager.default.fileExists(atPath: filePath) else {
            result(FlutterError(code: "FILE_NOT_FOUND", message: "File not found: \(filePath)", details: nil))
            return
        }

        // 如果有 cameraId，将文件重命名为 DAZZ_{cameraId}_{timestamp}.jpg
        if !cameraId.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let timestamp = formatter.string(from: Date())
            let newName = "DAZZ_\(cameraId)_\(timestamp).jpg"
            let newURL = fileURL.deletingLastPathComponent().appendingPathComponent(newName)
            try? FileManager.default.moveItem(at: fileURL, to: newURL)
            fileURL = newURL
        }

        PHPhotoLibrary.requestAuthorization { status in
            // .limited is only available on iOS 14+
            let isGranted: Bool
            if #available(iOS 14, *) {
                isGranted = (status == .authorized || status == .limited)
            } else {
                isGranted = (status == .authorized)
            }
            guard isGranted else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "PERMISSION_DENIED", message: "Photo library access denied", details: nil))
                }
                return
            }

            var assetPlaceholder: PHObjectPlaceholder?

            PHPhotoLibrary.shared().performChanges({
                // 1. 创建图片资产
                let createRequest = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                if let latitude, let longitude {
                    createRequest?.location = CLLocation(latitude: latitude, longitude: longitude)
                }
                assetPlaceholder = createRequest?.placeholderForCreatedAsset

                // 2. 保存到 DAZZ 专属相册
                let albumTitle = "DAZZ"
                let fetchOptions = PHFetchOptions()
                fetchOptions.predicate = NSPredicate(format: "title = %@", albumTitle)
                let existingAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: fetchOptions)

                if let existingAlbum = existingAlbums.firstObject {
                    // 相册已存在，直接添加
                    if let addRequest = PHAssetCollectionChangeRequest(for: existingAlbum),
                       let placeholder = assetPlaceholder {
                        addRequest.addAssets([placeholder] as NSFastEnumeration)
                    }
                } else {
                    // 创建新相册并添加
                    let createAlbumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
                    let albumPlaceholder = createAlbumRequest.placeholderForCreatedAssetCollection
                    // 注意：新相册在同一 performChanges 块内无法立即 fetch，需要在 completionHandler 里再添加
                    // 这里先记录 albumPlaceholder，在 completionHandler 里处理
                    _ = albumPlaceholder
                }
            }) { success, error in
                if !success {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "SAVE_FAILED", message: error?.localizedDescription, details: nil))
                    }
                    return
                }

                // 3. 获取刚保存的 PHAsset localIdentifier
                guard let localId = assetPlaceholder?.localIdentifier else {
                    DispatchQueue.main.async {
                        result(["success": true, "uri": ""])
                    }
                    return
                }

                // 4. 如果相册不存在，在第二次 performChanges 里创建并添加
                let fetchOptions = PHFetchOptions()
                fetchOptions.predicate = NSPredicate(format: "title = %@", "DAZZ")
                let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: fetchOptions)

                let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil)
                guard let asset = assets.firstObject else {
                    DispatchQueue.main.async {
                        result(["success": true, "uri": localId])
                    }
                    return
                }

                if albums.firstObject == nil {
                    // 相册不存在，创建并添加
                    PHPhotoLibrary.shared().performChanges({
                        let createAlbumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "DAZZ")
                        _ = createAlbumRequest.placeholderForCreatedAssetCollection
                    }) { _, _ in
                        // 再次查找并添加
                        let albums2 = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: fetchOptions)
                        if let album = albums2.firstObject {
                            PHPhotoLibrary.shared().performChanges({
                                if let addRequest = PHAssetCollectionChangeRequest(for: album) {
                                    addRequest.addAssets([asset] as NSFastEnumeration)
                                }
                            }) { _, _ in
                                // 清理缓存文件
                                try? FileManager.default.removeItem(at: fileURL)
                                DispatchQueue.main.async {
                                    result(["success": true, "uri": localId])
                                }
                            }
                        } else {
                            try? FileManager.default.removeItem(at: fileURL)
                            DispatchQueue.main.async {
                                result(["success": true, "uri": localId])
                            }
                        }
                    }
                } else {
                    // 相册已存在，直接添加（第一次 performChanges 已添加）
                    try? FileManager.default.removeItem(at: fileURL)
                    DispatchQueue.main.async {
                        result(["success": true, "uri": localId])
                    }
                }
            }
        }
    }

    // ─────────────────────────────────────────────
    // processWithGpu — Metal Compute 成片处理
    // ─────────────────────────────────────────────
    private func handleProcessWithGpu(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let filePath = args["filePath"] as? String,
              let params = args["params"] as? [String: Any] else {
            result(FlutterError(code: "INVALID_ARG", message: "filePath and params required", details: nil))
            return
        }

        // 在后台线程执行 GPU 处理，避免阻塞主线程
        DispatchQueue.global(qos: .userInitiated).async {
            guard let processor = self.captureProcessor else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "METAL_UNAVAILABLE",
                                       message: "Metal not available on this device",
                                       details: nil))
                }
                return
            }

            let outputPath = processor.processImage(filePath: filePath, params: params)

            DispatchQueue.main.async {
                if let path = outputPath {
                    result(["filePath": path])
                } else {
                    result(FlutterError(code: "PROCESS_FAILED",
                                       message: "Metal Compute processing failed",
                                       details: nil))
                }
            }
        }
    }

    private func handleComposeOverlay(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let filePath = args["filePath"] as? String,
              let rawImage = UIImage(contentsOfFile: filePath) else {
            result(FlutterError(code: "INVALID_ARG", message: "filePath required", details: nil))
            return
        }
        let srcImage = Self.normalizedImage(rawImage)
        guard let srcCg = srcImage.cgImage else {
            result(FlutterError(code: "INVALID_ARG", message: "invalid source image", details: nil))
            return
        }

        let canvasW = max(1, Int((args["canvasWidth"] as? Double) ?? Double(srcCg.width)))
        let canvasH = max(1, Int((args["canvasHeight"] as? Double) ?? Double(srcCg.height)))
        let cropLeft = CGFloat((args["cropLeft"] as? Double) ?? 0)
        let cropTop = CGFloat((args["cropTop"] as? Double) ?? 0)
        let cropWidth = CGFloat((args["cropWidth"] as? Double) ?? Double(srcCg.width))
        let cropHeight = CGFloat((args["cropHeight"] as? Double) ?? Double(srcCg.height))
        let imageLeft = CGFloat((args["imageLeft"] as? Double) ?? 0)
        let imageTop = CGFloat((args["imageTop"] as? Double) ?? 0)
        let imageWidth = CGFloat((args["imageWidth"] as? Double) ?? Double(canvasW))
        let imageHeight = CGFloat((args["imageHeight"] as? Double) ?? Double(canvasH))
        let frameAssetPath = (args["frameAssetPath"] as? String) ?? ""
        let frameAssetBytes = (args["frameAssetBytes"] as? FlutterStandardTypedData)?.data
        var frameImageFromBytes: UIImage? = nil
        if let bytes = frameAssetBytes, !bytes.isEmpty {
            frameImageFromBytes = UIImage(data: bytes)
        }
        if !frameAssetPath.isEmpty && frameImageFromBytes == nil {
            guard let fullPath = resolveFlutterAssetPath(frameAssetPath),
                  Self.cachedFrameImage(at: fullPath) != nil else {
                result(FlutterError(code: "FRAME_ASSET_MISSING", message: "frame asset not found: \(frameAssetPath)", details: nil))
                return
            }
        }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvasW, height: canvasH))

        let composed = renderer.image { ctx in
            let cg = ctx.cgContext

            let canvasBg = args["canvasBgColor"] as? String ?? "transparent"
            if let bgColor = Self.parseColor(canvasBg), bgColor != UIColor.clear {
                bgColor.setFill()
                cg.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
            }

            if (args["drawFrameBg"] as? Bool) == true {
                let frameBg = Self.parseColor(args["frameBgColor"] as? String ?? "") ?? UIColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1.0)
                let l = CGFloat((args["frameOuterLeft"] as? Double) ?? 0)
                let t = CGFloat((args["frameOuterTop"] as? Double) ?? 0)
                let w = CGFloat((args["frameOuterWidth"] as? Double) ?? 0)
                let h = CGFloat((args["frameOuterHeight"] as? Double) ?? 0)
                let r = CGFloat((args["frameCornerRadius"] as? Double) ?? 0)
                frameBg.setFill()
                if r > 0.1 {
                    UIBezierPath(roundedRect: CGRect(x: l, y: t, width: w, height: h), cornerRadius: r).fill()
                } else {
                    cg.fill(CGRect(x: l, y: t, width: w, height: h))
                }
            }

            let boundedCrop = CGRect(
                x: max(0, min(CGFloat(srcCg.width - 1), cropLeft)),
                y: max(0, min(CGFloat(srcCg.height - 1), cropTop)),
                width: max(1, min(cropWidth, CGFloat(srcCg.width))),
                height: max(1, min(cropHeight, CGFloat(srcCg.height)))
            )
            if let cropped = srcCg.cropping(to: boundedCrop) {
                UIImage(cgImage: cropped).draw(in: CGRect(x: imageLeft, y: imageTop, width: imageWidth, height: imageHeight))
            } else {
                srcImage.draw(in: CGRect(x: imageLeft, y: imageTop, width: imageWidth, height: imageHeight))
            }

            if !frameAssetPath.isEmpty {
                if let frameImage = frameImageFromBytes {
                    frameImage.draw(in: CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
                } else if let fullPath = resolveFlutterAssetPath(frameAssetPath),
                          let frameImage = Self.cachedFrameImage(at: fullPath) {
                    frameImage.draw(in: CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
                }
            }

            if let watermarkText = args["watermarkText"] as? String, !watermarkText.isEmpty {
                Self.drawWatermark(args: args, text: watermarkText, in: cg)
            }
        }

        let qualityInt = (args["jpegQuality"] as? Int) ?? 88
        let quality = CGFloat(max(60, min(95, qualityInt))) / 100.0
        guard let jpegData = composed.jpegData(compressionQuality: quality) else {
            result(FlutterError(code: "COMPOSE_FAILED", message: "Failed to encode jpeg", details: nil))
            return
        }
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gpu_overlay_\(UUID().uuidString).jpg")
        do {
            try jpegData.write(to: outputURL)
            result(["filePath": outputURL.path])
        } catch {
            result(FlutterError(code: "COMPOSE_FAILED", message: error.localizedDescription, details: nil))
        }
    }

    private func handleBlendDoubleExposure(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let firstImagePath = args["firstImagePath"] as? String,
              let secondData = (args["secondImageBytes"] as? FlutterStandardTypedData)?.data else {
            result(FlutterError(code: "INVALID_ARG", message: "firstImagePath and secondImageBytes are required", details: nil))
            return
        }
        let blend = max(0.0, min(1.0, (args["blend"] as? Double) ?? 0.5))
        let qualityInt = (args["jpegQuality"] as? Int) ?? 90
        let quality = CGFloat(max(60, min(95, qualityInt))) / 100.0

        DispatchQueue.global(qos: .userInitiated).async {
            guard let firstImage = UIImage(contentsOfFile: firstImagePath),
                  let firstCI = CIImage(image: firstImage),
                  let secondUIImage = UIImage(data: secondData),
                  let secondCIBase = CIImage(image: secondUIImage) else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "DECODE_FAILED", message: "failed to decode blend inputs", details: nil))
                }
                return
            }

            let targetRect = firstCI.extent
            if targetRect.width < 1 || targetRect.height < 1 {
                DispatchQueue.main.async {
                    result(FlutterError(code: "INVALID_SIZE", message: "invalid first image size", details: nil))
                }
                return
            }

            let sx = targetRect.width / max(secondCIBase.extent.width, 1)
            let sy = targetRect.height / max(secondCIBase.extent.height, 1)
            let secondScaled = secondCIBase.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

            let firstWeight = CGFloat(blend)
            let secondWeight = CGFloat(1.0 - blend)
            let firstWeighted = firstCI.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: firstWeight, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: firstWeight, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: firstWeight, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            let secondWeighted = secondScaled.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: secondWeight, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: secondWeight, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: secondWeight, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])

            guard let screen = CIFilter(name: "CIScreenBlendMode") else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "FILTER_MISSING", message: "CIScreenBlendMode unavailable", details: nil))
                }
                return
            }
            screen.setValue(secondWeighted, forKey: kCIInputImageKey)
            screen.setValue(firstWeighted, forKey: kCIInputBackgroundImageKey)
            guard let outCI = screen.outputImage?.cropped(to: targetRect),
                  let cgImage = self.ciContext.createCGImage(outCI, from: targetRect) else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "BLEND_FAILED", message: "failed to render blended image", details: nil))
                }
                return
            }

            let outUIImage = UIImage(cgImage: cgImage)
            guard let jpegData = outUIImage.jpegData(compressionQuality: quality) else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "ENCODE_FAILED", message: "failed to encode blended jpeg", details: nil))
                }
                return
            }
            let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("double_exp_\(UUID().uuidString).jpg")
            do {
                try jpegData.write(to: outputURL)
                DispatchQueue.main.async {
                    result(["filePath": outputURL.path])
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "WRITE_FAILED", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private static func drawWatermark(args: [String: Any], text: String, in cg: CGContext) {
        let imageLeft = CGFloat((args["imageLeft"] as? Double) ?? 0)
        let imageTop = CGFloat((args["imageTop"] as? Double) ?? 0)
        let imageWidth = CGFloat((args["imageWidth"] as? Double) ?? 0)
        let imageHeight = CGFloat((args["imageHeight"] as? Double) ?? 0)
        if imageWidth <= 1 || imageHeight <= 1 { return }
        let hasFrame = (args["watermarkHasFrame"] as? Bool) == true
        let margin = imageWidth * (hasFrame ? 0.08 : 0.04)
        let direction = (args["watermarkDirection"] as? String) ?? "horizontal"
        let position = (args["watermarkPosition"] as? String) ?? "bottom_right"
        let fontSize = CGFloat((args["watermarkFontSize"] as? Double) ?? Double(imageWidth * 0.038))
        let color = parseColor(args["watermarkColor"] as? String ?? "#FF8C00") ?? UIColor.orange
        let fontWeight = ((args["watermarkFontWeight"] as? Int) ?? 400) >= 700 ? UIFont.Weight.bold : UIFont.Weight.regular
        let fontFamily = ((args["watermarkFontFamily"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let font = UIFont(name: fontFamily, size: fontSize) ?? UIFont.systemFont(ofSize: fontSize, weight: fontWeight)

        if direction == "vertical" {
            let chars = text.map { String($0) }
            var maxW: CGFloat = 0
            var lineH: CGFloat = font.lineHeight
            for c in chars {
                let sz = (c as NSString).size(withAttributes: [.font: font])
                maxW = max(maxW, sz.width)
                lineH = max(lineH, sz.height)
            }
            let totalH = lineH * CGFloat(chars.count)
            let origin = resolveWatermarkOrigin(position: position, ox: imageLeft, oy: imageTop, w: imageWidth, h: imageHeight, textW: maxW, textH: totalH, margin: margin)
            for (idx, c) in chars.enumerated() {
                let y = origin.y + CGFloat(idx) * lineH
                let sz = (c as NSString).size(withAttributes: [.font: font])
                let x = origin.x + (maxW - sz.width) / 2
                (c as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
            }
        } else {
            let size = (text as NSString).size(withAttributes: [.font: font])
            let origin = resolveWatermarkOrigin(position: position, ox: imageLeft, oy: imageTop, w: imageWidth, h: imageHeight, textW: size.width, textH: size.height, margin: margin)
            (text as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: color])
        }
    }

    private static func resolveWatermarkOrigin(
        position: String,
        ox: CGFloat,
        oy: CGFloat,
        w: CGFloat,
        h: CGFloat,
        textW: CGFloat,
        textH: CGFloat,
        margin: CGFloat
    ) -> CGPoint {
        switch position {
        case "bottom_left":
            return CGPoint(x: ox + margin, y: oy + h - textH - margin)
        case "top_right":
            return CGPoint(x: ox + w - textW - margin, y: oy + margin)
        case "top_left":
            return CGPoint(x: ox + margin, y: oy + margin)
        case "bottom_center":
            return CGPoint(x: ox + (w - textW) / 2, y: oy + h - textH - margin)
        case "top_center":
            return CGPoint(x: ox + (w - textW) / 2, y: oy + margin)
        default:
            return CGPoint(x: ox + w - textW - margin, y: oy + h - textH - margin)
        }
    }

    private static func parseColor(_ hex: String) -> UIColor? {
        if hex.lowercased() == "transparent" { return UIColor.clear }
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        if raw.count == 6 { raw = "FF" + raw }
        guard raw.count == 8, let value = UInt32(raw, radix: 16) else { return nil }
        let a = CGFloat((value >> 24) & 0xFF) / 255.0
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }

    private func resolveFlutterAssetPath(_ rawPath: String) -> String? {
        let trimmed = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty { return nil }

        let normalized: String
        if trimmed.hasPrefix("flutter_assets/") {
            normalized = String(trimmed.dropFirst("flutter_assets/".count))
        } else {
            normalized = trimmed
        }

        var candidates: [String] = []
        if let lookup = flutterAssetKeyLookup?(normalized), !lookup.isEmpty {
            candidates.append(lookup)
        }
        if normalized.hasPrefix("assets/") {
            let withoutAssets = String(normalized.dropFirst("assets/".count))
            if let lookup = flutterAssetKeyLookup?(withoutAssets), !lookup.isEmpty {
                candidates.append(lookup)
            }
            candidates.append("Frameworks/App.framework/flutter_assets/\(withoutAssets)")
        } else {
            if let lookup = flutterAssetKeyLookup?("assets/\(normalized)"), !lookup.isEmpty {
                candidates.append(lookup)
            }
            candidates.append("Frameworks/App.framework/flutter_assets/assets/\(normalized)")
        }
        candidates.append("Frameworks/App.framework/flutter_assets/\(normalized)")

        var seen = Set<String>()
        for candidate in candidates where !candidate.isEmpty {
            if seen.contains(candidate) { continue }
            seen.insert(candidate)
            let cleaned = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let absolute = Bundle.main.bundlePath + "/" + cleaned
            if FileManager.default.fileExists(atPath: absolute) {
                return absolute
            }
            if let path = Bundle.main.path(forResource: cleaned, ofType: nil),
               FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    private static func cachedFrameImage(at fullPath: String) -> UIImage? {
        let key = fullPath as NSString
        if let cached = frameImageCache.object(forKey: key) {
            return cached
        }
        guard let image = UIImage(contentsOfFile: fullPath) else { return nil }
        frameImageCache.setObject(image, forKey: key)
        return image
    }

    /// 将带 EXIF 方向的 UIImage 归一化为 .up，避免直接用 cgImage 时方向丢失。
    private static func normalizedImage(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    // ─────────────────────────────────────────────
    // dispose
    // ─────────────────────────────────────────────
    private func handleDispose(result: @escaping FlutterResult) {
        runtimeStatsTimer?.invalidate()
        runtimeStatsTimer = nil
        cameraManager?.stopSession()
        cameraManager = nil
        if registeredTextureId != -1 {
            textureRegistry?.unregisterTexture(registeredTextureId)
            registeredTextureId = -1
        }
        renderer = nil
        cachedRenderParams = [:]
        cachedLensParams = [:]
        cachedPresetJson = [:]
        cachedPresetShaderParams = [:]
        cachedZoom = 1.0
        cachedRenderVersion = 0
        currentCameraId = ""
        result(nil)
    }

    private func reapplyRuntimeStateToRenderer() {
        guard let renderer else { return }
        if !cachedPresetShaderParams.isEmpty {
            renderer.updateParams(cachedPresetShaderParams)
        } else if !cachedPresetJson.isEmpty {
            // 兼容旧缓存路径，确保 renderer 重建后不会丢失预览风格参数。
            cachedPresetShaderParams = buildShaderParams(from: cachedPresetJson)
            renderer.updateParams(cachedPresetShaderParams)
        }
        if let fisheyeMode = cachedLensParams["fisheyeMode"] as? Bool {
            renderer.setFisheyeMode(fisheyeMode)
        }
        if let circularFisheye = cachedLensParams["circularFisheye"] as? Bool {
            renderer.setCircularFisheye(circularFisheye)
        }
        if !cachedLensParams.isEmpty {
            var p = renderer.getCCDParams()
            if let v = cachedLensParams["vignette"] as? Double { p.vignetteAmount = Float(v) }
            if let v = cachedLensParams["chromaticAberration"] as? Double { p.chromaticAberration = Float(v) }
            if let v = cachedLensParams["bloom"] as? Double { p.bloomAmount = Float(v) }
            if let v = cachedLensParams["distortion"] as? Double { p.lensDistortion = Float(v) }
            if let v = cachedLensParams["circularFisheye"] as? Bool { p.circularFisheye = v ? 1.0 : 0.0 }
            renderer.setCCDParams(p)
        }
        if !cachedRenderParams.isEmpty {
            renderer.updateParams(cachedRenderParams)
        }
        cameraManager?.setZoom(factor: CGFloat(cachedZoom))
    }

    private func scheduleRendererStateReplay(reason: String) {
        let replayDelays: [DispatchTimeInterval] = [.milliseconds(90), .milliseconds(220)]
        for delay in replayDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.reapplyRuntimeStateToRenderer()
                self.renderer?.setSharpen(self.currentSharpenLevel)
                #if DEBUG
                print("CameraPlugin: renderer state replayed after \(reason)")
                #endif
            }
        }
    }

    private func buildShaderParams(from presetJson: [String: Any]) -> [String: Any] {
        var shaderParams: [String: Any] = [:]
        if let baseModel = presetJson["baseModel"] as? [String: Any] {
            if let color = baseModel["color"] as? [String: Any] {
                if let contrast = color["contrast"] as? NSNumber { shaderParams["contrast"] = contrast.floatValue }
                if let saturation = color["saturation"] as? NSNumber { shaderParams["saturation"] = saturation.floatValue }
                if let temperature = color["temperature"] as? NSNumber { shaderParams["temperatureShift"] = temperature.floatValue }
            }
            if let sensor = baseModel["sensor"] as? [String: Any] {
                if let noise = sensor["noise"] as? NSNumber { shaderParams["noise"] = noise.floatValue }
                if let grain = sensor["grain"] as? NSNumber { shaderParams["grainAmount"] = grain.floatValue }
                if let vignette = sensor["vignette"] as? NSNumber { shaderParams["vignette"] = vignette.floatValue }
                if let ca = sensor["chromaticAberration"] as? NSNumber { shaderParams["chromaticAberration"] = ca.floatValue }
                if let bloom = sensor["bloom"] as? NSNumber { shaderParams["bloom"] = bloom.floatValue }
            }
        }
        if let params = presetJson["params"] as? [String: Any] {
            if let contrast = params["contrast"] as? NSNumber { shaderParams["contrast"] = contrast.floatValue }
            if let saturation = params["saturation"] as? NSNumber { shaderParams["saturation"] = saturation.floatValue }
            if let temperatureShift = params["temperatureShift"] as? NSNumber { shaderParams["temperatureShift"] = temperatureShift.floatValue }
            if let tintShift = params["tintShift"] as? NSNumber { shaderParams["tintShift"] = tintShift.floatValue }
            if let sharpen = params["sharpen"] as? NSNumber { shaderParams["sharpen"] = sharpen.floatValue }
            if let grainAmount = params["grainAmount"] as? NSNumber { shaderParams["grainAmount"] = grainAmount.floatValue }
            if let noiseAmount = params["noiseAmount"] as? NSNumber { shaderParams["noise"] = noiseAmount.floatValue }
            if let vignetteAmount = params["vignetteAmount"] as? NSNumber { shaderParams["vignette"] = vignetteAmount.floatValue }
            if let ca = params["chromaticAberration"] as? NSNumber { shaderParams["chromaticAberration"] = ca.floatValue }
            if let bloom = params["bloomAmount"] as? NSNumber { shaderParams["bloom"] = bloom.floatValue }
            if let halation = params["halationAmount"] as? NSNumber { shaderParams["halation"] = halation.floatValue }
            if let v = params["colorBiasR"] as? NSNumber { shaderParams["colorBiasR"] = v.floatValue }
            if let v = params["colorBiasG"] as? NSNumber { shaderParams["colorBiasG"] = v.floatValue }
            if let v = params["colorBiasB"] as? NSNumber { shaderParams["colorBiasB"] = v.floatValue }
            if let v = params["grainSize"] as? NSNumber { shaderParams["grainSize"] = v.floatValue }
            if let v = params["sharpness"] as? NSNumber { shaderParams["sharpness"] = v.floatValue }
            if let v = params["highlightWarmAmount"] as? NSNumber { shaderParams["highlightWarmAmount"] = v.floatValue }
            if let v = params["luminanceNoise"] as? NSNumber { shaderParams["luminanceNoise"] = v.floatValue }
            if let v = params["chromaNoise"] as? NSNumber { shaderParams["chromaNoise"] = v.floatValue }
        }
        if let dl = presetJson["defaultLook"] as? [String: Any] {
            if let v = dl["contrast"] as? NSNumber { shaderParams["contrast"] = v.floatValue }
            if let v = dl["saturation"] as? NSNumber { shaderParams["saturation"] = v.floatValue }
            if let v = dl["temperature"] as? NSNumber { shaderParams["temperatureShift"] = v.floatValue }
            if let v = dl["tint"] as? NSNumber { shaderParams["tintShift"] = v.floatValue }
            if let v = dl["grain"] as? NSNumber { shaderParams["grainAmount"] = v.floatValue }
            if let v = dl["vignette"] as? NSNumber { shaderParams["vignette"] = v.floatValue }
            if let v = dl["chromaticAberration"] as? NSNumber { shaderParams["chromaticAberration"] = v.floatValue }
            if let v = dl["bloom"] as? NSNumber { shaderParams["bloom"] = v.floatValue }
            if let v = dl["halation"] as? NSNumber { shaderParams["halation"] = v.floatValue }
            if let v = dl["highlights"] as? NSNumber { shaderParams["highlights"] = v.floatValue }
            if let v = dl["shadows"] as? NSNumber { shaderParams["shadows"] = v.floatValue }
            if let v = dl["whites"] as? NSNumber { shaderParams["whites"] = v.floatValue }
            if let v = dl["blacks"] as? NSNumber { shaderParams["blacks"] = v.floatValue }
            if let v = dl["clarity"] as? NSNumber { shaderParams["clarity"] = v.floatValue }
            if let v = dl["vibrance"] as? NSNumber { shaderParams["vibrance"] = v.floatValue }
            if let v = dl["noise"] as? NSNumber { shaderParams["noise"] = v.floatValue }
            if let v = dl["noiseAmount"] as? NSNumber { shaderParams["noise"] = v.floatValue }
            if let v = dl["colorBiasR"] as? NSNumber { shaderParams["colorBiasR"] = v.floatValue }
            if let v = dl["colorBiasG"] as? NSNumber { shaderParams["colorBiasG"] = v.floatValue }
            if let v = dl["colorBiasB"] as? NSNumber { shaderParams["colorBiasB"] = v.floatValue }
            if let v = dl["grainSize"] as? NSNumber { shaderParams["grainSize"] = v.floatValue }
            if let v = dl["sharpness"] as? NSNumber { shaderParams["sharpness"] = v.floatValue }
            if let v = dl["highlightWarmAmount"] as? NSNumber { shaderParams["highlightWarmAmount"] = v.floatValue }
            if let v = dl["luminanceNoise"] as? NSNumber { shaderParams["luminanceNoise"] = v.floatValue }
            if let v = dl["chromaNoise"] as? NSNumber { shaderParams["chromaNoise"] = v.floatValue }
            if let v = dl["highlightRolloff"] as? NSNumber { shaderParams["highlightRolloff"] = v.floatValue }
            if let v = dl["highlightRolloff2"] as? NSNumber { shaderParams["highlightRolloff2"] = v.floatValue }
            if let v = dl["paperTexture"] as? NSNumber { shaderParams["paperTexture"] = v.floatValue }
            if let v = dl["edgeFalloff"] as? NSNumber { shaderParams["edgeFalloff"] = v.floatValue }
            if let v = dl["exposureVariation"] as? NSNumber { shaderParams["exposureVariation"] = v.floatValue }
            if let v = dl["cornerWarmShift"] as? NSNumber { shaderParams["cornerWarmShift"] = v.floatValue }
            if let v = dl["toneCurveStrength"] as? NSNumber { shaderParams["toneCurveStrength"] = v.floatValue }
            if let v = dl["lutStrength"] as? NSNumber { shaderParams["lutStrength"] = v.floatValue }
            if let v = dl["centerGain"] as? NSNumber { shaderParams["centerGain"] = v.floatValue }
            if let v = dl["developmentSoftness"] as? NSNumber { shaderParams["developmentSoftness"] = v.floatValue }
            if let v = dl["chemicalIrregularity"] as? NSNumber { shaderParams["chemicalIrregularity"] = v.floatValue }
            if let v = dl["skinHueProtect"] as? Bool { shaderParams["skinHueProtect"] = v ? Float(1.0) : Float(0.0) }
            else if let v = dl["skinHueProtect"] as? NSNumber { shaderParams["skinHueProtect"] = v.floatValue }
            if let v = dl["skinSatProtect"] as? NSNumber { shaderParams["skinSatProtect"] = v.floatValue }
            if let v = dl["skinLumaSoften"] as? NSNumber { shaderParams["skinLumaSoften"] = v.floatValue }
            if let v = dl["skinRedLimit"] as? NSNumber { shaderParams["skinRedLimit"] = v.floatValue }
            if let lutPath = dl["baseLut"] as? String, !lutPath.isEmpty { shaderParams["lut"] = lutPath }
        }
        if let lut = presetJson["lut"] as? String { shaderParams["lut"] = lut }
        if let grain = presetJson["grain"] as? String { shaderParams["grain"] = grain }
        let cameraId = (presetJson["cameraId"] as? String) ?? (presetJson["id"] as? String) ?? ""
        if !cameraId.isEmpty { shaderParams["cameraId"] = cameraId }
        return shaderParams
    }

    private func startRuntimeStatsTimer() {
        runtimeStatsTimer?.invalidate()
        runtimeStatsTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard let stats = self.cameraManager?.snapshotRuntimeStats() else { return }
            self.emitEvent(type: "onCameraRuntimeStats", payload: stats)
        }
    }

    private func emitEvent(type: String, payload: [String: Any]) {
        eventSink?(["type": type, "payload": payload])
    }
}

// ─────────────────────────────────────────────
// FlutterStreamHandler — 事件流
// ─────────────────────────────────────────────
extension RetroCamPlugin: FlutterStreamHandler {
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}


// ── Metal Compute Pipeline ───────────────────────────────────────────
