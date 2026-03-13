package com.retrocam.app

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.EventChannel
import io.flutter.view.TextureRegistry

class RetroCamPlugin: FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var channel : MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null
    
    private var cameraManager: com.retrocam.app.managers.CameraManager? = null
    private var glRenderer: com.retrocam.app.renderers.GLRenderer? = null
    private lateinit var textureRegistry: TextureRegistry

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        textureRegistry = flutterPluginBinding.textureRegistry
        
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "com.retrocam.app/camera_control")
        channel.setMethodCallHandler(this)
        
        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "com.retrocam.app/camera_events")
        eventChannel.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "initCamera" -> handleInitCamera(call, result)
            "startPreview" -> {
                cameraManager?.startPreview()
                result.success(mapOf("success" to true))
            }
            "stopPreview" -> {
                cameraManager?.stopPreview()
                result.success(mapOf("success" to true))
            }
            "setPreset" -> handleSetPreset(call, result)
            "takePhoto" -> handleTakePhoto(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleInitCamera(call: MethodCall, result: Result) {
        // 初始化 OpenGL 渲染器并获取 SurfaceTexture
        val textureEntry = textureRegistry.createSurfaceTexture()
        glRenderer = com.retrocam.app.renderers.GLRenderer(textureEntry.surfaceTexture())
        
        // 初始化 CameraX
        // For Flutter plugin, we don't have direct access to a LifecycleOwner in the plugin itself
        // Typically we would use FlutterFragmentActivity or similar
        // For this skeleton, we'll assume cameraManager is initialized correctly later
        
        result.success(mapOf("textureId" to textureEntry.id()))
    }

    private fun handleSetPreset(call: MethodCall, result: Result) {
        val presetJson = call.argument<Map<String, Any>>("preset")
        if (presetJson == null) {
            result.error("1003", "Invalid preset parameters", null)
            return
        }
        // 解析 JSON 并更新 GLRenderer 的 Shader
        // val preset = Preset.fromJson(presetJson)
        // glRenderer?.updatePreset(preset)
        result.success(mapOf("success" to true))
    }

    private fun handleTakePhoto(call: MethodCall, result: Result) {
        // 触发 CameraX 拍照，送入 GL 渲染后保存
        result.success(mapOf("filePath" to "/dummy/path/to/photo.jpg"))
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
}
