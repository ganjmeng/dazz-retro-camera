import Foundation

// MARK: - Preset 数据模型（与 Flutter 侧的 JSON 结构完全对应）

struct Preset: Codable {
    let id: String
    let name: String
    let category: String
    let supportsPhoto: Bool
    let supportsVideo: Bool
    let isPremium: Bool
    let resources: PresetResources
    let params: PresetParams
    
    static func fromJson(_ json: [String: Any]) -> Preset? {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let preset = try? JSONDecoder().decode(Preset.self, from: data) else {
            return nil
        }
        return preset
    }
}

struct PresetResources: Codable {
    let lutName: String
    let grainTextureName: String
    let leakTextureNames: [String]
    let frameOverlayName: String?
}

struct DateStampConfig: Codable {
    let enabled: Bool
    let format: String
    let color: String
    let position: String
}

/// RGB 通道独立偏移（-1.0 ~ +1.0）
struct ColorBias: Codable {
    let r: Float
    let g: Float
    let b: Float
    
    static let zero = ColorBias(r: 0, g: 0, b: 0)
}

struct PresetParams: Codable {
    let exposureBias: Float

    // ── 基础色彩 ──────────────────────────────────────────────
    let contrast: Float
    let saturation: Float
    let temperatureShift: Float
    let tintShift: Float

    // ── Lightroom 风格曲线（-100 ~ +100）─────────────────────
    let highlights: Float
    let shadows: Float
    let whites: Float
    let blacks: Float
    let clarity: Float
    let vibrance: Float

    // ── RGB 通道独立偏移 ──────────────────────────────────────
    let colorBias: ColorBias

    // ── 胶片效果 ──────────────────────────────────────────────
    let sharpen: Float
    let blurRadius: Float
    let grainAmount: Float
    let noiseAmount: Float
    let vignetteAmount: Float
    let chromaticAberration: Float
    let bloomAmount: Float
    let halationAmount: Float
    let jpegArtifacts: Float
    let scanlineAmount: Float
    let dateStamp: DateStampConfig

    // MARK: - CodingKeys（处理可选字段的默认值）
    enum CodingKeys: String, CodingKey {
        case exposureBias, contrast, saturation, temperatureShift, tintShift
        case highlights, shadows, whites, blacks, clarity, vibrance, colorBias
        case sharpen, blurRadius, grainAmount, noiseAmount, vignetteAmount
        case chromaticAberration, bloomAmount, halationAmount, jpegArtifacts
        case scanlineAmount, dateStamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposureBias        = try c.decodeIfPresent(Float.self, forKey: .exposureBias)        ?? 0
        contrast            = try c.decodeIfPresent(Float.self, forKey: .contrast)            ?? 1
        saturation          = try c.decodeIfPresent(Float.self, forKey: .saturation)          ?? 1
        temperatureShift    = try c.decodeIfPresent(Float.self, forKey: .temperatureShift)    ?? 0
        tintShift           = try c.decodeIfPresent(Float.self, forKey: .tintShift)           ?? 0
        highlights          = try c.decodeIfPresent(Float.self, forKey: .highlights)          ?? 0
        shadows             = try c.decodeIfPresent(Float.self, forKey: .shadows)             ?? 0
        whites              = try c.decodeIfPresent(Float.self, forKey: .whites)              ?? 0
        blacks              = try c.decodeIfPresent(Float.self, forKey: .blacks)              ?? 0
        clarity             = try c.decodeIfPresent(Float.self, forKey: .clarity)             ?? 0
        vibrance            = try c.decodeIfPresent(Float.self, forKey: .vibrance)            ?? 0
        colorBias           = try c.decodeIfPresent(ColorBias.self, forKey: .colorBias)       ?? .zero
        sharpen             = try c.decodeIfPresent(Float.self, forKey: .sharpen)             ?? 0
        blurRadius          = try c.decodeIfPresent(Float.self, forKey: .blurRadius)          ?? 0
        grainAmount         = try c.decodeIfPresent(Float.self, forKey: .grainAmount)         ?? 0
        noiseAmount         = try c.decodeIfPresent(Float.self, forKey: .noiseAmount)         ?? 0
        vignetteAmount      = try c.decodeIfPresent(Float.self, forKey: .vignetteAmount)      ?? 0
        chromaticAberration = try c.decodeIfPresent(Float.self, forKey: .chromaticAberration) ?? 0
        bloomAmount         = try c.decodeIfPresent(Float.self, forKey: .bloomAmount)         ?? 0
        halationAmount      = try c.decodeIfPresent(Float.self, forKey: .halationAmount)      ?? 0
        jpegArtifacts       = try c.decodeIfPresent(Float.self, forKey: .jpegArtifacts)       ?? 0
        scanlineAmount      = try c.decodeIfPresent(Float.self, forKey: .scanlineAmount)      ?? 0
        dateStamp           = try c.decode(DateStampConfig.self, forKey: .dateStamp)
    }
}
