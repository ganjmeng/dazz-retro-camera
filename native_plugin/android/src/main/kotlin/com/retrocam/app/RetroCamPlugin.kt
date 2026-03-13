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
            "startRecording" -> handleStartRecording(call, result)
            "stopRecording" -> handleStopRecording(call, result)
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
        
        // Parse preset JSON to extract shader parameters
        val shaderParams = mutableMapOf<String, Any>()
        
        val baseModel = presetJson["baseModel"] as? Map<*, *>
        if (baseModel != null) {
            val color = baseModel["color"] as? Map<*, *>
            if (color != null) {
                color["contrast"]?.let { shaderParams["contrast"] = it }
                color["saturation"]?.let { shaderParams["saturation"] = it }
            }
            val sensor = baseModel["sensor"] as? Map<*, *>
            if (sensor != null) {
                sensor["noise"]?.let { shaderParams["noise"] = it }
            }
        }
        
        glRenderer?.updateParams(shaderParams)
        
        result.success(mapOf("success" to true))
    }

    private fun handleTakePhoto(call: MethodCall, result: Result) {
        // 触发 CameraX 拍照，送入 GL 渲染后保存
        // In a full implementation, this would call cameraManager.takePhoto,
        // wait for the high-res buffer, pass it through the GLRenderer with the
        // current params, apply paper/border if needed, and save to MediaStore.
        
        // Mock implementation for Phase 2 skeleton
        Thread {
            // Simulate processing time
            Thread.sleep(500)
            
            // Return to main thread
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                result.success(mapOf("filePath" to "/dummy/path/to/rendered_photo.jpg"))
            }
        }.start()
    }

    private fun handleStartRecording(call: MethodCall, result: Result) {
        // In a full implementation, this would setup MediaCodec/MediaMuxer,
        // connect it to the GLRenderer output surface, and start writing.
        result.success(mapOf("success" to true))
    }

    private fun handleStopRecording(call: MethodCall, result: Result) {
        // In a full implementation, this would stop the MediaCodec/MediaMuxer,
        // save the resulting MP4 file to MediaStore, and return the path.
        
        Thread {
            Thread.sleep(1000)
            
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                result.success(mapOf("filePath" to "/dummy/path/to/rendered_video.mp4"))
            }
        }.start()
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
