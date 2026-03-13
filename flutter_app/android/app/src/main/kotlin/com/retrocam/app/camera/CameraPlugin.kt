package com.retrocam.app.camera

import android.content.ContentValues
import android.content.Context
import android.graphics.SurfaceTexture
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import android.view.Surface
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.*
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class CameraPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {

    companion object {
        private const val TAG = "CameraPlugin"
        private const val METHOD_CHANNEL = "com.retrocam.app/camera_control"
        private const val EVENT_CHANNEL = "com.retrocam.app/camera_events"
        private const val DAZZ_ALBUM = "DAZZ"
    }

    // Flutter bindings
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null
    private lateinit var flutterPluginBinding: FlutterPlugin.FlutterPluginBinding

    // Activity / lifecycle
    private var activityBinding: ActivityPluginBinding? = null
    private val lifecycleOwner: LifecycleOwner?
        get() = activityBinding?.activity as? LifecycleOwner

    // CameraX
    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var preview: Preview? = null
    private var imageCapture: ImageCapture? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var recording: Recording? = null
    private var lensFacing: Int = CameraSelector.LENS_FACING_BACK

    // Flutter texture
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var surfaceTexture: SurfaceTexture? = null

    // Executors
    private lateinit var cameraExecutor: ExecutorService
    private lateinit var bgExecutor: ExecutorService

    // Filter state
    private var currentPresetJson: Map<*, *>? = null

    // ─────────────────────────────────────────────
    // FlutterPlugin lifecycle
    // ─────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        flutterPluginBinding = binding
        cameraExecutor = Executors.newSingleThreadExecutor()
        bgExecutor = Executors.newSingleThreadExecutor()

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                eventSink = sink
            }
            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        cameraExecutor.shutdown()
        bgExecutor.shutdown()
        releaseCamera()
    }

    // ─────────────────────────────────────────────
    // ActivityAware lifecycle
    // ─────────────────────────────────────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityBinding = binding
    }

    override fun onDetachedFromActivity() {
        activityBinding = null
    }

    // ─────────────────────────────────────────────
    // MethodChannel handler
    // ─────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initCamera"      -> handleInitCamera(call, result)
            "startPreview"    -> handleStartPreview(result)
            "stopPreview"     -> handleStopPreview(result)
            "setPreset"       -> handleSetPreset(call, result)
            "switchLens"      -> handleSwitchLens(call, result)
            "takePhoto"       -> handleTakePhoto(call, result)
            "setZoom"         -> handleSetZoom(call, result)
            "setExposure"     -> handleSetExposure(call, result)
            "setFlash"        -> handleSetFlash(call, result)
            "startRecording"   -> handleStartRecording(result)
            "stopRecording"    -> handleStopRecording(result)
            "dispose"          -> handleDispose(result)
            "readImageBytes"   -> handleReadImageBytes(call, result)
            "writeImageBytes"  -> handleWriteImageBytes(call, result)
            else               -> result.notImplemented()
        }
    }

    // ─────────────────────────────────────────────
    // initCamera
    // ─────────────────────────────────────────────

    private fun handleInitCamera(call: MethodCall, result: MethodChannel.Result) {
        val lensArg = call.argument<String>("lens") ?: "back"
        lensFacing = if (lensArg == "front") CameraSelector.LENS_FACING_FRONT
                     else CameraSelector.LENS_FACING_BACK

        val context = flutterPluginBinding.applicationContext
        val owner = lifecycleOwner

        if (owner == null) {
            result.error("NO_ACTIVITY", "Activity not attached", null)
            return
        }

        // Create Flutter texture on main thread
        val entry = flutterPluginBinding.textureRegistry.createSurfaceTexture()
        textureEntry = entry
        surfaceTexture = entry.surfaceTexture()

        bgExecutor.execute {
            try {
                val provider = ProcessCameraProvider.getInstance(context).get()
                cameraProvider = provider

                val mainExecutor = ContextCompat.getMainExecutor(context)
                mainExecutor.execute {
                    try {
                        bindCameraUseCases(owner)
                        result.success(mapOf("textureId" to entry.id()))
                        sendEvent("onCameraReady", emptyMap<String, Any>())
                    } catch (e: Exception) {
                        Log.e(TAG, "bindCameraUseCases failed", e)
                        result.error("CAMERA_INIT_FAILED", e.message, null)
                        sendEvent("onError", mapOf("message" to (e.message ?: "Unknown error")))
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "initCamera failed", e)
                val mainExecutor = ContextCompat.getMainExecutor(context)
                mainExecutor.execute {
                    result.error("CAMERA_INIT_FAILED", e.message, null)
                    sendEvent("onError", mapOf("message" to (e.message ?: "Unknown error")))
                }
            }
        }
    }

    private fun bindCameraUseCases(owner: LifecycleOwner) {
        val provider = cameraProvider ?: return
        val st = surfaceTexture ?: return

        val cameraSelector = CameraSelector.Builder()
            .requireLensFacing(lensFacing)
            .build()

        preview = Preview.Builder().build().also { prev ->
            prev.setSurfaceProvider { request ->
                st.setDefaultBufferSize(
                    request.resolution.width,
                    request.resolution.height
                )
                val surface = Surface(st)
                request.provideSurface(surface, cameraExecutor) { }
            }
        }

        imageCapture = ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
            .build()

        val recorder = Recorder.Builder()
            .setQualitySelector(QualitySelector.from(Quality.HIGHEST))
            .build()
        videoCapture = VideoCapture.withOutput(recorder)

        provider.unbindAll()
        camera = provider.bindToLifecycle(
            owner,
            cameraSelector,
            preview,
            imageCapture,
            videoCapture
        )
    }

    // ─────────────────────────────────────────────
    // startPreview / stopPreview
    // ─────────────────────────────────────────────

    private fun handleStartPreview(result: MethodChannel.Result) {
        result.success(null)
    }

    private fun handleStopPreview(result: MethodChannel.Result) {
        try {
            cameraProvider?.unbind(preview)
            result.success(null)
        } catch (e: Exception) {
            result.error("STOP_PREVIEW_FAILED", e.message, null)
        }
    }

    // ─────────────────────────────────────────────
    // setPreset
    // ─────────────────────────────────────────────

    @Suppress("UNCHECKED_CAST")
    private fun handleSetPreset(call: MethodCall, result: MethodChannel.Result) {
        val preset = call.argument<Map<*, *>>("preset")
        currentPresetJson = preset
        Log.d(TAG, "setPreset: ${preset?.get("id")}")
        result.success(null)
    }

    // ─────────────────────────────────────────────
    // switchLens
    // ─────────────────────────────────────────────

    private fun handleSwitchLens(call: MethodCall, result: MethodChannel.Result) {
        val lens = call.argument<String>("lens") ?: "back"
        lensFacing = if (lens == "front") CameraSelector.LENS_FACING_FRONT
                     else CameraSelector.LENS_FACING_BACK

        val owner = lifecycleOwner
        if (owner == null) {
            result.error("NO_ACTIVITY", "Activity not attached", null)
            return
        }
        try {
            bindCameraUseCases(owner)
            result.success(null)
        } catch (e: Exception) {
            result.error("SWITCH_LENS_FAILED", e.message, null)
        }
    }

    // ─────────────────────────────────────────────
    // takePhoto — saves to public DCIM/DAZZ via MediaStore
    // ─────────────────────────────────────────────

    private fun handleTakePhoto(call: MethodCall, result: MethodChannel.Result) {
        val capture = imageCapture
        if (capture == null) {
            result.error("NOT_INITIALIZED", "Camera not initialized", null)
            return
        }

        val context = flutterPluginBinding.applicationContext
        val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        val displayName = "DAZZ_${timestamp}.jpg"

        val outputOptions: ImageCapture.OutputFileOptions

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10+ — use MediaStore (no WRITE_EXTERNAL_STORAGE needed)
            val contentValues = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
                put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_DCIM}/$DAZZ_ALBUM")
            }
            outputOptions = ImageCapture.OutputFileOptions.Builder(
                context.contentResolver,
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                contentValues
            ).build()
        } else {
            // Android 9 and below — write to DCIM/DAZZ directly
            val dcimDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM)
            val dazzDir = File(dcimDir, DAZZ_ALBUM).apply { mkdirs() }
            val photoFile = File(dazzDir, displayName)
            outputOptions = ImageCapture.OutputFileOptions.Builder(photoFile).build()
        }

        capture.takePicture(
            outputOptions,
            cameraExecutor,
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                    val savedUri = output.savedUri?.toString() ?: ""
                    Log.d(TAG, "Photo saved: $savedUri")
                    val mainExecutor = ContextCompat.getMainExecutor(context)
                    mainExecutor.execute {
                        sendEvent("onPhotoCaptured", mapOf("filePath" to savedUri))
                        result.success(mapOf("filePath" to savedUri))
                    }
                }
                override fun onError(exception: ImageCaptureException) {
                    Log.e(TAG, "takePhoto failed", exception)
                    val mainExecutor = ContextCompat.getMainExecutor(context)
                    mainExecutor.execute {
                        result.error("CAPTURE_FAILED", exception.message, null)
                    }
                }
            }
        )
    }

    // ─────────────────────────────────────────────
    // setZoom / setExposure / setFlash
    // ─────────────────────────────────────────────

    private fun handleSetZoom(call: MethodCall, result: MethodChannel.Result) {
        val zoom = call.argument<Double>("zoom") ?: 1.0
        try {
            camera?.cameraControl?.setZoomRatio(zoom.toFloat())
            result.success(null)
        } catch (e: Exception) {
            result.error("ZOOM_FAILED", e.message, null)
        }
    }

    private fun handleSetExposure(call: MethodCall, result: MethodChannel.Result) {
        val ev = call.argument<Double>("ev") ?: 0.0
        try {
            camera?.cameraControl?.setExposureCompensationIndex(ev.toInt())
            result.success(null)
        } catch (e: Exception) {
            result.error("EXPOSURE_FAILED", e.message, null)
        }
    }

    private fun handleSetFlash(call: MethodCall, result: MethodChannel.Result) {
        val mode = call.argument<String>("mode") ?: "off"
        try {
            imageCapture?.flashMode = when (mode) {
                "on"   -> ImageCapture.FLASH_MODE_ON
                "auto" -> ImageCapture.FLASH_MODE_AUTO
                else   -> ImageCapture.FLASH_MODE_OFF
            }
            result.success(null)
        } catch (e: Exception) {
            result.error("FLASH_FAILED", e.message, null)
        }
    }

    // ─────────────────────────────────────────────
    // startRecording / stopRecording
    // ─────────────────────────────────────────────

    private fun handleStartRecording(result: MethodChannel.Result) {
        val vc = videoCapture
        if (vc == null) {
            result.error("NOT_INITIALIZED", "Camera not initialized", null)
            return
        }
        if (recording != null) {
            result.success(mapOf("success" to false, "reason" to "already_recording"))
            return
        }

        val context = flutterPluginBinding.applicationContext
        val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        val displayName = "DAZZ_VID_${timestamp}.mp4"

        val fileOutputOptions: FileOutputOptions
        val videoFile: File
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val moviesDir = context.getExternalFilesDir(Environment.DIRECTORY_MOVIES)
                ?: context.filesDir
            videoFile = File(moviesDir, displayName)
        } else {
            val moviesDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES)
            val dazzDir = File(moviesDir, DAZZ_ALBUM).apply { mkdirs() }
            videoFile = File(dazzDir, displayName)
        }
        fileOutputOptions = FileOutputOptions.Builder(videoFile).build()

        recording = vc.output
            .prepareRecording(context, fileOutputOptions)
            .start(cameraExecutor) { event ->
                when (event) {
                    is VideoRecordEvent.Start -> {
                        sendEvent("onRecordingStateChanged", mapOf("isRecording" to true))
                    }
                    is VideoRecordEvent.Finalize -> {
                        if (!event.hasError()) {
                            sendEvent("onVideoRecorded", mapOf("filePath" to videoFile.absolutePath))
                        } else {
                            sendEvent("onError", mapOf("message" to "Recording error: ${event.error}"))
                        }
                        sendEvent("onRecordingStateChanged", mapOf("isRecording" to false))
                        recording = null
                    }
                    else -> {}
                }
            }

        result.success(mapOf("success" to true))
    }

    private fun handleStopRecording(result: MethodChannel.Result) {
        val rec = recording
        if (rec == null) {
            result.error("NOT_RECORDING", "No active recording", null)
            return
        }
        rec.stop()
        result.success(mapOf("filePath" to null))
    }

    // ─────────────────────────────────────────────
    // dispose
    // ─────────────────────────────────────────────

    private fun handleDispose(result: MethodChannel.Result) {
        releaseCamera()
        result.success(null)
    }

    // ─────────────────────────────────────────────
    // readImageBytes / writeImageBytes
    // ─────────────────────────────────────────────

    private fun handleReadImageBytes(call: MethodCall, result: MethodChannel.Result) {
        val uriStr = call.argument<String>("uri") ?: run {
            result.error("INVALID_ARG", "uri is required", null)
            return
        }
        bgExecutor.execute {
            try {
                val uri = android.net.Uri.parse(uriStr)
                val context = flutterPluginBinding.applicationContext
                val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                val mainExec = ContextCompat.getMainExecutor(context)
                mainExec.execute {
                    if (bytes != null) {
                        result.success(mapOf("bytes" to bytes.toList()))
                    } else {
                        result.error("READ_FAILED", "Could not open stream for URI: $uriStr", null)
                    }
                }
            } catch (e: Exception) {
                val mainExec = ContextCompat.getMainExecutor(flutterPluginBinding.applicationContext)
                mainExec.execute { result.error("READ_FAILED", e.message, null) }
            }
        }
    }

    private fun handleWriteImageBytes(call: MethodCall, result: MethodChannel.Result) {
        val uriStr = call.argument<String>("uri") ?: run {
            result.error("INVALID_ARG", "uri is required", null)
            return
        }
        @Suppress("UNCHECKED_CAST")
        val byteList = call.argument<List<Int>>("bytes") ?: run {
            result.error("INVALID_ARG", "bytes is required", null)
            return
        }
        bgExecutor.execute {
            try {
                val uri = android.net.Uri.parse(uriStr)
                val context = flutterPluginBinding.applicationContext
                val bytes = ByteArray(byteList.size) { byteList[it].toByte() }
                context.contentResolver.openOutputStream(uri, "wt")?.use { it.write(bytes) }
                val mainExec = ContextCompat.getMainExecutor(context)
                mainExec.execute { result.success(null) }
            } catch (e: Exception) {
                val mainExec = ContextCompat.getMainExecutor(flutterPluginBinding.applicationContext)
                mainExec.execute { result.error("WRITE_FAILED", e.message, null) }
            }
        }
    }

    // ─────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────

    private fun releaseCamera() {
        recording?.stop()
        recording = null
        cameraProvider?.unbindAll()
        cameraProvider = null
        textureEntry?.release()
        textureEntry = null
        surfaceTexture = null
    }

    private fun sendEvent(type: String, payload: Map<String, Any>) {
        val mainExecutor = ContextCompat.getMainExecutor(flutterPluginBinding.applicationContext)
        mainExecutor.execute {
            eventSink?.success(mapOf("type" to type, "payload" to payload))
        }
    }
}
