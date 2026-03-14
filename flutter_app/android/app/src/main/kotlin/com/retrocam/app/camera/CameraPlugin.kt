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
            "startRecording"  -> handleStartRecording(result)
            "stopRecording"   -> handleStopRecording(result)
            "saveToGallery"   -> handleSaveToGallery(call, result)
            "dispose"         -> handleDispose(result)
            else              -> result.notImplemented()
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
    // takePhoto — saves to app cache first (so Flutter can read/process it),
    // then Flutter calls saveToGallery to copy to MediaStore
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

        // Save to app-private cache dir so Flutter Dart code can read/process the file
        // via dart:io File. After Flutter post-processing, the file is saved to gallery
        // by the saveToGallery method call from Dart.
        val cacheDir = File(context.cacheDir, "dazz_captures").apply { mkdirs() }
        val cacheFile = File(cacheDir, displayName)
        val outputOptions = ImageCapture.OutputFileOptions.Builder(cacheFile).build()

        capture.takePicture(
            outputOptions,
            cameraExecutor,
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                    val filePath = cacheFile.absolutePath
                    Log.d(TAG, "Photo saved to cache: $filePath")
                    val mainExecutor = ContextCompat.getMainExecutor(context)
                    mainExecutor.execute {
                        sendEvent("onPhotoCaptured", mapOf("filePath" to filePath))
                        result.success(mapOf("filePath" to filePath))
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
    // saveToGallery — called from Dart after post-processing
    // Copies processed file from cache to DCIM/DAZZ MediaStore
    // ─────────────────────────────────────────────

    private fun handleSaveToGallery(call: MethodCall, result: MethodChannel.Result) {
        val filePath = call.argument<String>("filePath")
        if (filePath == null) {
            result.error("INVALID_ARG", "filePath is required", null)
            return
        }
        val context = flutterPluginBinding.applicationContext
        val sourceFile = File(filePath)
        if (!sourceFile.exists()) {
            result.error("FILE_NOT_FOUND", "File not found: $filePath", null)
            return
        }
        val cameraId = call.argument<String>("cameraId") ?: ""
        bgExecutor.execute {
            try {
                // 文件名含 cameraId，使相册可按相机分类
                val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
                val displayName = if (cameraId.isNotEmpty()) {
                    "DAZZ_${cameraId}_${timestamp}.jpg"
                } else {
                    sourceFile.name
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    // Step 1: Insert with IS_PENDING=1 (file reserved, invisible to gallery)
                    val contentValues = ContentValues().apply {
                        put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
                        put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                        put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_DCIM}/$DAZZ_ALBUM")
                        put(MediaStore.Images.Media.IS_PENDING, 1)
                    }
                    val uri = context.contentResolver.insert(
                        MediaStore.Images.Media.EXTERNAL_CONTENT_URI, contentValues
                    )
                    Log.d(TAG, "[saveToGallery] MediaStore insert uri=$uri")
                    if (uri != null) {
                        // Step 2: Write bytes
                        context.contentResolver.openOutputStream(uri)?.use { os ->
                            sourceFile.inputStream().use { it.copyTo(os) }
                        }
                        // Step 3: CRITICAL — Clear IS_PENDING so photo_manager can see the file
                        val updateValues = ContentValues().apply {
                            put(MediaStore.Images.Media.IS_PENDING, 0)
                        }
                        val rows = context.contentResolver.update(uri, updateValues, null, null)
                        Log.d(TAG, "[saveToGallery] IS_PENDING cleared, rows=$rows, uri=$uri")
                        val mainExecutor = ContextCompat.getMainExecutor(context)
                        mainExecutor.execute { result.success(mapOf("success" to true, "uri" to uri.toString())) }
                    } else {
                        Log.e(TAG, "[saveToGallery] ContentResolver.insert returned null")
                        val mainExecutor = ContextCompat.getMainExecutor(context)
                        mainExecutor.execute { result.error("GALLERY_SAVE_FAILED", "ContentResolver insert returned null", null) }
                    }
                } else {
                    val dcimDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM)
                    val dazzDir = File(dcimDir, DAZZ_ALBUM).apply { mkdirs() }
                    val destFile = File(dazzDir, displayName)
                    sourceFile.copyTo(destFile, overwrite = true)
                    Log.d(TAG, "Saved to gallery: ${destFile.absolutePath}")
                    // Trigger MediaScanner so photo_manager can see the file immediately
                    android.media.MediaScannerConnection.scanFile(
                        context,
                        arrayOf(destFile.absolutePath),
                        arrayOf("image/jpeg")
                    ) { _, _ -> }
                    val mainExecutor = ContextCompat.getMainExecutor(context)
                    mainExecutor.execute { result.success(mapOf("success" to true, "uri" to destFile.absolutePath)) }
                }
                // Clean up cache file
                sourceFile.delete()
            } catch (e: Exception) {
                Log.e(TAG, "saveToGallery failed", e)
                val mainExecutor = ContextCompat.getMainExecutor(context)
                mainExecutor.execute { result.error("GALLERY_SAVE_FAILED", e.message, null) }
            }
        }
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
