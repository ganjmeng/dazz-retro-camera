import Flutter
import UIKit

public class RetroCamPlugin: NSObject, FlutterPlugin {
    
    private var cameraManager: CameraSessionManager?
    private var renderer: MetalRenderer?
    private var eventSink: FlutterEventSink?
    private var textureRegistry: FlutterTextureRegistry?
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.retrocam.app/camera_control", binaryMessenger: registrar.messenger())
        let eventChannel = FlutterEventChannel(name: "com.retrocam.app/camera_events", binaryMessenger: registrar.messenger())
        
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
            result(["success": true])
        case "stopPreview":
            cameraManager?.stopSession()
            result(["success": true])
        case "setPreset":
            handleSetPreset(call: call, result: result)
        case "updateLensParams":
            handleUpdateLensParams(call: call, result: result)
        case "takePhoto":
            handleTakePhoto(call: call, result: result)
        case "startRecording":
            handleStartRecording(call: call, result: result)
        case "stopRecording":
            handleStopRecording(call: call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func handleInitCamera(call: FlutterMethodCall, result: @escaping FlutterResult) {
        // 初始化 CameraManager 和 MetalRenderer
        cameraManager = CameraSessionManager()
        renderer = MetalRenderer(registry: textureRegistry!)
        
        // Register texture with Flutter
        let textureId = textureRegistry!.register(renderer!)
        renderer?.setTextureId(textureId)
        
        cameraManager?.sampleBufferDelegate = renderer!
        cameraManager?.configure()
        
        result(["textureId": textureId])
    }
    
    private func handleSetPreset(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let presetJson = args["preset"] as? [String: Any] else {
            result(FlutterError(code: "1003", message: "Invalid preset parameters", details: nil))
            return
        }
        
        // Parse preset JSON to extract shader parameters
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
        
        // Also parse active options from optionGroups if they exist in the snapshot
        // (In a real implementation, we would flatten the active options' rendering params)
        
        renderer?.updateParams(shaderParams)
        
        result(["success": true])
    }
    
    private func handleUpdateLensParams(call: FlutterMethodCall, result: @escaping FlutterResult) {
        // 镜头切换时实时更新 Metal shader 中的畸变参数
        guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "1004", message: "Invalid lens parameters", details: nil))
            return
        }
        let distortion = (args["distortion"] as? NSNumber)?.floatValue ?? 0.0
        renderer?.updateParams(["distortion": distortion])
        result(["success": true])
    }
    
    private func handleTakePhoto(call: FlutterMethodCall, result: @escaping FlutterResult) {
        // 触发拍照逻辑，获取高分辨率图像后进行渲染并保存
        // In a full implementation, this would call cameraManager.capturePhoto,
        // wait for the high-res buffer, pass it through the MetalRenderer with the
        // current params, apply paper/border if needed, and save to Photos album.
        
        // Mock implementation for Phase 2 skeleton
        DispatchQueue.global(qos: .userInitiated).async {
            // Simulate processing time
            Thread.sleep(forTimeInterval: 0.5)
            
            DispatchQueue.main.async {
                result(["filePath": "/dummy/path/to/rendered_photo.jpg"])
            }
        }
    }
    
    private func handleStartRecording(call: FlutterMethodCall, result: @escaping FlutterResult) {
        // In a full implementation, this would setup AVAssetWriter, connect it to the
        // MetalRenderer output, and start writing frames to a temporary file.
        result(["success": true])
    }
    
    private func handleStopRecording(call: FlutterMethodCall, result: @escaping FlutterResult) {
        // In a full implementation, this would finish writing the AVAssetWriter,
        // save the resulting MP4 file to the Photos album, and return the path.
        
        DispatchQueue.global(qos: .userInitiated).async {
            Thread.sleep(forTimeInterval: 1.0)
            
            DispatchQueue.main.async {
                result(["filePath": "/dummy/path/to/rendered_video.mp4"])
            }
        }
    }
}

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
