package com.retrocam.app.camera

import android.content.ContentValues
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.SurfaceTexture
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.media.MediaMetadataRetriever
import android.util.Log
import android.view.Surface
import android.media.ExifInterface
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CameraCharacteristics
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.CaptureRequestOptions
import android.util.Size
import androidx.camera.core.*
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.SurfaceOrientedMeteringPointFactory
import androidx.camera.core.resolutionselector.ResolutionFilter
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
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
import com.retrocam.app.camera.CaptureGLProcessor
import io.flutter.view.TextureRegistry
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class CameraPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private var captureProcessor: CaptureGLProcessor? = null

    companion object {
        private const val TAG = "CameraPlugin"
        private const val METHOD_CHANNEL = "com.retrocam.app/camera_control"
        private const val EVENT_CHANNEL = "com.retrocam.app/camera_events"
        private const val DAZZ_ALBUM = "DAZZ"
        private const val FRAME_BITMAP_CACHE_MAX = 6
        private val frameBitmapCache = LinkedHashMap<String, Bitmap>()
        private val frameBitmapLru = ArrayList<String>()
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
    private var imageAnalysis: ImageAnalysis? = null
    private var imageCapture: ImageCapture? = null
    /** 当前绑定摄像头的传感器调试信息，由 readActiveCameraInfo() 填充 */
    private var activeCameraDebugInfo: Map<String, Any> = emptyMap()
    private var videoCapture: VideoCapture<Recorder>? = null
    private var recording: Recording? = null
    @Volatile private var isPhotoCaptureInFlight: Boolean = false
    @Volatile private var pendingStopPreview: Boolean = false
    private var supportsLivePhoto: Boolean = false
    private var lensFacing: Int = CameraSelector.LENS_FACING_BACK
    private var previewStreamWidth: Int = 0
    private var previewStreamHeight: Int = 0

    // Flutter texture
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var surfaceTexture: SurfaceTexture? = null

    // Executors
    private lateinit var cameraExecutor: ExecutorService
    private lateinit var bgExecutor: ExecutorService

    // Filter state
    private var currentPresetJson: Map<*, *>? = null
    private var cachedRenderParams: Map<String, Any> = emptyMap()
    private var cachedRenderVersion: Int = 0
    private var currentSharpenLevel: Float = 0.5f
    private var currentPreviewResolution: String = "720p"
    private var currentCameraId: String = ""
    @Volatile private var pendingShotStartNs: Long = 0L
    @Volatile private var pendingShotLevel: Float = 0.5f
    // ── 缓存 lens 参数，供 switchLens 后重新应用 ──
    private var cachedLensFisheyeMode: Boolean = false
    private var cachedLensVignette: Double = 0.0
    private var cachedLensDistortion: Double = 0.0
    // GL Renderer
    private var glRenderer: CameraGLRenderer? = null
    // ── 用于 switchLens 等待新 renderer 就绪 ──
    @Volatile private var rendererReadyLatch: CountDownLatch? = null
    // ── 内存拍摄缓存：takePhoto 内存模式拿到的字节，供 processWithGpu 直接使用 ──
    @Volatile private var pendingJpegBytes: ByteArray? = null
    @Volatile private var pendingRotationDegrees: Int = 0
    @Volatile private var pendingIsFrontCamera: Boolean = false
    @Volatile private var mirrorFrontCameraEnabled: Boolean = true
    @Volatile private var mirrorBackCameraEnabled: Boolean = false
    // 当前镜头朝向（LENS_FACING_BACK / LENS_FACING_FRONT）
    private var currentLensPosition: Int = CameraSelector.LENS_FACING_BACK
    // 持久化闪光灯状态，避免重建 ImageCapture 后丢失
    private var currentFlashMode: Int = ImageCapture.FLASH_MODE_OFF
    @Volatile private var lastRuntimeStatsAtMs: Long = 0L
    private val perfPrefs: SharedPreferences by lazy {
        flutterPluginBinding.applicationContext.getSharedPreferences(
            "dazz_capture_perf",
            Context.MODE_PRIVATE
        )
    }

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
            "updateRenderParams" -> handleUpdateRenderParams(call, result)
            "switchLens"      -> handleSwitchLens(call, result)
            "takePhoto"       -> handleTakePhoto(call, result)
            "setZoom"         -> handleSetZoom(call, result)
            "setExposure"     -> handleSetExposure(call, result)
            "setFocus"        -> handleSetFocus(call, result)
            "setMirrorFrontCamera" -> handleSetMirrorFrontCamera(call, result)
            "setMirrorBackCamera"  -> handleSetMirrorBackCamera(call, result)
            "setFlash"        -> handleSetFlash(call, result)
            "setWhiteBalance" -> handleSetWhiteBalance(call, result)
            "setSharpen"         -> handleSetSharpen(call, result)
            "updateLensParams"   -> handleUpdateLensParams(call, result)
            "syncRuntimeState"   -> handleSyncRuntimeState(call, result)
            "startRecording"     -> handleStartRecording(result)
            "stopRecording"      -> handleStopRecording(result)
            "saveToGallery"      -> handleSaveToGallery(call, result)
            "saveMotionPhoto"    -> handleSaveMotionPhoto(call, result)
            "replaceGalleryImage"-> handleReplaceGalleryImage(call, result)
            "composeOverlay"     -> handleComposeOverlay(call, result)
            "blendDoubleExposure"-> handleBlendDoubleExposure(call, result)
            "dispose"            -> handleDispose(result)
            "processWithGpu"   -> {
                if (captureProcessor == null) {
                    captureProcessor = CaptureGLProcessor(flutterPluginBinding.applicationContext)
                }
                handleProcessWithGpu(call, result)
            }
            else                 -> result.notImplemented()
        }
    }

    // ─────────────────────────────────────────────
    // initCamera
    // ─────────────────────────────────────────────

    private fun handleInitCamera(call: MethodCall, result: MethodChannel.Result) {
        val lensArg = call.argument<String>("lens") ?: "back"
        currentPreviewResolution = call.argument<String>("resolution") ?: "720p"
        lensFacing = if (lensArg == "front") CameraSelector.LENS_FACING_FRONT
                     else CameraSelector.LENS_FACING_BACK
        currentLensPosition = lensFacing

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
                        // ── FIX: 等待新 renderer 就绪后再返回 ──────────────
                        // bindCameraUseCases 中 SurfaceProvider 回调在 cameraExecutor 上异步执行，
                        // 如果立即返回 result.success，Dart 层并行执行的 setCamera()
                        // 可能在 renderer 创建前执行（glRenderer 为 null），参数丢失。
                        // 等待 latch 确保 renderer 就绪 + reapplyPresetToRenderer 完成。
                        val latch = rendererReadyLatch
                        val textureId = entry.id()
                        bgExecutor.execute {
                            try {
                                val ready = latch?.await(5, java.util.concurrent.TimeUnit.SECONDS) ?: true
                                if (!ready) {
                                    Log.w(TAG, "initCamera: renderer ready timeout (5s)")
                                }
                                mainExecutor.execute {
                                    result.success(mapOf("textureId" to textureId))
                                    sendEvent("onCameraReady", activeCameraDebugInfo)
                                }
                            } catch (e: Exception) {
                                mainExecutor.execute {
                                    result.error("CAMERA_INIT_FAILED", e.message, null)
                                    sendEvent("onError", mapOf("message" to (e.message ?: "Unknown error")))
                                }
                            }
                        }
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

    /**
     * 在高品质模式下，通过 Camera2CameraInfo 查询所有后置摄像头的传感器像素阵列大小，
     * 选择像素数最大的主摄，避免 CameraX 默认选到超广角或长焦镜头。
     */
    @androidx.camera.camera2.interop.ExperimentalCamera2Interop
    private fun buildCameraSelector(provider: androidx.camera.lifecycle.ProcessCameraProvider): CameraSelector {
        if (lensFacing == CameraSelector.LENS_FACING_FRONT) {
            return CameraSelector.DEFAULT_FRONT_CAMERA
        }
        // 高品质模式：选最大传感器的后置摄像头
        if (currentSharpenLevel >= 0.7f) {
            try {
                val backCameras = provider.availableCameraInfos.filter { info ->
                    Camera2CameraInfo.from(info).getCameraCharacteristic(
                        CameraCharacteristics.LENS_FACING
                    ) == CameraCharacteristics.LENS_FACING_BACK
                }
                val bestCamera = backCameras.maxByOrNull { info ->
                    val size = Camera2CameraInfo.from(info).getCameraCharacteristic(
                        CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE
                    )
                    (size?.width?.toLong() ?: 0L) * (size?.height?.toLong() ?: 0L)
                }
                if (bestCamera != null) {
                    val camId = Camera2CameraInfo.from(bestCamera).cameraId
                    Log.d(TAG, "高品质模式：选择最大传感器摄像头 ID=$camId")
                    return CameraSelector.Builder()
                        .addCameraFilter { cams ->
                            cams.filter { Camera2CameraInfo.from(it).cameraId == camId }
                        }
                        .build()
                }
            } catch (e: Exception) {
                Log.w(TAG, "最大传感器摄像头选择失败，回落到默认后置: ${e.message}")
            }
        }
        return CameraSelector.Builder()
            .requireLensFacing(lensFacing)
            .build()
    }

    private fun bindCameraUseCases(owner: LifecycleOwner) {
        val provider = cameraProvider ?: return
        val st = surfaceTexture ?: return
        @Suppress("UnsafeOptInUsageError")
        val cameraSelector = buildCameraSelector(provider)

        // ── 创建 latch，供 handleSwitchLens 等待新 renderer 就绪 ──
        val latch = CountDownLatch(1)
        rendererReadyLatch = latch

        val previewBuilder = Preview.Builder()
        val targetPreviewSize = when (currentPreviewResolution) {
            "1080p" -> Size(1920, 1080)
            else -> Size(1280, 720)
        }
        previewBuilder.setResolutionSelector(
            ResolutionSelector.Builder()
                .setResolutionStrategy(ResolutionStrategy.HIGHEST_AVAILABLE_STRATEGY)
                .setResolutionFilter { supportedSizes, _ ->
                    supportedSizes.sortedWith(
                        compareBy<Size> {
                            val area = it.width.toLong() * it.height.toLong()
                            val targetArea =
                                targetPreviewSize.width.toLong() * targetPreviewSize.height.toLong()
                            kotlin.math.abs(area - targetArea)
                        }.thenBy {
                            kotlin.math.abs(it.width - targetPreviewSize.width) +
                                kotlin.math.abs(it.height - targetPreviewSize.height)
                        }
                    )
                }
                .build()
        )

        preview = previewBuilder.build().also { prev ->
            // GL 渲染模式：相机帧 → CameraGLRenderer（EGL + 着色器）→ Flutter SurfaceTexture
            prev.setSurfaceProvider(cameraExecutor) { request ->
                val w = request.resolution.width
                val h = request.resolution.height
                previewStreamWidth = w
                previewStreamHeight = h

                // 在 cameraExecutor 上初始化 GL（initialize 内部用 glExecutor 异步完成，
                // 并通过 CountDownLatch 同步等待，cameraExecutor 上阻塞是安全的）
                val renderer = CameraGLRenderer(st, flutterPluginBinding.applicationContext)
                renderer.initialize(w, h)
                glRenderer = renderer
                applyPreviewMirrorToRenderer(renderer)

                // ── FIX: 切换摄像头后重新应用缓存的 preset 参数 ──────────
                // switchLens 会重建 renderer，但不会重新调用 setPreset，
                // 导致新 renderer 的所有 uniform 参数为默认值（无效果）。
                reapplyPresetToRenderer(renderer)

                // ── 通知 handleSwitchLens：新 renderer 已就绪 ──
                latch.countDown()

                val inputSurface = renderer.getInputSurface()
                if (inputSurface != null) {
                    Log.d("CameraPlugin", "GL renderer ready, providing GL input surface")
                    request.provideSurface(
                        inputSurface,
                        cameraExecutor
                    ) {
                    // 只有当 glRenderer 仍然是本次创建的 renderer 时才清空
                    // 避免 bindCameraUseCases 重新调用后，旧的 Surface 释放 callback 把新的 glRenderer 清空
                    renderer.release()
                    if (glRenderer === renderer) glRenderer = null
                }
                } else {
                    // GL 初始化失败，降级到直通模式
                    Log.w("CameraPlugin", "GL renderer init failed, falling back to direct mode")
                    st.setDefaultBufferSize(w, h)
                    val surface = Surface(st)
                    request.provideSurface(
                        surface,
                        ContextCompat.getMainExecutor(flutterPluginBinding.applicationContext)
                    ) { }
                }
            }
        }

        imageCapture = buildImageCapture(currentSharpenLevel)
        imageCapture?.flashMode = currentFlashMode
        imageAnalysis = ImageAnalysis.Builder()
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .build().also { analysis ->
                analysis.setAnalyzer(bgExecutor) { image ->
                    analyzeRuntimeLuma(image)
                }
            }

        val recorder = Recorder.Builder()
            .setQualitySelector(QualitySelector.from(Quality.HIGHEST))
            .build()
        val candidateVideoCapture = VideoCapture.withOutput(recorder)
        provider.unbindAll()
        try {
            camera = provider.bindToLifecycle(
                owner,
                cameraSelector,
                preview,
                imageCapture,
                candidateVideoCapture,
                imageAnalysis
            )
            videoCapture = candidateVideoCapture
            supportsLivePhoto = true
        } catch (e: Exception) {
            Log.w(TAG, "bindCameraUseCases: live photo bind rejected, fallback to photo-only: ${e.message}")
            provider.unbindAll()
            camera = provider.bindToLifecycle(
                owner,
                cameraSelector,
                preview,
                imageCapture,
                imageAnalysis
            )
            videoCapture = null
            supportsLivePhoto = false
        }
        // 绑定成功后读取当前摄像头的传感器信息，供 Debug 面板显示
        @Suppress("UnsafeOptInUsageError")
        readActiveCameraInfo()
    }

    /** 读取当前绑定摄像头的传感器信息，存入 activeCameraDebugInfo */
    @androidx.camera.camera2.interop.ExperimentalCamera2Interop
    private fun readActiveCameraInfo() {
        try {
            val cam = camera ?: return
            val info = Camera2CameraInfo.from(cam.cameraInfo)
            val camId = info.cameraId
            val sensorSize = info.getCameraCharacteristic(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE)
            val focalLengths = info.getCameraCharacteristic(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
            val facing = info.getCameraCharacteristic(CameraCharacteristics.LENS_FACING)
            val facingStr = when (facing) {
                CameraCharacteristics.LENS_FACING_BACK -> "back"
                CameraCharacteristics.LENS_FACING_FRONT -> "front"
                CameraCharacteristics.LENS_FACING_EXTERNAL -> "external"
                else -> "unknown"
            }
            val sensorW = sensorSize?.width ?: 0
            val sensorH = sensorSize?.height ?: 0
            val focalStr = focalLengths?.joinToString("/") { String.format("%.1f", it) } ?: "?"
            activeCameraDebugInfo = mapOf(
                "cameraId" to camId,
                "sensorSize" to "${sensorW}×${sensorH}",
                "sensorMp" to String.format("%.1f", sensorW * sensorH / 1_000_000.0),
                "focalLengths" to focalStr,
                "facing" to facingStr,
                "previewWidth" to previewStreamWidth,
                "previewHeight" to previewStreamHeight,
                "previewAspectRatio" to (
                    if (previewStreamWidth > 0 && previewStreamHeight > 0) {
                        minOf(previewStreamWidth, previewStreamHeight).toFloat() /
                            maxOf(previewStreamWidth, previewStreamHeight).toFloat()
                    } else {
                        0.75f
                    }
                ),
                "brand" to Build.BRAND,
                "model" to Build.MODEL,
                "manufacturer" to Build.MANUFACTURER,
                "device" to Build.DEVICE,
                "supportsLivePhoto" to supportsLivePhoto
            )
            Log.d(TAG, "Active camera: id=$camId sensor=${sensorW}×${sensorH} focal=$focalStr facing=$facingStr")
        } catch (e: Exception) {
            Log.w(TAG, "readActiveCameraInfo failed: ${e.message}")
        }
    }

    /** 通过预览帧 Y 平面估算环境亮度，周期回传到 Flutter。 */
    private fun analyzeRuntimeLuma(image: ImageProxy) {
        try {
            val now = System.currentTimeMillis()
            if (now - lastRuntimeStatsAtMs < 350L) return
            lastRuntimeStatsAtMs = now

            val plane = image.planes.firstOrNull() ?: return
            val buffer = plane.buffer
            val rowStride = plane.rowStride
            val pixelStride = plane.pixelStride
            val width = image.width
            val height = image.height
            if (width <= 0 || height <= 0) return

            val start = buffer.position()
            var sum = 0L
            var count = 0L
            val stepX = 8
            val stepY = 8
            for (y in 0 until height step stepY) {
                val rowBase = y * rowStride
                for (x in 0 until width step stepX) {
                    val idx = rowBase + x * pixelStride
                    if (idx >= 0 && idx < buffer.limit()) {
                        sum += (buffer.get(idx).toInt() and 0xFF)
                        count++
                    }
                }
            }
            buffer.position(start)
            if (count <= 0) return
            val luma = sum.toDouble() / count.toDouble() // 0~255
            val lightIndex = ((170.0 - luma) / 28.0).coerceIn(0.0, 6.0) // 越暗越大
            val normalizedLuma = (luma / 255.0).coerceIn(0.0, 1.0)
            val runtime = mapOf(
                "rtLuma" to String.format(Locale.US, "%.4f", normalizedLuma),
                "rtLightIndex" to String.format(Locale.US, "%.2f", lightIndex),
            )
            activeCameraDebugInfo = activeCameraDebugInfo + runtime
            sendEvent("onCameraRuntimeStats", runtime)
        } catch (_: Exception) {
        } finally {
            image.close()
        }
    }

    // ─────────────────────────────────────────────
    // startPreview / stopPreview
    // ─────────────────────────────────────────────

    private fun handleStartPreview(result: MethodChannel.Result) {
        glRenderer?.let { reapplyPresetToRenderer(it) }
        scheduleRendererStateReplay("startPreview")
        result.success(null)
    }

    private fun handleStopPreview(result: MethodChannel.Result) {
        try {
            stopPreviewSession()
            result.success(null)
        } catch (e: Exception) {
            result.error("STOP_PREVIEW_FAILED", e.message, null)
        }
    }

    private fun stopPreviewSession() {
        if (isPhotoCaptureInFlight || recording != null) {
            pendingStopPreview = true
            recording?.stop()
            return
        }
        pendingStopPreview = false
        cameraProvider?.unbindAll()
        camera = null
        preview = null
        imageCapture = null
        imageAnalysis = null
        videoCapture = null
        supportsLivePhoto = false
    }

    // ─────────────────────────────────────────────
    // setPreset
    // ─────────────────────────────────────────────

    @Suppress("UNCHECKED_CAST")
    private fun handleSetPreset(call: MethodCall, result: MethodChannel.Result) {
        val preset = call.argument<Map<*, *>>("preset")
        val cameraId = (preset?.get("cameraId") as? String) ?: (preset?.get("id") as? String) ?: ""
        val cameraChanged = cameraId.isNotEmpty() && cameraId != currentCameraId
        if (cameraId.isNotEmpty()) {
            if (cameraChanged) {
                cachedRenderParams = emptyMap()
                cachedRenderVersion = 0
                cachedLensFisheyeMode = false
                cachedLensVignette = 0.0
                cachedLensDistortion = 0.0
            }
            currentPresetJson = preset
            currentCameraId = cameraId
        }
        Log.d(TAG, "setPreset: cameraId=$cameraId")

        if (preset != null) {
            val params = mutableMapOf<String, Any>()

            // 1. 从 preset 顶层读取通用参数（旧路径兼容）
            (preset["contrast"]            as? Number)?.let { params["contrast"]            = it }
            (preset["saturation"]          as? Number)?.let { params["saturation"]          = it }
            (preset["temperatureShift"]    as? Number)?.let { params["temperatureShift"]    = it }
            (preset["chromaticAberration"] as? Number)?.let { params["chromaticAberration"] = it }
            (preset["noise"]               as? Number)?.let { params["noise"]               = it }
            (preset["vignette"]            as? Number)?.let { params["vignette"]            = it }
            (preset["grain"]               as? Number)?.let { params["grain"]               = it }
            (preset["sharpen"]             as? Number)?.let { params["sharpen"]             = it }

            // 3. 从 defaultLook 子对象读取完整参数（新路径，由 Flutter setCamera() 传入）
            // 注意：JSON 键名与 Shader uniform 名可能不同，需要映射（与 iOS 侧保持一致）
            @Suppress("UNCHECKED_CAST")
            val look = preset["defaultLook"] as? Map<*, *>
            if (look != null) {
                // 通用参数（直接映射）
                (look["contrast"]            as? Number)?.let { params["contrast"]            = it }
                (look["saturation"]          as? Number)?.let { params["saturation"]          = it }
                (look["vignette"]            as? Number)?.let { params["vignette"]            = it }
                (look["chromaticAberration"] as? Number)?.let { params["chromaticAberration"] = it }
                (look["grain"]               as? Number)?.let { params["grain"]               = it }
                // 字段名映射（JSON 键名 → Shader uniform 名）
                (look["temperature"]         as? Number)?.let { params["temperatureShift"]    = it }  // temperature → temperatureShift
                (look["tint"]                as? Number)?.let { params["tintShift"]           = it }  // tint → tintShift
                (look["halation"]            as? Number)?.let { params["halationAmount"]      = it }  // halation → halationAmount
                (look["bloom"]               as? Number)?.let { params["bloomAmount"]         = it }  // bloom → bloomAmount
                (look["sharpness"]           as? Number)?.let { params["sharpen"]             = it }  // sharpness → sharpen
                // ── FIX: Lightroom 风格曲线参数（原来缺失，导致链路断裂）──────────────────────
                (look["highlights"]          as? Number)?.let { params["highlights"]          = it }  // 高光压缩/提亮
                (look["shadows"]             as? Number)?.let { params["shadows"]             = it }  // 阴影压缩/提亮
                (look["whites"]              as? Number)?.let { params["whites"]              = it }  // 白场偏移
                (look["blacks"]              as? Number)?.let { params["blacks"]              = it }  // 黑场偏移
                (look["clarity"]             as? Number)?.let { params["clarity"]             = it }  // 中间调微对比度
                (look["vibrance"]            as? Number)?.let { params["vibrance"]            = it }  // 智能饱和度
                // ── FIX: noiseAmount（JSON 键名 noise → Shader uniform noiseAmount）──────────
                (look["noise"]               as? Number)?.let { params["noiseAmount"]         = it }  // noise → noiseAmount
                (look["noiseAmount"]         as? Number)?.let { params["noiseAmount"]         = it }  // noiseAmount 直接映射（兼容两种键名）
                // FQS/CPM35 专有参数（直接映射）
                (look["colorBiasR"]          as? Number)?.let { params["colorBiasR"]          = it }
                (look["colorBiasG"]          as? Number)?.let { params["colorBiasG"]          = it }
                (look["colorBiasB"]          as? Number)?.let { params["colorBiasB"]          = it }
                (look["grainSize"]           as? Number)?.let { params["grainSize"]           = it }
                (look["luminanceNoise"]      as? Number)?.let { params["luminanceNoise"]      = it }
                (look["chromaNoise"]         as? Number)?.let { params["chromaNoise"]         = it }
                (look["highlightWarmAmount"] as? Number)?.let { params["highlightWarmAmount"] = it }
                // Inst C 专用字段（直接映射）
                (look["highlightRolloff"]    as? Number)?.let { params["highlightRolloff"]    = it }
                (look["highlightRolloff2"]   as? Number)?.let { params["highlightRolloff2"]   = it }
                (look["paperTexture"]        as? Number)?.let { params["paperTexture"]        = it }
                (look["edgeFalloff"]         as? Number)?.let { params["edgeFalloff"]         = it }
                (look["exposureVariation"]   as? Number)?.let { params["exposureVariation"]   = it }
                (look["cornerWarmShift"]     as? Number)?.let { params["cornerWarmShift"]     = it }
                (look["toneCurveStrength"]   as? Number)?.let { params["toneCurveStrength"]   = it }
                (look["lutStrength"]         as? Number)?.let { params["lutStrength"]         = it }
                (look["baseLut"]             as? String)?.let { params["baseLut"]             = it }
                // 用户曝光补偿（胶囊区拖条，必须在此映射，否则预览无效）
                (look["exposureOffset"]       as? Number)?.let { params["exposureOffset"]       = it }
                // SQC 专用字段
                (look["centerGain"]           as? Number)?.let { params["centerGain"]           = it }
                (look["developmentSoftness"]  as? Number)?.let { params["developmentSoftness"]  = it }
                (look["chemicalIrregularity"] as? Number)?.let { params["chemicalIrregularity"] = it }
                val skinProtect = look["skinHueProtect"]
                if (skinProtect is Boolean) params["skinHueProtect"] = if (skinProtect) 1.0 else 0.0
                else (skinProtect as? Number)?.let { params["skinHueProtect"] = it }
                (look["skinSatProtect"]       as? Number)?.let { params["skinSatProtect"]       = it }
                (look["skinLumaSoften"]       as? Number)?.let { params["skinLumaSoften"]       = it }
                (look["skinRedLimit"]         as? Number)?.let { params["skinRedLimit"]         = it }
            }

            if (params.isNotEmpty()) {
                glRenderer?.updateParams(params)
            }
            // 2. 先 updateParams 设置参数，再 setCameraId 切换 Shader
            // 顺序很重要：setCameraId 在 GL 线程异步执行，如果先调用它会导致竞态条件（参数被重置）
            if (cameraId.isNotEmpty()) {
                glRenderer?.setCameraId(cameraId)
            }
        }
        result.success(null)
    }

    // ─────────────────────────────────────────────
    // updateRenderParams — update shader params only (do not mutate preset cache)
    // ─────────────────────────────────────────────
    private fun handleUpdateRenderParams(call: MethodCall, result: MethodChannel.Result) {
        val params = call.argument<Map<String, Any>>("params") ?: emptyMap()
        val version = (call.argument<Int>("version") ?: cachedRenderVersion).coerceAtLeast(0)
        if (params.isNotEmpty()) {
            cachedRenderParams = params
            glRenderer?.updateParams(params)
        }
        cachedRenderVersion = version
        result.success(
            mapOf(
                "appliedVersion" to cachedRenderVersion,
                "rendererReady" to (glRenderer != null)
            )
        )
    }

    // ─────────────────────────────────────────────
    // switchLens
    // ─────────────────────────────────────────────

    private fun handleSwitchLens(call: MethodCall, result: MethodChannel.Result) {
        val lens = call.argument<String>("lens") ?: "back"
        lensFacing = if (lens == "front") CameraSelector.LENS_FACING_FRONT
                     else CameraSelector.LENS_FACING_BACK
        currentLensPosition = lensFacing // sync for takePhoto isFront detection

        val owner = lifecycleOwner
        if (owner == null) {
            result.error("NO_ACTIVITY", "Activity not attached", null)
            return
        }
        try {
            bindCameraUseCases(owner)

            // ── FIX: 等待新 renderer 就绪后再返回，避免 Dart 层竞态 ────────
            // bindCameraUseCases 中 SurfaceProvider 回调在 cameraExecutor 上异步执行，
            // 如果立即返回 result.success，Dart 层的 setCamera() + updateLensParams()
            // 会在新 renderer 创建前执行，导致参数发到 null。
            // 在 bgExecutor 上等待 latch（不阻塞主线程），完成后在主线程回调 result。
            val latch = rendererReadyLatch
            val mainExecutor = ContextCompat.getMainExecutor(flutterPluginBinding.applicationContext)
            bgExecutor.execute {
                try {
                    // 等待新 renderer 就绪，最多 5 秒超时
                    val ready = latch?.await(5, java.util.concurrent.TimeUnit.SECONDS) ?: true
                    if (!ready) {
                        Log.w(TAG, "switchLens: renderer ready timeout (5s)")
                    }
                    mainExecutor.execute { result.success(null) }
                } catch (e: Exception) {
                    mainExecutor.execute { result.error("SWITCH_LENS_FAILED", e.message, null) }
                }
            }
        } catch (e: Exception) {
            result.error("SWITCH_LENS_FAILED", e.message, null)
        }
    }

    // ─────────────────────────────────────────────
    // takePhoto — 内存模式：使用 OnImageCapturedCallback 直接拿到 ImageProxy 字节，
    // 跳过第一次磁盘写入，减少一次文件 IO 耗时（~100-300ms）。
    // JPEG 字节缓存到 pendingJpegBytes，processWithGpu 优先使用内存字节而非读文件。
    // ─────────────────────────────────────────────
    private fun handleTakePhoto(call: MethodCall, result: MethodChannel.Result) {
        val capture = imageCapture
        if (capture == null) {
            result.error("NOT_INITIALIZED", "Camera not initialized", null)
            return
        }
        val deviceQuarter = (call.argument<Int>("deviceQuarter") ?: 0).coerceIn(0, 3)
        runCatching {
            capture.targetRotation = quarterToSurfaceRotation(deviceQuarter)
        }.onFailure {
            Log.w(TAG, "set targetRotation failed: ${it.message}")
        }
        // 某些机型会在拍照后内部重置 flashMode，这里每次拍照前强制重设一次。
        runCatching { capture.flashMode = currentFlashMode }
            .onFailure { Log.w(TAG, "reapply flashMode failed: ${it.message}") }
        pendingShotStartNs = System.nanoTime()
        pendingShotLevel = currentSharpenLevel
        isPhotoCaptureInFlight = true
        val context = flutterPluginBinding.applicationContext
        // 使用 OnImageCapturedCallback 内存模式，跳过磁盘写入
        capture.takePicture(
            cameraExecutor,
            object : ImageCapture.OnImageCapturedCallback() {
                override fun onCaptureSuccess(image: ImageProxy) {
                    try {
                        val buffer = image.planes[0].buffer
                        val jpegBytes = ByteArray(buffer.remaining())
                        buffer.get(jpegBytes)
                        val rawRotationDegrees = image.imageInfo.rotationDegrees
                        // imageInfo.rotationDegrees 已包含 CameraX 对 targetRotation 的计算结果。
                        // rawRotation=0 是合法值（表示无需额外旋转），不能再用 deviceQuarter 强行补偿，
                        // 否则会在部分机型上出现横屏成片方向错误（如左横屏变成倒置竖图）。
                        val rotationDegrees = rawRotationDegrees
                        val isFront = currentLensPosition == CameraSelector.LENS_FACING_FRONT
                        val captureW = image.width
                        val captureH = image.height
                        val elapsedMs = ((System.nanoTime() - pendingShotStartNs) / 1_000_000L).coerceAtLeast(0L)
                        image.close()
                        isPhotoCaptureInFlight = false
                        Log.d(TAG, "takePhoto(mem): ${captureW}x${captureH} rot=${rotationDegrees} rawRot=${rawRotationDegrees} quarter=${deviceQuarter} front=${isFront}")
                        maybeRecordMidCapturePerf(captureW, captureH, elapsedMs)
                        // 异步写入 cache，保持 filePath 接口兼容性
                        val ts = SimpleDateFormat("yyyyMMdd_HHmmss_SSS", Locale.US).format(Date())
                        val cacheDir = File(context.cacheDir, "dazz_captures").apply { mkdirs() }
                        val cacheFile = File(cacheDir, "DAZZ_${ts}.jpg")
                        bgExecutor.execute {
                            try { cacheFile.writeBytes(jpegBytes) }
                            catch (e: Exception) { Log.w(TAG, "cache write failed: ${e.message}") }
                        }
                        val mainExecutor = ContextCompat.getMainExecutor(context)
                        mainExecutor.execute {
                            glRenderer?.let { renderer ->
                                reapplyPresetToRenderer(renderer)
                            }
                            // 缓存内存字节，供 processWithGpu 直接使用（跳过文件读取）
                            pendingJpegBytes = jpegBytes
                            pendingRotationDegrees = rotationDegrees
                            pendingIsFrontCamera = isFront
                            sendEvent("onPhotoCaptured", mapOf("filePath" to cacheFile.absolutePath))
                            result.success(mapOf(
                                "filePath" to cacheFile.absolutePath,
                                "captureWidth" to captureW,
                                "captureHeight" to captureH
                            ))
                            if (pendingStopPreview) {
                                stopPreviewSession()
                            }
                        }
                    } catch (e: Exception) {
                        image.close()
                        isPhotoCaptureInFlight = false
                        Log.e(TAG, "takePhoto(mem) failed", e)
                        val mainExecutor = ContextCompat.getMainExecutor(context)
                        mainExecutor.execute {
                            result.error("CAPTURE_FAILED", e.message, null)
                            if (pendingStopPreview) {
                                stopPreviewSession()
                            }
                        }
                    }
                }
                override fun onError(exception: ImageCaptureException) {
                    isPhotoCaptureInFlight = false
                    Log.e(TAG, "takePhoto failed", exception)
                    val mainExecutor = ContextCompat.getMainExecutor(context)
                    mainExecutor.execute {
                        glRenderer?.let { renderer ->
                            reapplyPresetToRenderer(renderer)
                        }
                        result.error("CAPTURE_FAILED", exception.message, null)
                        if (pendingStopPreview) {
                            stopPreviewSession()
                        }
                    }
                }
            }
        )
    }

    private fun quarterToSurfaceRotation(quarter: Int): Int {
        return when (quarter) {
            // quarter 定义：1=左横屏(逆时针), 3=右横屏(顺时针)
            // Surface rotation 语义与设备旋转方向相反，左右需对调映射。
            1 -> Surface.ROTATION_270
            2 -> Surface.ROTATION_180
            3 -> Surface.ROTATION_90
            else -> Surface.ROTATION_0
        }
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
                        // OPPO ColorOS 16 小米 MIUI 兴趣：额外触发 notifyChange 确保 photo_manager 立即感知新文件
                        context.contentResolver.notifyChange(
                            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, null
                        )
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

    private fun handleSaveMotionPhoto(call: MethodCall, result: MethodChannel.Result) {
        val imagePath = call.argument<String>("imagePath")
        val videoPath = call.argument<String>("videoPath")
        if (imagePath.isNullOrEmpty() || videoPath.isNullOrEmpty()) {
            result.error("INVALID_ARG", "imagePath and videoPath are required", null)
            return
        }
        val imageFile = File(imagePath)
        val videoFile = File(videoPath)
        if (!imageFile.exists() || !videoFile.exists()) {
            result.error("FILE_NOT_FOUND", "image or video file not found", null)
            return
        }
        val cameraId = call.argument<String>("cameraId") ?: ""
        val context = flutterPluginBinding.applicationContext

        bgExecutor.execute {
            var xmpImageFile: File? = null
            var motionPhotoFile: File? = null
            try {
                val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
                val displayName = if (cameraId.isNotEmpty()) {
                    "DAZZ_${cameraId}_${timestamp}_MP.jpg"
                } else {
                    "DAZZ_MOTION_${timestamp}_MP.jpg"
                }
                val presentationTimestampUs =
                    resolveMotionPhotoPresentationTimestampUs(videoFile)

                xmpImageFile = File(context.cacheDir, "motion_xmp_${timestamp}.jpg")
                imageFile.copyTo(xmpImageFile, overwrite = true)
                val exif = ExifInterface(xmpImageFile.absolutePath)
                exif.setAttribute(
                    ExifInterface.TAG_XMP,
                    buildMotionPhotoXmp(
                        videoLength = videoFile.length(),
                        presentationTimestampUs = presentationTimestampUs,
                    )
                )
                exif.saveAttributes()

                motionPhotoFile = File(context.cacheDir, "motion_out_${timestamp}.jpg")
                FileInputStream(xmpImageFile).use { input ->
                    FileOutputStream(motionPhotoFile).use { output ->
                        input.copyTo(output)
                        FileInputStream(videoFile).use { videoInput ->
                            videoInput.copyTo(output)
                        }
                    }
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val contentValues = ContentValues().apply {
                        put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
                        put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                        put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_DCIM}/$DAZZ_ALBUM")
                        put(MediaStore.Images.Media.IS_PENDING, 1)
                    }
                    val uri = context.contentResolver.insert(
                        MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                        contentValues
                    )
                    if (uri != null) {
                        context.contentResolver.openOutputStream(uri)?.use { os ->
                            FileInputStream(motionPhotoFile).use { it.copyTo(os) }
                        }
                        val updateValues = ContentValues().apply {
                            put(MediaStore.Images.Media.IS_PENDING, 0)
                        }
                        context.contentResolver.update(uri, updateValues, null, null)
                        context.contentResolver.notifyChange(
                            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                            null
                        )
                        ContextCompat.getMainExecutor(context).execute {
                            result.success(mapOf("success" to true, "uri" to uri.toString()))
                        }
                    } else {
                        ContextCompat.getMainExecutor(context).execute {
                            result.error("GALLERY_SAVE_FAILED", "ContentResolver insert returned null", null)
                        }
                    }
                } else {
                    val dcimDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM)
                    val dazzDir = File(dcimDir, DAZZ_ALBUM).apply { mkdirs() }
                    val destFile = File(dazzDir, displayName)
                    motionPhotoFile.copyTo(destFile, overwrite = true)
                    android.media.MediaScannerConnection.scanFile(
                        context,
                        arrayOf(destFile.absolutePath),
                        arrayOf("image/jpeg")
                    ) { _, _ -> }
                    ContextCompat.getMainExecutor(context).execute {
                        result.success(mapOf("success" to true, "uri" to destFile.absolutePath))
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "saveMotionPhoto failed", e)
                ContextCompat.getMainExecutor(context).execute {
                    result.error("GALLERY_SAVE_FAILED", e.message, null)
                }
            } finally {
                runCatching { imageFile.delete() }
                runCatching { videoFile.delete() }
                runCatching { xmpImageFile?.delete() }
                runCatching { motionPhotoFile?.delete() }
            }
        }
    }

    private fun buildMotionPhotoXmp(
        videoLength: Long,
        presentationTimestampUs: Long,
    ): String {
        return """
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description
                  xmlns:Camera="http://ns.google.com/photos/1.0/camera/"
                  xmlns:Container="http://ns.google.com/photos/1.0/container/"
                  xmlns:Item="http://ns.google.com/photos/1.0/container/item/"
                  Camera:MicroVideo="1"
                  Camera:MicroVideoVersion="1"
                  Camera:MicroVideoOffset="$videoLength"
                  Camera:MicroVideoPresentationTimestampUs="$presentationTimestampUs"
                  Camera:MotionPhoto="1"
                  Camera:MotionPhotoVersion="1"
                  Camera:MotionPhotoPresentationTimestampUs="$presentationTimestampUs">
                  <Container:Directory>
                    <rdf:Seq>
                      <rdf:li rdf:parseType="Resource"
                        Item:Mime="image/jpeg"
                        Item:Semantic="Primary"
                        Item:Length="0"
                        Item:Padding="0"/>
                      <rdf:li rdf:parseType="Resource"
                        Item:Mime="video/mp4"
                        Item:Semantic="MotionPhoto"
                        Item:Length="$videoLength"/>
                    </rdf:Seq>
                  </Container:Directory>
                </rdf:Description>
              </rdf:RDF>
            </x:xmpmeta>
        """.trimIndent()
    }

    private fun resolveMotionPhotoPresentationTimestampUs(videoFile: File): Long {
        return try {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(videoFile.absolutePath)
                val durationMs = retriever
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull()
                    ?: return -1L
                if (durationMs <= 0L) -1L else (durationMs * 1000L) / 2L
            } finally {
                retriever.release()
            }
        } catch (e: Exception) {
            Log.w(TAG, "resolveMotionPhotoPresentationTimestampUs failed: ${e.message}")
            -1L
        }
    }

    /// 使用处理后的文件覆盖已存在的 MediaStore 资产内容（同一 URI）。
    private fun handleReplaceGalleryImage(call: MethodCall, result: MethodChannel.Result) {
        val uriStr = call.argument<String>("uri")
        val filePath = call.argument<String>("filePath")
        if (uriStr.isNullOrEmpty() || filePath.isNullOrEmpty()) {
            result.error("INVALID_ARG", "uri and filePath are required", null)
            return
        }
        if (!uriStr.startsWith("content://")) {
            result.error("INVALID_URI", "replaceGalleryImage only supports content:// uri", null)
            return
        }
        val sourceFile = File(filePath)
        if (!sourceFile.exists()) {
            result.error("FILE_NOT_FOUND", "File not found: $filePath", null)
            return
        }

        val context = flutterPluginBinding.applicationContext
        bgExecutor.execute {
            try {
                val uri = Uri.parse(uriStr)
                context.contentResolver.openOutputStream(uri, "w")?.use { os ->
                    sourceFile.inputStream().use { it.copyTo(os) }
                } ?: run {
                    throw IllegalStateException("openOutputStream returned null")
                }
                context.contentResolver.notifyChange(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    null
                )
                Log.d(TAG, "[replaceGalleryImage] success uri=$uriStr")
                val mainExecutor = ContextCompat.getMainExecutor(context)
                mainExecutor.execute { result.success(mapOf("success" to true)) }
            } catch (e: Exception) {
                Log.e(TAG, "replaceGalleryImage failed", e)
                val mainExecutor = ContextCompat.getMainExecutor(context)
                mainExecutor.execute {
                    result.error("GALLERY_REPLACE_FAILED", e.message, null)
                }
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

    /**
     * 点击对焦 + 对焦点曝光（行业最佳实践）
     * x, y: 归一化坐标 [0, 1]，原点在左上角
     * 使用 CameraX FocusMeteringAction + SurfaceOrientedMeteringPointFactory
     */
    private fun handleSetFocus(call: MethodCall, result: MethodChannel.Result) {
        val x = call.argument<Double>("x")?.toFloat() ?: 0.5f
        val y = call.argument<Double>("y")?.toFloat() ?: 0.5f
        val cam = camera
        val st = surfaceTexture
        if (cam == null || st == null) {
            result.success(null)
            return
        }
        try {
            // SurfaceOrientedMeteringPointFactory 使用归一化坐标，自动处理旋转和镜像
            val factory = SurfaceOrientedMeteringPointFactory(1.0f, 1.0f)
            val point = factory.createPoint(x, y)
            val action = FocusMeteringAction.Builder(point,
                FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE)
                .setAutoCancelDuration(3, java.util.concurrent.TimeUnit.SECONDS)
                .build()
            cam.cameraControl.startFocusAndMetering(action)
            result.success(null)
        } catch (e: Exception) {
            Log.w(TAG, "setFocus failed: ${e.message}")
            result.success(null) // 对焦失败不影响拍摄流程
        }
    }

    private fun handleSetFlash(call: MethodCall, result: MethodChannel.Result) {
        val mode = call.argument<String>("mode") ?: "off"
        try {
            currentFlashMode = when (mode) {
                "on"   -> ImageCapture.FLASH_MODE_ON
                "auto" -> ImageCapture.FLASH_MODE_AUTO
                else   -> ImageCapture.FLASH_MODE_OFF
            }
            imageCapture?.flashMode = currentFlashMode
            result.success(null)
        } catch (e: Exception) {
            result.error("FLASH_FAILED", e.message, null)
        }
    }

    private fun handleSetWhiteBalance(call: MethodCall, result: MethodChannel.Result) {
        val mode = call.argument<String>("mode") ?: "auto"
        val tempK = call.argument<Int>("tempK") ?: 5500
        try {
            val cam = camera
            if (cam == null) {
                result.error("NOT_INITIALIZED", "Camera not initialized", null)
                return
            }
            // CameraX 通过 Camera2Interop 设置 AWB 模式
            val awbMode = when (mode) {
                "daylight"      -> CaptureRequest.CONTROL_AWB_MODE_DAYLIGHT
                "incandescent"  -> CaptureRequest.CONTROL_AWB_MODE_INCANDESCENT
                "fluorescent"   -> CaptureRequest.CONTROL_AWB_MODE_FLUORESCENT
                "cloudy"        -> CaptureRequest.CONTROL_AWB_MODE_CLOUDY_DAYLIGHT
                "manual"        -> CaptureRequest.CONTROL_AWB_MODE_OFF
                else            -> CaptureRequest.CONTROL_AWB_MODE_AUTO
            }
            val options = CaptureRequestOptions.Builder()
                .setCaptureRequestOption(CaptureRequest.CONTROL_AWB_MODE, awbMode)
                .build()
            Camera2CameraControl.from(cam.cameraControl).setCaptureRequestOptions(options)
            result.success(null)
        } catch (e: Exception) {
            // 部分设备不支持 Camera2Interop，静默失败
            result.success(null)
        }
    }

    // ─────────────────────────────────────────────
    // buildImageCapture — 根据清晰度级别构建 ImageCapture
    // 输入分辨率与 capture_pipeline.dart 的输出档位对齐，避免 ISP 多帧合成浪费时间：
    //   低档  输出 1920px → 输入请求 ≤4MP（2688×2016），单帧快速出图
    //   中档  输出 2688px → 输入请求 ≤16MP（4096×3072），覆盖输出所需，跳过多帧合成
    //   高档  输出 4096px → 输入请求 ≤16MP（4096×3072），覆盖输出所需，跳过多帧合成
    // 行业标准：输入分辨率只需略大于输出分辨率即可，不需要传感器全像素。
    // ─────────────────────────────────────────────
    private fun applySpeedCaptureOptions(
        builder: ImageCapture.Builder,
        level: Float,
    ) {
        val extender = Camera2Interop.Extender(builder)
        // 只保留保守且稳定的参数，避免在部分机型触发欠曝/偏暗。
        extender.setCaptureRequestOption(
            CaptureRequest.CONTROL_AF_MODE,
            CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE
        )
        // 中低档画质进一步降低 JPEG 硬件编码质量，减少编码耗时
        val jpegQ: Byte = when {
            level < 0.2f -> 84
            level < 0.7f -> 86
            else -> 92
        }
        extender.setCaptureRequestOption(CaptureRequest.JPEG_QUALITY, jpegQ)
    }

    private fun pickMidSpeedSizes(supportedSizes: List<Size>): List<Size> {
        val profileKey = buildMidProfileKey()
        val bestW = perfPrefs.getInt("${profileKey}_best_w", 0)
        val bestH = perfPrefs.getInt("${profileKey}_best_h", 0)

        // 1) 优先 12MP binning 原生档位（常见 4000x3000 / 4096x3072），很多 2 亿像素机型更快
        val prefer12Mp = supportedSizes.filter {
            val longSide = maxOf(it.width, it.height)
            val shortSide = minOf(it.width, it.height)
            val px = it.width.toLong() * it.height.toLong()
            px in 10_000_000L..14_500_000L &&
                longSide in 3900..4200 &&
                shortSide in 2900..3200
        }.sortedByDescending { it.width.toLong() * it.height.toLong() }

        // 2) 回退：4MP 附近（旧策略）
        val near4Mp = supportedSizes.filter {
            val px = it.width.toLong() * it.height.toLong()
            px in 3_200_000L..4_500_000L
        }.sortedByDescending { it.width.toLong() * it.height.toLong() }

        // 3) 再回退：<=8MP 的最大档位，避免掉回全像素慢路径
        val fallback = supportedSizes.filter {
            it.width.toLong() * it.height.toLong() <= 8_000_000L
        }.sortedByDescending { it.width.toLong() * it.height.toLong() }
            .ifEmpty { supportedSizes.sortedBy { it.width.toLong() * it.height.toLong() } }
        val candidates = (prefer12Mp + near4Mp + fallback)
            .distinctBy { "${it.width}x${it.height}" }

        if (candidates.isEmpty()) return supportedSizes

        // 已学习到最优尺寸：固定优先该尺寸。
        if (bestW > 0 && bestH > 0) {
            val best = candidates.firstOrNull {
                (it.width == bestW && it.height == bestH) || (it.width == bestH && it.height == bestW)
            }
            if (best != null) {
                return listOf(best) + candidates.filterNot { it == best }
            }
        }

        // 未学习到最优尺寸：轮询探索前 3 个候选档位。
        val explorePool = candidates.take(minOf(3, candidates.size))
        val idxKey = "${profileKey}_explore_idx"
        val idx = perfPrefs.getInt(idxKey, 0)
        val selected = explorePool[idx % explorePool.size]
        perfPrefs.edit().putInt(idxKey, idx + 1).apply()
        Log.d(TAG, "mid explore size=${selected.width}x${selected.height}, idx=$idx key=$profileKey")
        return listOf(selected) + candidates.filterNot { it == selected }
    }

    private fun buildMidProfileKey(): String {
        val cam = if (currentCameraId.isNotEmpty()) currentCameraId else "unknown"
        val lens = if (currentLensPosition == CameraSelector.LENS_FACING_FRONT) "front" else "back"
        return "mid_${Build.MANUFACTURER}_${Build.MODEL}_${cam}_$lens"
    }

    private fun maybeRecordMidCapturePerf(captureW: Int, captureH: Int, elapsedMs: Long) {
        if (pendingShotLevel < 0.2f || pendingShotLevel >= 0.7f) return
        if (captureW <= 0 || captureH <= 0 || elapsedMs <= 0L) return

        val key = buildMidProfileKey()
        val oldBestMs = perfPrefs.getLong("${key}_best_ms", Long.MAX_VALUE)
        val oldBestW = perfPrefs.getInt("${key}_best_w", 0)
        val oldBestH = perfPrefs.getInt("${key}_best_h", 0)
        if (elapsedMs < oldBestMs) {
            perfPrefs.edit()
                .putLong("${key}_best_ms", elapsedMs)
                .putInt("${key}_best_w", captureW)
                .putInt("${key}_best_h", captureH)
                .apply()
            Log.d(TAG, "mid best update: ${captureW}x${captureH} ${elapsedMs}ms (prev=${oldBestW}x${oldBestH} ${oldBestMs}ms)")
        } else {
            Log.d(TAG, "mid sample: ${captureW}x${captureH} ${elapsedMs}ms, best=${oldBestW}x${oldBestH} ${oldBestMs}ms")
        }
    }

    private fun buildImageCapture(level: Float): ImageCapture {
        val builder = ImageCapture.Builder()
        applySpeedCaptureOptions(builder, level)
        when {
            level < 0.2f -> {
                // 低清晰度：输出 1920px（~2MP），输入精准对齐 ≤4MP（2688×2016）
                // 用 ResolutionFilter 选"≤400万像素的最大档位"，避免解码超出输出所需的大图
                val lowFilter = ResolutionFilter { supportedSizes, _ ->
                    val candidates = supportedSizes.filter {
                        it.width.toLong() * it.height.toLong() <= 4_000_000L
                    }
                    candidates.sortedByDescending { it.width.toLong() * it.height.toLong() }
                        .ifEmpty {
                            // 所有档位都超过 400 万像素，回落到最小可用
                            supportedSizes.sortedBy { it.width.toLong() * it.height.toLong() }
                        }
                }
                builder.setResolutionSelector(
                    ResolutionSelector.Builder()
                        .setResolutionStrategy(ResolutionStrategy.HIGHEST_AVAILABLE_STRATEGY)
                        .setResolutionFilter(lowFilter)
                        .build()
                ).setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
            }
            level < 0.7f -> {
                // 中清晰度：优先 12MP binning 原生档位（如 4000x3000 / 4096x3072）
                // 若机型无该档位，再回退到 4MP 附近，避免走全像素慢路径。
                val midFilter = ResolutionFilter { supportedSizes, _ ->
                    pickMidSpeedSizes(supportedSizes)
                }
                builder.setResolutionSelector(
                    ResolutionSelector.Builder()
                        .setResolutionStrategy(ResolutionStrategy.HIGHEST_AVAILABLE_STRATEGY)
                        .setResolutionFilter(midFilter)
                        .build()
                ).setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
            }
            else -> {
                // 高清晰度：输出 4096px（~12MP），输入请求 ≤16MP（4096×3072）
                // 行业标准：不追求传感器全像素，只需覆盖 4096px 输出即可
                // 2亿像素手机全像素输出需要多帧合成（3-5s），限制 ≤1600万像素走单帧快速出图
                val highFilter = ResolutionFilter { supportedSizes, _ ->
                    // 优先选"≥4096px 且 ≤1600万像素"的档位（Binning 自然输出）
                    val candidates = supportedSizes.filter {
                        val px = it.width.toLong() * it.height.toLong()
                        px <= 16_000_000L && (it.width >= 4096 || it.height >= 4096)
                    }
                    if (candidates.isNotEmpty()) {
                        // 有符合条件的档位，选最大的
                        candidates.sortedByDescending { it.width.toLong() * it.height.toLong() }
                    } else {
                        // 没有同时满足"≥4096px 且 ≤1600万像素"的档位（低端设备）
                        // 回落到 ≤1600万像素的最大档位
                        val fallback = supportedSizes.filter {
                            it.width.toLong() * it.height.toLong() <= 16_000_000L
                        }.sortedByDescending { it.width.toLong() * it.height.toLong() }
                        fallback.ifEmpty {
                            // 所有档位都超过 1600 万像素，选最小的（极端情况）
                            supportedSizes.sortedBy { it.width.toLong() * it.height.toLong() }
                        }
                    }
                }
                builder.setResolutionSelector(
                    ResolutionSelector.Builder()
                        .setResolutionStrategy(ResolutionStrategy.HIGHEST_AVAILABLE_STRATEGY)
                        .setResolutionFilter(highFilter)
                        .build()
                ).setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
            }
        }
        return builder.build()
    }

    // ─────────────────────────────────────────────
    // setSharpen — 分辨率切换 + GPU Unsharp Mask + Camera2 EDGE_MODE
    // level: 0.0=低(2MP), 0.5=中(8MP), 1.0=高(全分辨率)
    // ─────────────────────────────────────────────
    private fun handleSetSharpen(call: MethodCall, result: MethodChannel.Result) {
        val level = call.argument<Double>("level") ?: 0.5
        currentSharpenLevel = level.toFloat()
        // 1. 更新 GL 渲染器中的 Unsharp Mask 强度
        glRenderer?.setSharpen(currentSharpenLevel)
        // 2. 重建 ImageCapture 并重新绑定（切换拍摄分辨率）
        // CRITICAL FIX: result.success must be called ONLY AFTER imageCapture is fully
        // rebound. Previously result.success(null) was called immediately after launching
        // bgExecutor.execute{}, causing Flutter's takePhoto to run before the new
        // high-res ImageCapture was bound — resulting in 2MP output even in high-quality mode.
        val owner = lifecycleOwner
        val provider = cameraProvider
        if (owner != null && provider != null) {
            bgExecutor.execute {
                try {
                    val newImageCapture = buildImageCapture(currentSharpenLevel)
                    @Suppress("UnsafeOptInUsageError")
                    val cameraSelector = buildCameraSelector(provider)
                    android.os.Handler(android.os.Looper.getMainLooper()).post {
                        try {
                            // CRITICAL FIX: Must unbindAll and rebind ALL use cases together.
                            // If only imageCapture is rebound while preview+videoCapture remain,
                            // CameraX negotiates a shared stream config compatible with the
                            // existing preview (1920x1080), silently capping imageCapture at 2MP
                            // even when HIGHEST_AVAILABLE_STRATEGY is set.
                            provider.unbindAll()
                            imageCapture = newImageCapture
                            imageCapture?.flashMode = currentFlashMode
                            val currentVideoCapture = videoCapture
                            if (currentVideoCapture != null) {
                                try {
                                    camera = provider.bindToLifecycle(
                                        owner,
                                        cameraSelector,
                                        preview,
                                        imageCapture,
                                        currentVideoCapture,
                                        imageAnalysis
                                    )
                                    supportsLivePhoto = true
                                } catch (e: Exception) {
                                    Log.w(TAG, "setSharpen rebind with live photo failed, fallback to photo-only: ${e.message}")
                                    provider.unbindAll()
                                    videoCapture = null
                                    supportsLivePhoto = false
                                    camera = provider.bindToLifecycle(
                                        owner,
                                        cameraSelector,
                                        preview,
                                        imageCapture,
                                        imageAnalysis
                                    )
                                }
                            } else {
                                supportsLivePhoto = false
                                camera = provider.bindToLifecycle(
                                    owner,
                                    cameraSelector,
                                    preview,
                                    imageCapture,
                                    imageAnalysis
                                )
                            }
                            Log.d(TAG, "setSharpen: level=$level, imageCapture rebuilt")
                            // 3. 使用 Camera2Interop 设置 EDGE_MODE（锐化算法）
                            // Must run after bindToLifecycle so cam.cameraControl is valid
                            try {
                                val cam = camera
                                if (cam != null) {
                                    val edgeMode = when {
                                        level < 0.2  -> android.hardware.camera2.CameraMetadata.EDGE_MODE_OFF
                                        level < 0.7  -> android.hardware.camera2.CameraMetadata.EDGE_MODE_FAST
                                        else         -> android.hardware.camera2.CameraMetadata.EDGE_MODE_HIGH_QUALITY
                                    }
                                    val options = CaptureRequestOptions.Builder()
                                        .setCaptureRequestOption(
                                            android.hardware.camera2.CaptureRequest.EDGE_MODE,
                                            edgeMode
                                        )
                                        .build()
                                    Camera2CameraControl.from(cam.cameraControl).setCaptureRequestOptions(options)
                                    Log.d(TAG, "setSharpen: level=$level, edgeMode=$edgeMode")
                                }
                            } catch (e: Exception) {
                                Log.w(TAG, "setSharpen EDGE_MODE failed: ${e.message}")
                            }
                            glRenderer?.let { renderer ->
                                reapplyPresetToRenderer(renderer)
                            }
                            scheduleRendererStateReplay("setSharpen")
                            // Return to Flutter ONLY after imageCapture is fully rebound
                            result.success(null)
                        } catch (e: Exception) {
                            Log.w(TAG, "rebind imageCapture failed: ${e.message}")
                            result.success(null) // Unblock Flutter even on failure
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "buildImageCapture failed: ${e.message}")
                    result.success(null) // Unblock Flutter even on failure
                }
            }
        } else {
            // No camera provider yet — just update the level and return immediately.
            // bindCameraUseCases will use currentSharpenLevel when it runs.
            result.success(null)
        }
    }

    private fun scheduleRendererStateReplay(reason: String) {
        val handler = android.os.Handler(android.os.Looper.getMainLooper())
        val replayDelays = longArrayOf(90L, 220L)
        replayDelays.forEach { delayMs ->
            handler.postDelayed({
                try {
                    glRenderer?.let { renderer ->
                        reapplyPresetToRenderer(renderer)
                        renderer.setSharpen(currentSharpenLevel)
                        Log.d(TAG, "renderer state replayed after $reason (+${delayMs}ms)")
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "renderer replay after $reason failed: ${e.message}")
                }
            }, delayMs)
        }
    }

    // ─────────────────────────────────────────────
    // updateLensParams — 镜头参数（畸变/暗角/缩放/鱼眼模式）
    // ─────────────────────────────────────────────

    private fun handleUpdateLensParams(call: MethodCall, result: MethodChannel.Result) {
        val fisheyeMode           = call.argument<Boolean>("fisheyeMode") ?: false
        val vignette              = call.argument<Double>("vignette")    ?: 0.0
        val chromaticAberration   = call.argument<Double>("chromaticAberration") ?: 0.0
        val bloom                 = call.argument<Double>("bloom") ?: 0.0
        val softFocus             = call.argument<Double>("softFocus") ?: 0.0
        val distortion            = call.argument<Double>("distortion") ?: 0.0
        val exposure              = call.argument<Double>("exposure") ?: 0.0
        val contrast              = call.argument<Double>("contrast") ?: 0.0
        val saturation            = call.argument<Double>("saturation") ?: 0.0
        val highlightCompression  = call.argument<Double>("highlightCompression") ?: 0.0
        val zoomFactor            = call.argument<Double>("zoomFactor") ?: 1.0

        // ── 缓存 lens 参数，供 switchLens 后重新应用 ──
        cachedLensFisheyeMode = fisheyeMode
        cachedLensVignette = vignette
        cachedLensDistortion = distortion

        // 将鱼眼模式传递到 GL 渲染器
        glRenderer?.setFisheyeMode(fisheyeMode)

        // ── FIX: 将所有镜头参数传递到 GL 渲染器（之前只传了 vignette）──
        val params = mutableMapOf<String, Any>(
            "vignette" to vignette,
            "chromaticAberration" to chromaticAberration,
            "bloomAmount" to bloom,
            "softFocus" to softFocus,
            "distortion" to distortion,
        )
        // 曝光、对比度、饱和度是镜头的叠加偏移量，不直接设置到 shader（它们通过 renderParams 组合后统一发送）
        // 但仍然需要缓存以供 switchLens 后重新应用
        glRenderer?.updateParams(params)

        Log.d(TAG, "updateLensParams: fisheyeMode=$fisheyeMode, vignette=$vignette, " +
            "chromaticAberration=$chromaticAberration, bloom=$bloom, softFocus=$softFocus, " +
            "distortion=$distortion, exposure=$exposure, contrast=$contrast, " +
            "saturation=$saturation, zoomFactor=$zoomFactor")
        result.success(null)
    }

    private fun handleSetMirrorFrontCamera(call: MethodCall, result: MethodChannel.Result) {
        mirrorFrontCameraEnabled = call.argument<Boolean>("enabled") ?: true
        applyPreviewMirrorToRenderer()
        result.success(null)
    }

    private fun handleSetMirrorBackCamera(call: MethodCall, result: MethodChannel.Result) {
        mirrorBackCameraEnabled = call.argument<Boolean>("enabled") ?: false
        applyPreviewMirrorToRenderer()
        result.success(null)
    }

    // ─────────────────────────────────────────────
    // syncRuntimeState — 一次性同步镜头参数 + 渲染参数 + 缩放
    // ─────────────────────────────────────────────
    private fun handleSyncRuntimeState(call: MethodCall, result: MethodChannel.Result) {
        val lensParams = call.argument<Map<String, Any>>("lensParams") ?: emptyMap()
        val renderParams = call.argument<Map<String, Any>>("renderParams") ?: emptyMap()
        val zoom = (call.argument<Double>("zoom") ?: 1.0).coerceIn(0.6, 20.0)
        val version = (call.argument<Int>("version") ?: cachedRenderVersion).coerceAtLeast(0)

        val fisheyeMode = (lensParams["fisheyeMode"] as? Boolean) ?: false
        val vignette = (lensParams["vignette"] as? Number)?.toDouble() ?: 0.0
        val distortion = (lensParams["distortion"] as? Number)?.toDouble() ?: 0.0
        val chromaticAberration =
            (lensParams["chromaticAberration"] as? Number)?.toDouble() ?: 0.0
        val bloom = (lensParams["bloom"] as? Number)?.toDouble() ?: 0.0
        val softFocus = (lensParams["softFocus"] as? Number)?.toDouble() ?: 0.0

        // 缓存 lens 参数，供重建 renderer 后恢复
        cachedLensFisheyeMode = fisheyeMode
        cachedLensVignette = vignette
        cachedLensDistortion = distortion

        try {
            camera?.cameraControl?.setZoomRatio(zoom.toFloat())
        } catch (e: Exception) {
            Log.w(TAG, "syncRuntimeState setZoom failed: ${e.message}")
        }

        glRenderer?.setFisheyeMode(fisheyeMode)

        val merged = mutableMapOf<String, Any>()
        merged.putAll(renderParams)
        merged["vignette"] = vignette
        merged["chromaticAberration"] = chromaticAberration
        merged["bloomAmount"] = bloom
        merged["softFocus"] = softFocus
        merged["distortion"] = distortion
        cachedRenderParams = renderParams
        cachedRenderVersion = version
        glRenderer?.updateParams(merged)

        result.success(
            mapOf(
                "appliedVersion" to cachedRenderVersion,
                "rendererReady" to (glRenderer != null)
            )
        )
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
                        if (pendingStopPreview) {
                            val mainExecutor =
                                ContextCompat.getMainExecutor(flutterPluginBinding.applicationContext)
                            mainExecutor.execute { stopPreviewSession() }
                        }
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
    // ── OpenGL ES Compute Pipeline ───────────────────────────────────────

    private fun handleProcessWithGpu(call: MethodCall, result: MethodChannel.Result) {
        // 取出内存字节缓存（消费一次后清空，避免下次误用）
        val memBytes = pendingJpegBytes
        val memRotation = pendingRotationDegrees
        val memIsFront = pendingIsFrontCamera
        pendingJpegBytes = null

        bgExecutor.execute {
            val filePath = call.argument<String>("filePath")
            val params = call.argument<Map<String, Any>>("params")
            val maxDimension = call.argument<Int>("maxDimension") ?: 4096
            val jpegQuality = (call.argument<Int>("jpegQuality") ?: 88).coerceIn(60, 95)

            if (params == null) {
                result.error("INVALID_ARG", "params required", null)
                return@execute
            }
            val paramsForGpu = params.toMutableMap().apply {
                this["maxDimension"] = maxDimension
                this["jpegQuality"] = jpegQuality
                this["mirrorOutput"] = shouldMirrorCurrentLens()
            }

            val newPath = if (memBytes != null) {
                // 优先使用内存字节，跳过文件读取（节省 100-300ms）
                Log.d(TAG, "processWithGpu: using in-memory JPEG bytes (${memBytes.size} bytes)")
                captureProcessor?.processImageBytes(memBytes, memRotation, memIsFront, paramsForGpu)
            } else {
                // 降级：内存字节不可用时回退到文件读取
                if (filePath == null) {
                    result.error("INVALID_ARG", "filePath required when no pending bytes", null)
                    return@execute
                }
                Log.d(TAG, "processWithGpu: fallback to file path $filePath")
                captureProcessor?.processImage(filePath, paramsForGpu)
            }

            activityBinding?.activity?.runOnUiThread {
                if (newPath != null) {
                    result.success(mapOf("filePath" to newPath))
                } else {
                    result.error("PROCESS_FAILED", "OpenGL ES processing failed", null)
                }
            }
        }
    }

    private fun handleComposeOverlay(call: MethodCall, result: MethodChannel.Result) {
        bgExecutor.execute {
            try {
                val filePath = call.argument<String>("filePath")
                if (filePath.isNullOrEmpty()) {
                    result.error("INVALID_ARG", "filePath required", null)
                    return@execute
                }
                val srcBitmap = BitmapFactory.decodeFile(filePath)
                    ?: run {
                        result.error("DECODE_FAILED", "Failed to decode source", null)
                        return@execute
                    }
                val canvasW = ((call.argument<Double>("canvasWidth") ?: srcBitmap.width.toDouble()).toInt()).coerceAtLeast(1)
                val canvasH = ((call.argument<Double>("canvasHeight") ?: srcBitmap.height.toDouble()).toInt()).coerceAtLeast(1)
                val outBitmap = Bitmap.createBitmap(canvasW, canvasH, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(outBitmap)

                val canvasBg = call.argument<String>("canvasBgColor") ?: "transparent"
                if (!canvasBg.equals("transparent", true) && canvasBg != "#00000000") {
                    canvas.drawColor(parseColorSafe(canvasBg, Color.WHITE))
                }

                val drawFrameBg = call.argument<Boolean>("drawFrameBg") == true
                if (drawFrameBg) {
                    val frameBgColor = parseColorSafe(call.argument<String>("frameBgColor"), Color.parseColor("#F5F2EA"))
                    val l = (call.argument<Double>("frameOuterLeft") ?: 0.0).toFloat()
                    val t = (call.argument<Double>("frameOuterTop") ?: 0.0).toFloat()
                    val w = (call.argument<Double>("frameOuterWidth") ?: 0.0).toFloat()
                    val h = (call.argument<Double>("frameOuterHeight") ?: 0.0).toFloat()
                    val r = (call.argument<Double>("frameCornerRadius") ?: 0.0).toFloat()
                    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = frameBgColor }
                    if (r > 0f) {
                        canvas.drawRoundRect(RectF(l, t, l + w, t + h), r, r, paint)
                    } else {
                        canvas.drawRect(RectF(l, t, l + w, t + h), paint)
                    }
                }

                val cropLeft = (call.argument<Double>("cropLeft") ?: 0.0).toInt().coerceAtLeast(0)
                val cropTop = (call.argument<Double>("cropTop") ?: 0.0).toInt().coerceAtLeast(0)
                val cropWidth = (call.argument<Double>("cropWidth") ?: srcBitmap.width.toDouble()).toInt()
                val cropHeight = (call.argument<Double>("cropHeight") ?: srcBitmap.height.toDouble()).toInt()
                val srcRect = Rect(
                    cropLeft.coerceAtMost(srcBitmap.width - 1),
                    cropTop.coerceAtMost(srcBitmap.height - 1),
                    (cropLeft + cropWidth).coerceAtMost(srcBitmap.width),
                    (cropTop + cropHeight).coerceAtMost(srcBitmap.height),
                )
                val imageLeft = (call.argument<Double>("imageLeft") ?: 0.0).toInt()
                val imageTop = (call.argument<Double>("imageTop") ?: 0.0).toInt()
                val imageWidth = (call.argument<Double>("imageWidth") ?: canvasW.toDouble()).toInt()
                val imageHeight = (call.argument<Double>("imageHeight") ?: canvasH.toDouble()).toInt()
                val dstRect = Rect(imageLeft, imageTop, imageLeft + imageWidth, imageTop + imageHeight)
                canvas.drawBitmap(srcBitmap, srcRect, dstRect, Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    isFilterBitmap = true
                    isDither = true
                })

                val frameAssetPath = call.argument<String>("frameAssetPath") ?: ""
                if (frameAssetPath.isNotEmpty()) {
                    val frameAssetBytes = call.argument<ByteArray>("frameAssetBytes")
                    val frameBitmap = if (frameAssetBytes != null && frameAssetBytes.isNotEmpty()) {
                        BitmapFactory.decodeByteArray(frameAssetBytes, 0, frameAssetBytes.size)
                    } else {
                        getOrLoadFrameBitmap(frameAssetPath)
                    } ?: throw IllegalStateException("frame asset not found: $frameAssetPath")
                    canvas.drawBitmap(
                        frameBitmap,
                        null,
                        Rect(0, 0, canvasW, canvasH),
                        Paint(Paint.ANTI_ALIAS_FLAG).apply { isFilterBitmap = true }
                    )
                    if (frameAssetBytes != null && frameAssetBytes.isNotEmpty() && !frameBitmap.isRecycled) {
                        frameBitmap.recycle()
                    }
                }

                val watermarkText = call.argument<String>("watermarkText") ?: ""
                if (watermarkText.isNotEmpty()) {
                    drawWatermarkOnCanvas(canvas, call)
                }

                val jpegQuality = (call.argument<Int>("jpegQuality") ?: 88).coerceIn(60, 95)
                val outFile = File(
                    flutterPluginBinding.applicationContext.cacheDir,
                    "gpu_overlay_${System.currentTimeMillis()}.jpg"
                )
                java.io.FileOutputStream(outFile).use { fos ->
                    outBitmap.compress(Bitmap.CompressFormat.JPEG, jpegQuality, fos)
                }

                srcBitmap.recycle()
                outBitmap.recycle()
                val mainExecutor = ContextCompat.getMainExecutor(flutterPluginBinding.applicationContext)
                mainExecutor.execute { result.success(mapOf("filePath" to outFile.absolutePath)) }
            } catch (e: Exception) {
                Log.e(TAG, "composeOverlay failed", e)
                val mainExecutor = ContextCompat.getMainExecutor(flutterPluginBinding.applicationContext)
                mainExecutor.execute { result.error("COMPOSE_FAILED", e.message, null) }
            }
        }
    }

    private fun handleBlendDoubleExposure(call: MethodCall, result: MethodChannel.Result) {
        bgExecutor.execute {
            try {
                val firstImagePath = call.argument<String>("firstImagePath")
                val secondImageBytes = call.argument<ByteArray>("secondImageBytes")
                val blend = ((call.argument<Double>("blend") ?: 0.5).coerceIn(0.0, 1.0)).toFloat()
                val jpegQuality = (call.argument<Int>("jpegQuality") ?: 90).coerceIn(60, 95)
                if (firstImagePath.isNullOrEmpty() || secondImageBytes == null || secondImageBytes.isEmpty()) {
                    result.error("INVALID_ARG", "firstImagePath and secondImageBytes are required", null)
                    return@execute
                }

                val first = BitmapFactory.decodeFile(firstImagePath)
                    ?: run {
                        result.error("DECODE_FAILED", "failed to decode first image", null)
                        return@execute
                    }
                val secondRaw = BitmapFactory.decodeByteArray(secondImageBytes, 0, secondImageBytes.size)
                    ?: run {
                        first.recycle()
                        result.error("DECODE_FAILED", "failed to decode second image", null)
                        return@execute
                    }
                val second = if (secondRaw.width != first.width || secondRaw.height != first.height) {
                    Bitmap.createScaledBitmap(secondRaw, first.width, first.height, true).also {
                        if (it !== secondRaw) secondRaw.recycle()
                    }
                } else {
                    secondRaw
                }

                val out = blendDoubleExposureScreen(first, second, blend)

                val outputFile = File(
                    flutterPluginBinding.applicationContext.cacheDir,
                    "double_exp_${System.currentTimeMillis()}.jpg"
                )
                java.io.FileOutputStream(outputFile).use { fos ->
                    out.compress(Bitmap.CompressFormat.JPEG, jpegQuality, fos)
                }

                first.recycle()
                second.recycle()
                out.recycle()

                val mainExecutor = ContextCompat.getMainExecutor(flutterPluginBinding.applicationContext)
                mainExecutor.execute {
                    result.success(mapOf("filePath" to outputFile.absolutePath))
                }
            } catch (e: Exception) {
                Log.e(TAG, "blendDoubleExposure failed", e)
                val mainExecutor = ContextCompat.getMainExecutor(flutterPluginBinding.applicationContext)
                mainExecutor.execute {
                    result.error("BLEND_FAILED", e.message, null)
                }
            }
        }
    }

    private fun blendDoubleExposureScreen(first: Bitmap, second: Bitmap, blend: Float): Bitmap {
        val w = first.width
        val h = first.height
        val firstWeight = blend.coerceIn(0f, 1f)
        val secondWeight = (1f - firstWeight).coerceIn(0f, 1f)
        val inA = IntArray(w * h)
        val inB = IntArray(w * h)
        val out = IntArray(w * h)
        first.getPixels(inA, 0, w, 0, 0, w, h)
        second.getPixels(inB, 0, w, 0, 0, w, h)
        for (i in out.indices) {
            val p1 = inA[i]
            val p2 = inB[i]
            val r1 = ((p1 shr 16) and 0xFF) / 255f * firstWeight
            val g1 = ((p1 shr 8) and 0xFF) / 255f * firstWeight
            val b1 = (p1 and 0xFF) / 255f * firstWeight
            val r2 = ((p2 shr 16) and 0xFF) / 255f * secondWeight
            val g2 = ((p2 shr 8) and 0xFF) / 255f * secondWeight
            val b2 = (p2 and 0xFF) / 255f * secondWeight
            val rr = (1f - (1f - r1) * (1f - r2)).coerceIn(0f, 1f)
            val gg = (1f - (1f - g1) * (1f - g2)).coerceIn(0f, 1f)
            val bb = (1f - (1f - b1) * (1f - b2)).coerceIn(0f, 1f)
            out[i] = (0xFF shl 24) or
                ((rr * 255f).toInt().coerceIn(0, 255) shl 16) or
                ((gg * 255f).toInt().coerceIn(0, 255) shl 8) or
                ((bb * 255f).toInt().coerceIn(0, 255))
        }
        return Bitmap.createBitmap(out, w, h, Bitmap.Config.ARGB_8888)
    }

    private fun drawWatermarkOnCanvas(canvas: Canvas, call: MethodCall) {
        val text = call.argument<String>("watermarkText") ?: return
        if (text.isEmpty()) return
        val imageLeft = (call.argument<Double>("imageLeft") ?: 0.0).toFloat()
        val imageTop = (call.argument<Double>("imageTop") ?: 0.0).toFloat()
        val imageWidth = (call.argument<Double>("imageWidth") ?: 0.0).toFloat()
        val imageHeight = (call.argument<Double>("imageHeight") ?: 0.0).toFloat()
        if (imageWidth <= 1f || imageHeight <= 1f) return

        val hasFrame = call.argument<Boolean>("watermarkHasFrame") == true
        val margin = imageWidth * if (hasFrame) 0.08f else 0.04f
        val direction = call.argument<String>("watermarkDirection") ?: "horizontal"
        val position = call.argument<String>("watermarkPosition") ?: "bottom_right"
        val color = parseColorSafe(call.argument<String>("watermarkColor"), Color.parseColor("#FF8C00"))
        val fontSize = (call.argument<Double>("watermarkFontSize") ?: (imageWidth * 0.038)).toFloat()
        val fontWeight = call.argument<Int>("watermarkFontWeight") ?: 400
        val letterSpacing = (call.argument<Double>("watermarkLetterSpacing") ?: 0.0).toFloat()
        val fontFamily = (call.argument<String>("watermarkFontFamily") ?: "").trim()

        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.color = color
            textSize = fontSize
            typeface = if (fontFamily.isNotEmpty()) {
                Typeface.create(fontFamily, if (fontWeight >= 700) Typeface.BOLD else Typeface.NORMAL)
            } else {
                Typeface.defaultFromStyle(if (fontWeight >= 700) Typeface.BOLD else Typeface.NORMAL)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                this.letterSpacing = if (fontSize > 0f) letterSpacing / fontSize else 0f
            }
        }
        val fm = paint.fontMetrics
        val lineHeight = fm.descent - fm.ascent

        if (direction == "vertical") {
            val chars = text.toCharArray().map { it.toString() }
            val maxW = chars.maxOfOrNull { paint.measureText(it) } ?: 0f
            val totalH = lineHeight * chars.size
            val (sx, sy) = resolveWatermarkStart(position, imageLeft, imageTop, imageWidth, imageHeight, maxW, totalH, margin)
            var y = sy - fm.ascent
            for (c in chars) {
                val cw = paint.measureText(c)
                canvas.drawText(c, sx + (maxW - cw) / 2f, y, paint)
                y += lineHeight
            }
        } else {
            val textW = paint.measureText(text)
            val textH = lineHeight
            val (dx, dyTop) = resolveWatermarkStart(position, imageLeft, imageTop, imageWidth, imageHeight, textW, textH, margin)
            val baseline = dyTop - fm.ascent
            canvas.drawText(text, dx, baseline, paint)
        }
    }

    private fun resolveWatermarkStart(
        position: String,
        ox: Float,
        oy: Float,
        w: Float,
        h: Float,
        textW: Float,
        textH: Float,
        margin: Float
    ): Pair<Float, Float> {
        return when (position) {
            "bottom_left" -> Pair(ox + margin, oy + h - textH - margin)
            "top_right" -> Pair(ox + w - textW - margin, oy + margin)
            "top_left" -> Pair(ox + margin, oy + margin)
            "bottom_center" -> Pair(ox + (w - textW) / 2f, oy + h - textH - margin)
            "top_center" -> Pair(ox + (w - textW) / 2f, oy + margin)
            else -> Pair(ox + w - textW - margin, oy + h - textH - margin)
        }
    }

    private fun parseColorSafe(value: String?, fallback: Int): Int {
        if (value.isNullOrEmpty()) return fallback
        if (value.equals("transparent", true)) return Color.TRANSPARENT
        return runCatching {
            val v = if (value.startsWith("#")) value else "#$value"
            Color.parseColor(v)
        }.getOrDefault(fallback)
    }

    private fun getOrLoadFrameBitmap(frameAssetPath: String): Bitmap? {
        synchronized(frameBitmapCache) {
            val cached = frameBitmapCache[frameAssetPath]
            if (cached != null && !cached.isRecycled) {
                frameBitmapLru.remove(frameAssetPath)
                frameBitmapLru.add(frameAssetPath)
                return cached
            }
        }
        val decoded = openFrameAssetStream(frameAssetPath)
            ?.use { input -> BitmapFactory.decodeStream(input) }
            ?: return null
        synchronized(frameBitmapCache) {
            frameBitmapCache[frameAssetPath] = decoded
            frameBitmapLru.remove(frameAssetPath)
            frameBitmapLru.add(frameAssetPath)
            while (frameBitmapLru.size > FRAME_BITMAP_CACHE_MAX) {
                val evictKey = frameBitmapLru.removeAt(0)
                frameBitmapCache.remove(evictKey)?.recycle()
            }
        }
        return decoded
    }

    private fun openFrameAssetStream(frameAssetPath: String): java.io.InputStream? {
        val assetManager = flutterPluginBinding.applicationContext.assets
        val candidates = LinkedHashSet<String>()
        val normalized = frameAssetPath
            .removePrefix("/")
            .removePrefix("flutter_assets/")
        if (normalized.isNotEmpty()) {
            candidates.add(normalized)
            if (normalized.startsWith("assets/")) {
                candidates.add(normalized.removePrefix("assets/"))
            } else {
                candidates.add("assets/$normalized")
            }
            runCatching {
                flutterPluginBinding.flutterAssets.getAssetFilePathBySubpath(normalized)
            }.getOrNull()?.let { lookup ->
                candidates.add(lookup.removePrefix("/").removePrefix("flutter_assets/"))
            }
            runCatching {
                flutterPluginBinding.flutterAssets.getAssetFilePathByName(normalized)
            }.getOrNull()?.let { lookup ->
                candidates.add(lookup.removePrefix("/").removePrefix("flutter_assets/"))
            }
        }
        for (candidate in candidates) {
            val stream = runCatching { assetManager.open(candidate) }.getOrNull()
            if (stream != null) return stream
        }
        return null
    }

    private fun handleDispose(result: MethodChannel.Result) {
        releaseCamera()
        result.success(null)
    }

    private fun shouldMirrorCurrentLens(): Boolean =
        if (currentLensPosition == CameraSelector.LENS_FACING_FRONT) {
            mirrorFrontCameraEnabled
        } else {
            mirrorBackCameraEnabled
        }

    private fun applyPreviewMirrorToRenderer(renderer: CameraGLRenderer? = glRenderer) {
        renderer?.setPreviewMirror(shouldMirrorCurrentLens())
    }

    // ─────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────

    private fun releaseCamera() {
        recording?.stop()
        recording = null
        cameraProvider?.unbindAll()
        cameraProvider = null
        glRenderer?.release()
        glRenderer = null
        textureEntry?.release()
        textureEntry = null
        surfaceTexture = null
    }

    /**
     * 切换摄像头后重新应用缓存的 preset 参数到新创建的 renderer。
     * switchLens 会重建 CameraGLRenderer，但不会重新调用 setPreset，
     * 导致新 renderer 的所有 uniform 参数为默认值（无效果）。
     */
    @Suppress("UNCHECKED_CAST")
    private fun reapplyPresetToRenderer(renderer: CameraGLRenderer) {
        val preset = currentPresetJson ?: return
        val cameraId = (preset["cameraId"] as? String) ?: (preset["id"] as? String) ?: ""
        Log.d(TAG, "reapplyPresetToRenderer: cameraId=$cameraId")

        val params = mutableMapOf<String, Any>()

        // 从 preset 顶层读取通用参数（旧路径兼容）
        (preset["contrast"]            as? Number)?.let { params["contrast"]            = it }
        (preset["saturation"]          as? Number)?.let { params["saturation"]          = it }
        (preset["temperatureShift"]    as? Number)?.let { params["temperatureShift"]    = it }
        (preset["chromaticAberration"] as? Number)?.let { params["chromaticAberration"] = it }
        (preset["noise"]               as? Number)?.let { params["noise"]               = it }
        (preset["vignette"]            as? Number)?.let { params["vignette"]            = it }
        (preset["grain"]               as? Number)?.let { params["grain"]               = it }
        (preset["sharpen"]             as? Number)?.let { params["sharpen"]             = it }

        // 从 defaultLook 子对象读取完整参数
        val look = preset["defaultLook"] as? Map<*, *>
        if (look != null) {
            (look["contrast"]            as? Number)?.let { params["contrast"]            = it }
            (look["saturation"]          as? Number)?.let { params["saturation"]          = it }
            (look["vignette"]            as? Number)?.let { params["vignette"]            = it }
            (look["chromaticAberration"] as? Number)?.let { params["chromaticAberration"] = it }
            (look["grain"]               as? Number)?.let { params["grain"]               = it }
            (look["temperature"]         as? Number)?.let { params["temperatureShift"]    = it }
            (look["tint"]                as? Number)?.let { params["tintShift"]           = it }
            (look["halation"]            as? Number)?.let { params["halationAmount"]      = it }
            (look["bloom"]               as? Number)?.let { params["bloomAmount"]         = it }
            (look["sharpness"]           as? Number)?.let { params["sharpen"]             = it }
            (look["highlights"]          as? Number)?.let { params["highlights"]          = it }
            (look["shadows"]             as? Number)?.let { params["shadows"]             = it }
            (look["whites"]              as? Number)?.let { params["whites"]              = it }
            (look["blacks"]              as? Number)?.let { params["blacks"]              = it }
            (look["clarity"]             as? Number)?.let { params["clarity"]             = it }
            (look["vibrance"]            as? Number)?.let { params["vibrance"]            = it }
            (look["noise"]               as? Number)?.let { params["noiseAmount"]         = it }
            (look["noiseAmount"]         as? Number)?.let { params["noiseAmount"]         = it }
            (look["colorBiasR"]          as? Number)?.let { params["colorBiasR"]          = it }
            (look["colorBiasG"]          as? Number)?.let { params["colorBiasG"]          = it }
            (look["colorBiasB"]          as? Number)?.let { params["colorBiasB"]          = it }
            (look["grainSize"]           as? Number)?.let { params["grainSize"]           = it }
            (look["luminanceNoise"]      as? Number)?.let { params["luminanceNoise"]      = it }
            (look["chromaNoise"]         as? Number)?.let { params["chromaNoise"]         = it }
            (look["highlightWarmAmount"] as? Number)?.let { params["highlightWarmAmount"] = it }
            (look["highlightRolloff"]    as? Number)?.let { params["highlightRolloff"]    = it }
            (look["highlightRolloff2"]   as? Number)?.let { params["highlightRolloff2"]   = it }
            (look["paperTexture"]        as? Number)?.let { params["paperTexture"]        = it }
            (look["edgeFalloff"]         as? Number)?.let { params["edgeFalloff"]         = it }
            (look["exposureVariation"]   as? Number)?.let { params["exposureVariation"]   = it }
            (look["cornerWarmShift"]     as? Number)?.let { params["cornerWarmShift"]     = it }
            (look["toneCurveStrength"]   as? Number)?.let { params["toneCurveStrength"]   = it }
            (look["lutStrength"]         as? Number)?.let { params["lutStrength"]         = it }
            (look["baseLut"]             as? String)?.let { params["baseLut"]             = it }
            // 用户曝光补偿（必须映射，否则预览无效）
            (look["exposureOffset"]       as? Number)?.let { params["exposureOffset"]       = it }
            (look["centerGain"]           as? Number)?.let { params["centerGain"]           = it }
            (look["developmentSoftness"]  as? Number)?.let { params["developmentSoftness"]  = it }
            (look["chemicalIrregularity"] as? Number)?.let { params["chemicalIrregularity"] = it }
            val skinProtect = look["skinHueProtect"]
            if (skinProtect is Boolean) params["skinHueProtect"] = if (skinProtect) 1.0 else 0.0
            else (skinProtect as? Number)?.let { params["skinHueProtect"] = it }
            (look["skinSatProtect"]       as? Number)?.let { params["skinSatProtect"]       = it }
            (look["skinLumaSoften"]       as? Number)?.let { params["skinLumaSoften"]       = it }
            (look["skinRedLimit"]         as? Number)?.let { params["skinRedLimit"]         = it }
        }

        if (params.isNotEmpty()) {
            renderer.updateParams(params)
        }
        if (cameraId.isNotEmpty()) {
            renderer.setCameraId(cameraId)
        }
        if (cachedRenderParams.isNotEmpty()) {
            renderer.updateParams(cachedRenderParams)
        }

        // ── FIX: 恢复缓存的 lens 参数（fisheyeMode / vignette）──────────────
        // switchLens 后 Dart 层的 setCamera + updateLensParams 可能在
        // SurfaceProvider 回调（新 renderer 创建）之前就已经执行完毕，
        // 此时 glRenderer 仍为 null，导致 lens 参数丢失。
        // 因此必须在此处从缓存中恢复 lens 参数。
        renderer.setFisheyeMode(cachedLensFisheyeMode)
        renderer.updateParams(mapOf(
            "vignette" to cachedLensVignette,
            "distortion" to cachedLensDistortion
        ))
        Log.d(TAG, "reapplyPresetToRenderer: restored lens params fisheyeMode=$cachedLensFisheyeMode, vignette=$cachedLensVignette, distortion=$cachedLensDistortion")
    }

    private fun sendEvent(type: String, payload: Map<String, Any>) {
        val mainExecutor = ContextCompat.getMainExecutor(flutterPluginBinding.applicationContext)
        mainExecutor.execute {
            eventSink?.success(mapOf("type" to type, "payload" to payload))
        }
    }
}
