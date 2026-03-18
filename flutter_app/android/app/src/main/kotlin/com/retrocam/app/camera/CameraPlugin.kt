package com.retrocam.app.camera

import android.content.ContentValues
import android.content.Context
import android.graphics.SurfaceTexture
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import android.view.Surface
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
    /** 当前绑定摄像头的传感器调试信息，由 readActiveCameraInfo() 填充 */
    private var activeCameraDebugInfo: Map<String, Any> = emptyMap()
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
    private var currentSharpenLevel: Float = 0.5f
    // ── 缓存所有 lens 参数，供 Renderer 重建后完整恢复 ──
    private var cachedLensFisheyeMode: Boolean = false
    private var cachedLensVignette: Double = 0.0
    private var cachedLensChromaticAberration: Double = 0.0
    private var cachedLensBloom: Double = 0.0
    private var cachedLensSoftFocus: Double = 0.0
    private var cachedLensDistortion: Double = 0.0
    // 缓存完整渲染参数（滤镜+defaultLook 组合值），供 Renderer 重建后恢复
    @Volatile private var cachedRenderParams: Map<String, Any>? = null
    // 缓存镜像设置
    private var cachedMirrorFrontCamera: Boolean = true
    // GL Renderer
    private var glRenderer: CameraGLRenderer? = null
    // ── 用于 switchLens 等待新 renderer 就绪 ──
    @Volatile private var rendererReadyLatch: CountDownLatch? = null

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
            "setFocus"        -> handleSetFocus(call, result)
            "setFlash"        -> handleSetFlash(call, result)
            "setWhiteBalance" -> handleSetWhiteBalance(call, result)
            "setSharpen"         -> handleSetSharpen(call, result)
            "updateLensParams"   -> handleUpdateLensParams(call, result)
            "startRecording"     -> handleStartRecording(result)
            "stopRecording"      -> handleStopRecording(result)
            "saveToGallery"      -> handleSaveToGallery(call, result)
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

        preview = Preview.Builder().build().also { prev ->
            // GL 渲染模式：相机帧 → CameraGLRenderer（EGL + 着色器）→ Flutter SurfaceTexture
            prev.setSurfaceProvider(cameraExecutor) { request ->
                val w = request.resolution.width
                val h = request.resolution.height

                // 在 cameraExecutor 上初始化 GL（initialize 内部用 glExecutor 异步完成，
                // 并通过 CountDownLatch 同步等待，cameraExecutor 上阻塞是安全的）
                val renderer = CameraGLRenderer(st)
                renderer.initialize(w, h)
                glRenderer = renderer

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
                "facing" to facingStr
            )
            Log.d(TAG, "Active camera: id=$camId sensor=${sensorW}×${sensorH} focal=$focalStr facing=$facingStr")
        } catch (e: Exception) {
            Log.w(TAG, "readActiveCameraInfo failed: ${e.message}")
        }
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
        val cameraId = (preset?.get("cameraId") as? String) ?: (preset?.get("id") as? String) ?: ""
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
                (look["paperTexture"]        as? Number)?.let { params["paperTexture"]        = it }
                (look["edgeFalloff"]         as? Number)?.let { params["edgeFalloff"]         = it }
                (look["exposureVariation"]   as? Number)?.let { params["exposureVariation"]   = it }
                (look["cornerWarmShift"]     as? Number)?.let { params["cornerWarmShift"]     = it }
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
                // 缓存完整渲染参数，供 Renderer 重建后在 reapplyPresetToRenderer 中恢复
                @Suppress("UNCHECKED_CAST")
                cachedRenderParams = params.toMap() as Map<String, Any>
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
                    // Attach actual capture resolution for debug overlay
                    val resInfo = capture.resolutionInfo
                    val captureW = resInfo?.resolution?.width ?: 0
                    val captureH = resInfo?.resolution?.height ?: 0
                    Log.d(TAG, "Capture resolution: ${captureW}x${captureH}")
                    val mainExecutor = ContextCompat.getMainExecutor(context)
                    mainExecutor.execute {
                        sendEvent("onPhotoCaptured", mapOf("filePath" to filePath))
                        result.success(mapOf(
                            "filePath" to filePath,
                            "captureWidth" to captureW,
                            "captureHeight" to captureH
                        ))
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
    // level: 0.0=低(2MP), 0.5=中(8MP), 1.0=高(全分辨率)
    // ─────────────────────────────────────────────
    private fun buildImageCapture(level: Float): ImageCapture {
        val builder = ImageCapture.Builder()
        when {
            level < 0.2f -> {
                // 低清晰度：目标 2MP（1600×1200），最小延迟模式
                val strategy = ResolutionStrategy(
                    Size(1600, 1200),
                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER
                )
                builder.setResolutionSelector(
                    ResolutionSelector.Builder()
                        .setResolutionStrategy(strategy)
                        .build()
                ).setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
            }
            level < 0.7f -> {
                // 中清晰度：目标 8MP（3264×2448），最小延迟模式
                val strategy = ResolutionStrategy(
                    Size(3264, 2448),
                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER
                )
                builder.setResolutionSelector(
                    ResolutionSelector.Builder()
                        .setResolutionStrategy(strategy)
                        .build()
                ).setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
            }
            else -> {
                // 高清晰度：设备全像素（最高分辨率）
                // 使用 ResolutionFilter 优先选择 ≥4096 的分辨率，如果设备不支持则回落到最大可用
                val highResFilter = ResolutionFilter { supportedSizes, _ ->
                    // 按像素数降序排列，优先选择 ≥4096 的尺寸
                    val sorted = supportedSizes.sortedByDescending { it.width * it.height }
                    val preferred = sorted.filter { it.width >= 4096 || it.height >= 4096 }
                    if (preferred.isNotEmpty()) preferred else sorted
                }
                // 通过 Camera2Interop 设置 JPEG 硬件编码质量为 95
                val extender = Camera2Interop.Extender(builder)
                extender.setCaptureRequestOption(
                    CaptureRequest.JPEG_QUALITY,
                    95.toByte()
                )
                builder.setResolutionSelector(
                    ResolutionSelector.Builder()
                        .setResolutionStrategy(ResolutionStrategy.HIGHEST_AVAILABLE_STRATEGY)
                        .setResolutionFilter(highResFilter)
                        .build()
                ).setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
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
                            camera = provider.bindToLifecycle(
                                owner,
                                cameraSelector,
                                preview,
                                imageCapture,
                                videoCapture
                            )
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

        // ── 缓存所有 lens 参数，供 Renderer 重建后完整恢复 ──
        cachedLensFisheyeMode = fisheyeMode
        cachedLensVignette = vignette
        cachedLensChromaticAberration = chromaticAberration
        cachedLensBloom = bloom
        cachedLensSoftFocus = softFocus
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
    // ── OpenGL ES Compute Pipeline ───────────────────────────────────────

    private fun handleProcessWithGpu(call: MethodCall, result: MethodChannel.Result) {
        bgExecutor.execute {
            val filePath = call.argument<String>("filePath")
            val params = call.argument<Map<String, Any>>("params")

            if (filePath == null || params == null) {
                result.error("INVALID_ARG", "filePath and params required", null)
                return@execute
            }

            val newPath = captureProcessor?.processImage(filePath, params)
            activityBinding?.activity?.runOnUiThread {
                if (newPath != null) {
                    result.success(mapOf("filePath" to newPath))
                } else {
                    result.error("PROCESS_FAILED", "OpenGL ES processing failed", null)
                }
            }
        }
    }

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
            (look["paperTexture"]        as? Number)?.let { params["paperTexture"]        = it }
            (look["edgeFalloff"]         as? Number)?.let { params["edgeFalloff"]         = it }
            (look["exposureVariation"]   as? Number)?.let { params["exposureVariation"]   = it }
            (look["cornerWarmShift"]     as? Number)?.let { params["cornerWarmShift"]     = it }
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

          // ── 优先使用 cachedRenderParams（已经是 Shader uniform 名称，无需再映射）──
        val rp = cachedRenderParams
        if (rp != null) {
            renderer.updateParams(rp)
            Log.d(TAG, "reapplyPresetToRenderer: restored cachedRenderParams (${rp.size} keys)")
        }
        // ── 完整恢复所有 lens 参数 ──
        // switchLens/initCamera 后 Dart 层的 updateLensParams 可能在 SurfaceProvider 回调之前执行，
        // 此时 glRenderer 为 null 导致参数丢失。必须在此处从缓存中完整恢复。
        renderer.setFisheyeMode(cachedLensFisheyeMode)
        val lensParams = mutableMapOf<String, Any>(
            "vignette"            to cachedLensVignette,
            "chromaticAberration" to cachedLensChromaticAberration,
            "bloomAmount"         to cachedLensBloom,
            "softFocus"           to cachedLensSoftFocus,
            "distortion"          to cachedLensDistortion,
        )
        renderer.updateParams(lensParams)
        Log.d(TAG, "reapplyPresetToRenderer: restored lens params fisheyeMode=$cachedLensFisheyeMode, vignette=$cachedLensVignette, chromaticAberration=$cachedLensChromaticAberration")
    }

    private fun sendEvent(type: String, payload: Map<String, Any>) {
        val mainExecutor = ContextCompat.getMainExecutor(flutterPluginBinding.applicationContext)
        mainExecutor.execute {
            eventSink?.success(mapOf("type" to type, "payload" to payload))
        }
    }
}
