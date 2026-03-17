package com.retrocam.app.camera

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.renderscript.Allocation
import android.renderscript.Element
import android.renderscript.RenderScript
import android.renderscript.Type
import android.util.Log
import com.retrocam.app.ScriptC_capture_pipeline
import java.io.File
import java.io.FileOutputStream

/**
 * Android 成片 GPU 处理器
 *
 * 使用 RenderScript 在 GPU 上执行完整的成片管线，对应 iOS 的 Metal Compute Shader。
 * 在 Dart 层的 capture_pipeline.dart 调用 processWithGpu 时触发。
 *
 * 管线顺序（与 fragment_ccd.glsl 和 iOS CapturePipeline.metal 完全一致）：
 *   Pass 1:  色差（Kotlin 预处理）
 *   Pass 2:  色温 + Tint
 *   Pass 3:  黑场/白场
 *   Pass 4:  高光/阴影压缩
 *   Pass 5:  对比度
 *   Pass 6:  Clarity（中间调微对比度）
 *   Pass 7:  饱和度 + Vibrance
 *   Pass 8:  RGB 通道偏移
 *   Pass 9:  Bloom（高光光晕）
 *   Pass 10: Highlight Rolloff（高光柔和滴落，成片专属）
 *   Pass 11: Center Gain（中心增亮，成片专属）
 *   Pass 12: Skin Protection（肤色保护，成片专属）
 *   Pass 13: Edge Falloff + Corner Warm Shift（成片专属）
 *   Pass 14: Chemical Irregularity（化学不规则感，成片专属）
 *   Pass 15: Paper Texture（相纸纹理，成片专属）
 *   Pass 16: Film Grain（胶片颗粒）
 *   Pass 17: Vignette（暗角）
 */
class CaptureProcessor(private val context: Context) {

    companion object {
        private const val TAG = "CaptureProcessor"
    }

    private var rs: RenderScript? = null
    private var script: ScriptC_capture_pipeline? = null

    private fun ensureInit() {
        if (rs == null) {
            rs = RenderScript.create(context)
            script = ScriptC_capture_pipeline(rs!!)
        }
    }

    /**
     * 处理图像文件，返回处理后的临时文件路径
     *
     * @param filePath 原始 JPEG 文件路径
     * @param params   来自 Dart 层的参数字典（PreviewRenderParams.toJson()）
     * @return 处理后的 JPEG 文件路径，失败时返回 null
     */
    fun processImage(filePath: String, params: Map<String, Any>): String? {
        return try {
            ensureInit()
            val rs = this.rs ?: return null
            val script = this.script ?: return null

            // 1. 解码原始 JPEG
            val options = BitmapFactory.Options().apply { inMutable = true }
            val inBitmap = BitmapFactory.decodeFile(filePath, options)
                ?: return null.also { Log.e(TAG, "Failed to decode: $filePath") }

            // 2. 设置所有 RenderScript 全局参数
            setScriptParams(script, params, inBitmap.width, inBitmap.height)

            // 3. 创建输入/输出 Allocation
            val inAlloc = Allocation.createFromBitmap(rs, inBitmap,
                Allocation.MipmapControl.MIPMAP_NONE,
                Allocation.USAGE_SCRIPT)

            val outBitmap = Bitmap.createBitmap(inBitmap.width, inBitmap.height, Bitmap.Config.ARGB_8888)
            val outAlloc = Allocation.createFromBitmap(rs, outBitmap,
                Allocation.MipmapControl.MIPMAP_NONE,
                Allocation.USAGE_SCRIPT)

            // 4. 执行 RenderScript 内核
            script.forEach_capturePipeline(inAlloc, outAlloc)

            // 5. 回写结果到 Bitmap
            outAlloc.copyTo(outBitmap)

            // 6. 释放 Allocation
            inAlloc.destroy()
            outAlloc.destroy()
            inBitmap.recycle()

            // 7. 编码为 JPEG 并写入临时文件
            val outputFile = File(context.cacheDir, "gpu_${File(filePath).name}")
            FileOutputStream(outputFile).use { fos ->
                outBitmap.compress(Bitmap.CompressFormat.JPEG, 92, fos)
            }
            outBitmap.recycle()

            Log.d(TAG, "GPU processing complete: ${outputFile.absolutePath}")
            outputFile.absolutePath

        } catch (e: Exception) {
            Log.e(TAG, "GPU processing failed", e)
            null
        }
    }

    /**
     * 将 Dart 传来的参数字典映射到 RenderScript 全局变量
     */
    private fun setScriptParams(script: ScriptC_capture_pipeline, params: Map<String, Any>,
                                 width: Int, height: Int) {
        // 图像尺寸
        script.set_gWidth(width)
        script.set_gHeight(height)

        // 时间种子（用于颗粒和化学不规则感的随机数）
        script.set_gTime(System.currentTimeMillis().toFloat() / 1000.0f)

        // ── 基础色彩参数 ──────────────────────────────────────────────────
        script.set_gContrast(getFloat(params, "contrast", 1.0f))
        script.set_gSaturation(getFloat(params, "saturation", 1.0f))
        script.set_gTemperatureShift(getFloat(params, "temperatureShift", 0.0f))
        script.set_gTintShift(getFloat(params, "tintShift", 0.0f))

        // ── Lightroom 风格曲线参数 ────────────────────────────────────────
        script.set_gHighlights(getFloat(params, "highlights", 0.0f))
        script.set_gShadows(getFloat(params, "shadows", 0.0f))
        script.set_gWhites(getFloat(params, "whites", 0.0f))
        script.set_gBlacks(getFloat(params, "blacks", 0.0f))
        script.set_gClarity(getFloat(params, "clarity", 0.0f))
        script.set_gVibrance(getFloat(params, "vibrance", 0.0f))

        // ── RGB 通道偏移 ──────────────────────────────────────────────────
        script.set_gColorBiasR(getFloat(params, "colorBiasR", 0.0f))
        script.set_gColorBiasG(getFloat(params, "colorBiasG", 0.0f))
        script.set_gColorBiasB(getFloat(params, "colorBiasB", 0.0f))

        // ── 胶片效果参数 ──────────────────────────────────────────────────
        script.set_gGrainAmount(getFloat(params, "grainAmount", 0.0f))
        script.set_gNoiseAmount(getFloat(params, "noiseAmount", 0.0f))
        script.set_gVignetteAmount(getFloat(params, "vignetteAmount", 0.0f))
        script.set_gChromaticAberration(getFloat(params, "chromaticAberration", 0.0f))
        script.set_gBloomAmount(getFloat(params, "bloomAmount", 0.0f))
        script.set_gDistortion(getFloat(params, "distortion", 0.0f))
        script.set_gZoomFactor(getFloat(params, "zoomFactor", 1.0f))
        script.set_gLensVignette(getFloat(params, "lensVignette", 0.0f))

        // ── 成片专属参数（预览中被 SIMPLIFIED 的效果）────────────────────
        script.set_gHighlightRolloff(getFloat(params, "highlightRolloff", 0.0f))
        script.set_gPaperTexture(getFloat(params, "paperTexture", 0.0f))
        script.set_gEdgeFalloff(getFloat(params, "edgeFalloff", 0.0f))
        script.set_gExposureVariation(getFloat(params, "exposureVariation", 0.0f))
        script.set_gCornerWarmShift(getFloat(params, "cornerWarmShift", 0.0f))
        script.set_gCenterGain(getFloat(params, "centerGain", 0.0f))
        script.set_gDevelopmentSoftness(getFloat(params, "developmentSoftness", 0.0f))
        script.set_gChemicalIrregularity(getFloat(params, "chemicalIrregularity", 0.0f))
        script.set_gSkinHueProtect(getFloat(params, "skinHueProtect", 0.0f))
        script.set_gSkinSatProtect(getFloat(params, "skinSatProtect", 1.0f))
        script.set_gSkinLumaSoften(getFloat(params, "skinLumaSoften", 0.0f))
        script.set_gSkinRedLimit(getFloat(params, "skinRedLimit", 1.0f))
    }

    private fun getFloat(params: Map<String, Any>, key: String, default: Float): Float {
        return when (val v = params[key]) {
            is Double -> v.toFloat()
            is Float  -> v
            is Int    -> v.toFloat()
            is Long   -> v.toFloat()
            else      -> default
        }
    }

    fun destroy() {
        script?.destroy()
        rs?.destroy()
        rs = null
        script = null
    }
}
