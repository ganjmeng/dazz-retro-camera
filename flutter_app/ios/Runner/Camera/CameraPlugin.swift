import Flutter
import UIKit
import AVFoundation
import Photos
import MetalKit

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

    private var cameraManager: CameraSessionManager?
    private var renderer: MetalRenderer?
    private var eventSink: FlutterEventSink?
    private var textureRegistry: FlutterTextureRegistry?
    private var registeredTextureId: Int64 = -1

    // 当前闪光灯模式
    private var currentFlashMode: AVCaptureDevice.FlashMode = .off

    // takePhoto 的回调（等待 AVCapturePhotoCaptureDelegate）
    private var pendingPhotoResult: FlutterResult?

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

        registrar.addMethodCallDelegate(instance, channel: channel)
        eventChannel.setStreamHandler(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initCamera":
            handleInitCamera(call: call, result: result)
        case "startPreview":
            cameraManager?.startSession()
            result(nil)
        case "stopPreview":
            cameraManager?.stopSession()
            result(nil)
        case "setPreset":
            handleSetPreset(call: call, result: result)
        case "takePhoto":
            handleTakePhoto(call: call, result: result)
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
        case "setWhiteBalance":
            handleSetWhiteBalance(call: call, result: result)
        case "setSharpen":
            handleSetSharpen(call: call, result: result)
        case "updateLensParams":
            handleUpdateLensParams(call: call, result: result)
        case "saveToGallery":
            handleSaveToGallery(call: call, result: result)
        case "processWithGpu":
            handleProcessWithGpu(call: call, result: result)
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
        let lens: AVCaptureDevice.Position = (lensStr == "front") ? .front : .back

        // 释放旧资源
        cameraManager?.stopSession()
        if registeredTextureId != -1 {
            textureRegistry?.unregisterTexture(registeredTextureId)
        }

        cameraManager = CameraSessionManager()
        renderer = MetalRenderer(registry: textureRegistry!)

        // 向 Flutter 注册 Texture
        let textureId = textureRegistry!.register(renderer!)
        registeredTextureId = textureId
        renderer?.setTextureId(textureId)

        // 设置帧回调并启动相机会话
        cameraManager?.sampleBufferDelegate = renderer!
        cameraManager?.configure(lens: lens)
        cameraManager?.startSession()

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
        result(nil)
    }

    // ─────────────────────────────────────────────
    // setPreset
    // ─────────────────────────────────────────────
    private func handleSetPreset(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let presetJson = args["preset"] as? [String: Any] else {
            result(FlutterError(code: "INVALID_ARG", message: "Invalid preset parameters", details: nil))
            return
        }
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
        // 解析 params 子对象（PresetParams.toJson() 输出）
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
            // ── FQS / CPM35 专用字段 ──────────────────────────────────────────────────
            if let v = params["colorBiasR"]          as? NSNumber { shaderParams["colorBiasR"]          = v.floatValue }
            if let v = params["colorBiasG"]          as? NSNumber { shaderParams["colorBiasG"]          = v.floatValue }
            if let v = params["colorBiasB"]          as? NSNumber { shaderParams["colorBiasB"]          = v.floatValue }
            if let v = params["grainSize"]           as? NSNumber { shaderParams["grainSize"]           = v.floatValue }
            if let v = params["sharpness"]           as? NSNumber { shaderParams["sharpness"]           = v.floatValue }
            if let v = params["highlightWarmAmount"] as? NSNumber { shaderParams["highlightWarmAmount"] = v.floatValue }
            if let v = params["luminanceNoise"]      as? NSNumber { shaderParams["luminanceNoise"]      = v.floatValue }
            if let v = params["chromaNoise"]         as? NSNumber { shaderParams["chromaNoise"]         = v.floatValue }
        }
        // ── 解析 defaultLook 子对象（直接从 CameraDefinition.defaultLook 传入） ──────────────────────
        if let dl = presetJson["defaultLook"] as? [String: Any] {
            if let v = dl["contrast"]            as? NSNumber { shaderParams["contrast"]            = v.floatValue }
            if let v = dl["saturation"]          as? NSNumber { shaderParams["saturation"]          = v.floatValue }
            if let v = dl["temperature"]         as? NSNumber { shaderParams["temperatureShift"]    = v.floatValue }
            if let v = dl["tint"]                as? NSNumber { shaderParams["tintShift"]           = v.floatValue }
            if let v = dl["grain"]               as? NSNumber { shaderParams["grainAmount"]         = v.floatValue }
            if let v = dl["vignette"]            as? NSNumber { shaderParams["vignette"]            = v.floatValue }
            if let v = dl["chromaticAberration"] as? NSNumber { shaderParams["chromaticAberration"] = v.floatValue }
            if let v = dl["bloom"]               as? NSNumber { shaderParams["bloom"]               = v.floatValue }
            if let v = dl["halation"]            as? NSNumber { shaderParams["halation"]            = v.floatValue }
            // FIX: Lightroom 风格曲线参数（原来缺失，导致链路断裂）
            if let v = dl["highlights"]          as? NSNumber { shaderParams["highlights"]          = v.floatValue }
            if let v = dl["shadows"]             as? NSNumber { shaderParams["shadows"]             = v.floatValue }
            if let v = dl["whites"]              as? NSNumber { shaderParams["whites"]              = v.floatValue }
            if let v = dl["blacks"]              as? NSNumber { shaderParams["blacks"]              = v.floatValue }
            if let v = dl["clarity"]             as? NSNumber { shaderParams["clarity"]             = v.floatValue }
            if let v = dl["vibrance"]            as? NSNumber { shaderParams["vibrance"]            = v.floatValue }
            // FIX: noiseAmount（兼容 noise 和 noiseAmount 两种键名）
            if let v = dl["noise"]               as? NSNumber { shaderParams["noise"]               = v.floatValue }
            if let v = dl["noiseAmount"]         as? NSNumber { shaderParams["noise"]               = v.floatValue }
            // FQS / CPM35 专用
            if let v = dl["colorBiasR"]          as? NSNumber { shaderParams["colorBiasR"]          = v.floatValue }
            if let v = dl["colorBiasG"]          as? NSNumber { shaderParams["colorBiasG"]          = v.floatValue }
            if let v = dl["colorBiasB"]          as? NSNumber { shaderParams["colorBiasB"]          = v.floatValue }
            if let v = dl["grainSize"]           as? NSNumber { shaderParams["grainSize"]           = v.floatValue }
            if let v = dl["sharpness"]           as? NSNumber { shaderParams["sharpness"]           = v.floatValue }
            if let v = dl["highlightWarmAmount"] as? NSNumber { shaderParams["highlightWarmAmount"] = v.floatValue }
            if let v = dl["luminanceNoise"]      as? NSNumber { shaderParams["luminanceNoise"]      = v.floatValue }
            if let v = dl["chromaNoise"]         as? NSNumber { shaderParams["chromaNoise"]         = v.floatValue }
            // Inst C 专用字段
            if let v = dl["highlightRolloff"]   as? NSNumber { shaderParams["highlightRolloff"]   = v.floatValue }
            if let v = dl["paperTexture"]        as? NSNumber { shaderParams["paperTexture"]        = v.floatValue }
            if let v = dl["edgeFalloff"]         as? NSNumber { shaderParams["edgeFalloff"]         = v.floatValue }
            if let v = dl["exposureVariation"]   as? NSNumber { shaderParams["exposureVariation"]   = v.floatValue }
            if let v = dl["cornerWarmShift"]     as? NSNumber { shaderParams["cornerWarmShift"]     = v.floatValue }
            // SQC 专用字段
            if let v = dl["centerGain"]           as? NSNumber { shaderParams["centerGain"]           = v.floatValue }
            if let v = dl["developmentSoftness"]  as? NSNumber { shaderParams["developmentSoftness"]  = v.floatValue }
            if let v = dl["chemicalIrregularity"] as? NSNumber { shaderParams["chemicalIrregularity"] = v.floatValue }
            if let v = dl["skinHueProtect"] as? Bool { shaderParams["skinHueProtect"] = v ? Float(1.0) : Float(0.0) }
            else if let v = dl["skinHueProtect"] as? NSNumber { shaderParams["skinHueProtect"] = v.floatValue }
            if let v = dl["skinSatProtect"]       as? NSNumber { shaderParams["skinSatProtect"]       = v.floatValue }
            if let v = dl["skinLumaSoften"]       as? NSNumber { shaderParams["skinLumaSoften"]       = v.floatValue }
            if let v = dl["skinRedLimit"]         as? NSNumber { shaderParams["skinRedLimit"]         = v.floatValue }
            if let lutPath = dl["baseLut"] as? String, !lutPath.isEmpty { shaderParams["lut"] = lutPath }
        }
        if let lut = presetJson["lut"] as? String { shaderParams["lut"] = lut }
        if let grain = presetJson["grain"] as? String { shaderParams["grain"] = grain }
        renderer?.updateParams(shaderParams)
        result(["success": true])
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
        // 1. 更新 Metal shader 中的 Unsharp Mask 强度
        renderer?.setSharpen(floatLevel)
        // 2. 动态切换 AVCaptureSession.sessionPreset（影响实际拍摄分辨率）
        // CRITICAL FIX: call result(nil) only AFTER sessionPreset is committed.
        // Previously result(nil) was called immediately, causing Flutter's takePhoto
        // to run before the new sessionPreset was applied — resulting in 2MP output.
        if let mgr = cameraManager {
            mgr.setResolution(level: floatLevel) {
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
        let vignette              = args?["vignette"] as? Double ?? 0.0
        let chromaticAberration   = args?["chromaticAberration"] as? Double ?? 0.0
        let bloom                 = args?["bloom"] as? Double ?? 0.0
        let softFocus             = args?["softFocus"] as? Double ?? 0.0
        let distortion            = args?["distortion"] as? Double ?? 0.0

        // 将鱼眼模式传递到 Metal 渲染器
        renderer?.setFisheyeMode(fisheyeMode)

        // ── FIX: 将所有镜头参数传递到 Metal 渲染器（之前只传了 vignette）──
        if let r = renderer {
            var p = r.getCCDParams()
            p.vignetteAmount = Float(vignette)
            p.chromaticAberration = Float(chromaticAberration)
            p.bloomAmount = Float(bloom)
            // softFocus 和 distortion 在 Metal shader 中可能没有对应 uniform，
            // 但通过 renderParams 统一发送时会覆盖
            r.setCCDParams(p)
        }
        result(nil)
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

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let fileName = "DAZZ_\(timestamp).jpg"
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dazz_captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let fileURL = cacheDir.appendingPathComponent(fileName)

        cameraManager.capturePhoto(flashMode: currentFlashMode) { [weak self] imageData in
            guard let data = imageData else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "CAPTURE_FAILED", message: "Failed to capture photo", details: nil))
                }
                return
            }
            do {
                try data.write(to: fileURL)
                DispatchQueue.main.async {
                    result(["filePath": fileURL.path])
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "WRITE_FAILED", message: error.localizedDescription, details: nil))
                }
            }
        }
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

    // ─────────────────────────────────────────────
    // dispose
    // ─────────────────────────────────────────────
    private func handleDispose(result: @escaping FlutterResult) {
        cameraManager?.stopSession()
        cameraManager = nil
        if registeredTextureId != -1 {
            textureRegistry?.unregisterTexture(registeredTextureId)
            registeredTextureId = -1
        }
        renderer = nil
        result(nil)
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
