package com.retrocam.app.models

import org.json.JSONObject

/**
 * Preset 数据模型（与 Flutter 侧的 JSON 结构完全对应）
 */
data class Preset(
    val id: String,
    val name: String,
    val category: String,
    val supportsPhoto: Boolean,
    val supportsVideo: Boolean,
    val isPremium: Boolean,
    val resources: PresetResources,
    val params: PresetParams
) {
    companion object {
        fun fromJson(json: Map<String, Any>): Preset? {
            return try {
                val resourcesMap = json["resources"] as Map<String, Any>
                val paramsMap = json["params"] as Map<String, Any>
                val dateStampMap = paramsMap["dateStamp"] as? Map<String, Any> ?: emptyMap()
                
                Preset(
                    id = json["id"] as String,
                    name = json["name"] as String,
                    category = json["category"] as String,
                    supportsPhoto = json["supportsPhoto"] as? Boolean ?: true,
                    supportsVideo = json["supportsVideo"] as? Boolean ?: false,
                    isPremium = json["isPremium"] as? Boolean ?: false,
                    resources = PresetResources(
                        lutName = resourcesMap["lutName"] as String,
                        grainTextureName = resourcesMap["grainTextureName"] as String,
                        leakTextureNames = (resourcesMap["leakTextureNames"] as? List<*>)
                            ?.filterIsInstance<String>() ?: emptyList(),
                        frameOverlayName = resourcesMap["frameOverlayName"] as? String
                    ),
                    params = PresetParams(
                        exposureBias = (paramsMap["exposureBias"] as? Number)?.toFloat() ?: 0f,
                        contrast = (paramsMap["contrast"] as? Number)?.toFloat() ?: 1f,
                        saturation = (paramsMap["saturation"] as? Number)?.toFloat() ?: 1f,
                        temperatureShift = (paramsMap["temperatureShift"] as? Number)?.toFloat() ?: 0f,
                        tintShift = (paramsMap["tintShift"] as? Number)?.toFloat() ?: 0f,
                        sharpen = (paramsMap["sharpen"] as? Number)?.toFloat() ?: 0f,
                        blurRadius = (paramsMap["blurRadius"] as? Number)?.toFloat() ?: 0f,
                        grainAmount = (paramsMap["grainAmount"] as? Number)?.toFloat() ?: 0f,
                        noiseAmount = (paramsMap["noiseAmount"] as? Number)?.toFloat() ?: 0f,
                        vignetteAmount = (paramsMap["vignetteAmount"] as? Number)?.toFloat() ?: 0f,
                        chromaticAberration = (paramsMap["chromaticAberration"] as? Number)?.toFloat() ?: 0f,
                        bloomAmount = (paramsMap["bloomAmount"] as? Number)?.toFloat() ?: 0f,
                        halationAmount = (paramsMap["halationAmount"] as? Number)?.toFloat() ?: 0f,
                        jpegArtifacts = (paramsMap["jpegArtifacts"] as? Number)?.toFloat() ?: 0f,
                        scanlineAmount = (paramsMap["scanlineAmount"] as? Number)?.toFloat() ?: 0f,
                        dateStamp = DateStampConfig(
                            enabled = dateStampMap["enabled"] as? Boolean ?: false,
                            format = dateStampMap["format"] as? String ?: "yyyy MM dd",
                            color = dateStampMap["color"] as? String ?: "#FFFFA500",
                            position = dateStampMap["position"] as? String ?: "bottomRight"
                        )
                    )
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}

data class PresetResources(
    val lutName: String,
    val grainTextureName: String,
    val leakTextureNames: List<String>,
    val frameOverlayName: String?
)

data class DateStampConfig(
    val enabled: Boolean,
    val format: String,
    val color: String,
    val position: String
)

data class PresetParams(
    val exposureBias: Float,
    val contrast: Float,
    val saturation: Float,
    val temperatureShift: Float,
    val tintShift: Float,
    val sharpen: Float,
    val blurRadius: Float,
    val grainAmount: Float,
    val noiseAmount: Float,
    val vignetteAmount: Float,
    val chromaticAberration: Float,
    val bloomAmount: Float,
    val halationAmount: Float,
    val jpegArtifacts: Float,
    val scanlineAmount: Float,
    val dateStamp: DateStampConfig
)
