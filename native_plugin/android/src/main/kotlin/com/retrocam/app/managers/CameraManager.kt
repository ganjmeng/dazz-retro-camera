package com.retrocam.app.managers

import android.content.Context
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.retrocam.app.renderers.GLRenderer

/**
 * 管理 CameraX 的生命周期和配置。
 * 负责将相机输出绑定到 GLRenderer 的输入 SurfaceTexture。
 */
class CameraManager(private val context: Context) {
    
    private var cameraProvider: ProcessCameraProvider? = null
    private var imageCapture: ImageCapture? = null
    private var currentLens = CameraSelector.LENS_FACING_BACK
    
    /**
     * 初始化 CameraX 并将 Preview UseCase 绑定到 GLRenderer 的 SurfaceTexture
     */
    fun bindToLifecycle(lifecycleOwner: LifecycleOwner, renderer: GLRenderer) {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)
        cameraProviderFuture.addListener({
            cameraProvider = cameraProviderFuture.get()
            bindCamera(lifecycleOwner, renderer)
        }, ContextCompat.getMainExecutor(context))
    }
    
    private fun bindCamera(lifecycleOwner: LifecycleOwner, renderer: GLRenderer) {
        val cameraProvider = cameraProvider ?: return
        
        // 配置 Preview UseCase，将输出绑定到 GLRenderer 的 SurfaceTexture
        val preview = Preview.Builder().build().also {
            it.setSurfaceProvider { request ->
                // 将 GLRenderer 持有的 SurfaceTexture 提供给 CameraX
                val surface = renderer.getInputSurface()
                request.provideSurface(surface, ContextCompat.getMainExecutor(context)) {}
            }
        }
        
        // 配置 ImageCapture UseCase，用于高分辨率拍照
        imageCapture = ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
            .build()
        
        val cameraSelector = CameraSelector.Builder()
            .requireLensFacing(currentLens)
            .build()
        
        try {
            cameraProvider.unbindAll()
            cameraProvider.bindToLifecycle(
                lifecycleOwner,
                cameraSelector,
                preview,
                imageCapture
            )
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
    
    /**
     * 切换前后置摄像头
     */
    fun switchLens(lifecycleOwner: LifecycleOwner, renderer: GLRenderer) {
        currentLens = if (currentLens == CameraSelector.LENS_FACING_BACK) {
            CameraSelector.LENS_FACING_FRONT
        } else {
            CameraSelector.LENS_FACING_BACK
        }
        bindCamera(lifecycleOwner, renderer)
    }
    
    /**
     * 触发拍照
     * @param onSuccess 拍照成功回调，返回文件路径
     * @param onError 拍照失败回调
     */
    fun takePhoto(onSuccess: (String) -> Unit, onError: (Exception) -> Unit) {
        // 实现 ImageCapture 拍照逻辑
        // imageCapture?.takePicture(...)
    }
}
