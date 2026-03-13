# Preset 模型设计

本文件定义了相机 Preset 的数据结构。为了保证跨平台的一致性和后续扩展（如云端下发、在线商店），采用 JSON 作为序列化标准，Flutter 和原生层分别实现对应的解析模型。

## 1. 核心数据结构

### 1.1 JSON 示例 (CCD Cool 风格)

```json
{
  "id": "ccd_cool_01",
  "name": "CCD Cool",
  "category": "CCD",
  "supportsPhoto": true,
  "supportsVideo": true,
  "isPremium": false,
  "resources": {
    "lutName": "lut_ccd_cool.png",
    "grainTextureName": "grain_fine.png",
    "leakTextureNames": ["leak_blue_01.png", "leak_blue_02.png"],
    "frameOverlayName": "frame_polaroid_white.png"
  },
  "params": {
    "exposureBias": 0.2,
    "contrast": 1.15,
    "saturation": 0.85,
    "temperatureShift": -400.0,
    "tintShift": 10.0,
    "sharpen": 0.4,
    "blurRadius": 1.2,
    "grainAmount": 0.25,
    "noiseAmount": 0.15,
    "vignetteAmount": 0.4,
    "chromaticAberration": 0.02,
    "bloomAmount": 0.3,
    "halationAmount": 0.1,
    "jpegArtifacts": 0.05,
    "scanlineAmount": 0.0,
    "dateStamp": {
      "enabled": true,
      "format": "yyyy MM dd",
      "color": "#FFFFA500",
      "position": "bottomRight"
    }
  }
}
```

## 2. 各端模型定义

### 2.1 Dart 模型 (Flutter 侧)

```dart
// lib/models/preset.dart
class Preset {
  final String id;
  final String name;
  final String category;
  final bool supportsPhoto;
  final bool supportsVideo;
  final bool isPremium;
  final PresetResources resources;
  final PresetParams params;

  Preset({
    required this.id,
    required this.name,
    required this.category,
    required this.supportsPhoto,
    required this.supportsVideo,
    required this.isPremium,
    required this.resources,
    required this.params,
  });

  factory Preset.fromJson(Map<String, dynamic> json) {
    // ... 解析逻辑
  }

  Map<String, dynamic> toJson() {
    // ... 序列化逻辑
  }
}

class PresetResources {
  final String lutName;
  final String grainTextureName;
  final List<String> leakTextureNames;
  final String? frameOverlayName;
  // ...
}

class PresetParams {
  final double exposureBias;
  final double contrast;
  final double temperatureShift; // 色温偏移，负数为冷色
  final double chromaticAberration; // 色差/RGB偏移程度
  final double bloomAmount; // 高光溢出程度
  // ... 其他参数
}
```

### 2.2 iOS 模型 (Swift 侧)

```swift
// ios/Classes/Models/Preset.swift
struct Preset: Codable {
    let id: String
    let name: String
    let resources: PresetResources
    let params: PresetParams
}

struct PresetResources: Codable {
    let lutName: String
    let grainTextureName: String
    let leakTextureNames: [String]
    let frameOverlayName: String?
}

struct PresetParams: Codable {
    let exposureBias: Float
    let contrast: Float
    let temperatureShift: Float
    let chromaticAberration: Float
    let bloomAmount: Float
    // ... 其他参数
}
```

### 2.3 Android 模型 (Kotlin 侧)

```kotlin
// android/src/main/kotlin/com/retrocam/app/models/Preset.kt
import kotlinx.serialization.Serializable

@Serializable
data class Preset(
    val id: String,
    val name: String,
    val resources: PresetResources,
    val params: PresetParams
)

@Serializable
data class PresetResources(
    val lutName: String,
    val grainTextureName: String,
    val leakTextureNames: List<String>,
    val frameOverlayName: String? = null
)

@Serializable
data class PresetParams(
    val exposureBias: Float,
    val contrast: Float,
    val temperatureShift: Float,
    val chromaticAberration: Float,
    val bloomAmount: Float
    // ... 其他参数
)
```

## 3. CCD 效果组合思路说明

根据需求，CCD 效果不是简单的 LUT 覆盖，而是通过 `PresetParams` 驱动多个 Shader Pass 组合而成：
1. **基础色彩**：通过 `temperatureShift` 偏冷/偏青，结合 `lutName` 进行色彩重映射。
2. **高光与光晕**：使用 `bloomAmount` 和 `halationAmount` 模拟老旧 CCD 传感器的高光溢出（Blooming）现象。
3. **质感与噪点**：结合 `grainAmount`（胶片颗粒纹理）和 `noiseAmount`（动态数字噪点）模拟暗部噪点。
4. **镜头缺陷**：通过 `vignetteAmount` 增加暗角，通过 `chromaticAberration` 模拟边缘的 RGB 通道分离（色差）。
5. **清晰度衰减**：利用 `blurRadius` 和 `sharpen` 的组合，先轻微模糊再锐化，模拟早期数码相机的边缘伪影。
6. **日期水印**：通过 `dateStamp` 配置在右下角叠加复古橙色字体。
