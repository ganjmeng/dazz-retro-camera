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
        case "takePhoto":
            handleTakePhoto(call: call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func handleInitCamera(call: FlutterMethodCall, result: @escaping FlutterResult) {
        // 初始化 CameraManager 和 MetalRenderer
        cameraManager = CameraSessionManager()
        renderer = MetalRenderer(registry: textureRegistry!)
        
        cameraManager?.setSampleBufferDelegate(renderer!)
        
        if let textureId = renderer?.textureId {
            result(["textureId": textureId])
        } else {
            result(FlutterError(code: "1001", message: "Failed to create texture", details: nil))
        }
    }
    
    private func handleSetPreset(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let presetJson = args["preset"] as? [String: Any] else {
            result(FlutterError(code: "1003", message: "Invalid preset parameters", details: nil))
            return
        }
        
        // 解析 JSON 并更新 Renderer 的 Shader 和参数
        // let preset = Preset.fromJson(presetJson)
        // renderer?.updatePreset(preset)
        
        result(["success": true])
    }
    
    private func handleTakePhoto(call: FlutterMethodCall, result: @escaping FlutterResult) {
        // 触发拍照逻辑，获取高分辨率图像后进行渲染并保存
        // cameraManager?.capturePhoto { image in ... }
        result(["filePath": "/dummy/path/to/photo.jpg"])
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
