import Flutter
import UIKit
import AVFoundation
import Photos

// ─────────────────────────────────────────────────────────────────────────────
// RetroCamPlugin — iOS 相机 MethodChannel 插件
// Channel: com.retrocam.app/camera_control
// ─────────────────────────────────────────────────────────────────────────────
public class RetroCamPlugin: NSObject, FlutterPlugin {

    private var cameraManager: CameraSessionManager?
    private var renderer: MetalRenderer?
    private var eventSink: FlutterEventSink?
    private var textureRegistry: FlutterTextureRegistry?
    private var registeredTextureId: Int64 = -1

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
            // Flash handled at capture time; no-op for preview
            result(nil)
        case "setZoom":
            result(nil)
        case "setExposure":
            result(nil)
        case "saveToGallery":
            handleSaveToGallery(call: call, result: result)
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
            }
            if let sensor = baseModel["sensor"] as? [String: Any] {
                if let noise = sensor["noise"] as? NSNumber { shaderParams["noise"] = noise.floatValue }
            }
        }
        renderer?.updateParams(shaderParams)
        result(["success": true])
    }

    // ─────────────────────────────────────────────
    // takePhoto — 捕获当前帧并保存到 cache
    // ─────────────────────────────────────────────
    private func handleTakePhoto(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let renderer = renderer else {
            result(FlutterError(code: "NOT_READY", message: "Camera not initialized", details: nil))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let pixelBuffer = renderer.copyPixelBuffer()?.takeRetainedValue() else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "NO_FRAME", message: "No frame available", details: nil))
                }
                return
            }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let context = CIContext()
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            let fileName = "DAZZ_\(timestamp).jpg"
            let cacheDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("dazz_captures", isDirectory: true)
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let fileURL = cacheDir.appendingPathComponent(fileName)
            if let cgImage = context.createCGImage(ciImage, from: ciImage.extent),
               let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.92) {
                try? data.write(to: fileURL)
                DispatchQueue.main.async {
                    result(["filePath": fileURL.path])
                }
            } else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "ENCODE_FAILED", message: "Failed to encode image", details: nil))
                }
            }
        }
    }

    // ─────────────────────────────────────────────
    // saveToGallery — 将 cache 文件保存到 Photos
    // ─────────────────────────────────────────────
    private func handleSaveToGallery(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let filePath = args["filePath"] as? String else {
            result(FlutterError(code: "INVALID_ARG", message: "filePath required", details: nil))
            return
        }
        let fileURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            result(FlutterError(code: "FILE_NOT_FOUND", message: "File not found: \(filePath)", details: nil))
            return
        }
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "PERMISSION_DENIED", message: "Photo library access denied", details: nil))
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                _ = request?.placeholderForCreatedAsset
            }) { success, error in
                DispatchQueue.main.async {
                    if success {
                        try? FileManager.default.removeItem(at: fileURL)
                        result(["success": true, "uri": filePath])
                    } else {
                        result(FlutterError(code: "SAVE_FAILED", message: error?.localizedDescription, details: nil))
                    }
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
