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

struct PresetParams: Codable {
    let exposureBias: Float
    let contrast: Float
    let saturation: Float
    let temperatureShift: Float
    let tintShift: Float
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
}
