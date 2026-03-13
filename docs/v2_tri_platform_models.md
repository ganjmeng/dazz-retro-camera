## 三端数据模型代码 (Dart / Swift / Kotlin)

为了适配全新的相机实体化架构，以下是 Flutter、iOS 和 Android 三端对应的数据模型实现。

### 1. Dart 模型 (Flutter 侧)

```dart
// lib/models/camera_definition.dart
class CameraDefinition {
  final String id;
  final String name;
  final String category;
  final String outputType;
  final BaseModel baseModel;
  final OptionGroups optionGroups;
  final UiCapabilities uiCapabilities;

  CameraDefinition({
    required this.id,
    required this.name,
    required this.category,
    required this.outputType,
    required this.baseModel,
    required this.optionGroups,
    required this.uiCapabilities,
  });

  factory CameraDefinition.fromJson(Map<String, dynamic> json) {
    return CameraDefinition(
      id: json['id'],
      name: json['name'],
      category: json['category'],
      outputType: json['outputType'],
      baseModel: BaseModel.fromJson(json['baseModel']),
      optionGroups: OptionGroups.fromJson(json['optionGroups'] ?? {}),
      uiCapabilities: UiCapabilities.fromJson(json['uiCapabilities']),
    );
  }
}

class BaseModel {
  final SensorModel sensor;
  final ColorModel color;
  final OpticalModel? optical;

  BaseModel({required this.sensor, required this.color, this.optical});

  factory BaseModel.fromJson(Map<String, dynamic> json) {
    return BaseModel(
      sensor: SensorModel.fromJson(json['sensor']),
      color: ColorModel.fromJson(json['color']),
      optical: json['optical'] != null ? OpticalModel.fromJson(json['optical']) : null,
    );
  }
}

class SensorModel {
  final String type;
  final double? iso;
  final double? dynamicRange;

  SensorModel({required this.type, this.iso, this.dynamicRange});

  factory SensorModel.fromJson(Map<String, dynamic> json) {
    return SensorModel(
      type: json['type'],
      iso: json['iso']?.toDouble(),
      dynamicRange: json['dynamicRange']?.toDouble(),
    );
  }
}

class ColorModel {
  final String lut;
  final double? temperature;
  final double? tint;

  ColorModel({required this.lut, this.temperature, this.tint});

  factory ColorModel.fromJson(Map<String, dynamic> json) {
    return ColorModel(
      lut: json['lut'],
      temperature: json['temperature']?.toDouble(),
      tint: json['tint']?.toDouble(),
    );
  }
}

class OpticalModel {
  final double focalLength;
  final double aperture;

  OpticalModel({required this.focalLength, required this.aperture});

  factory OpticalModel.fromJson(Map<String, dynamic> json) {
    return OpticalModel(
      focalLength: json['focalLength']?.toDouble() ?? 35.0,
      aperture: json['aperture']?.toDouble() ?? 2.0,
    );
  }
}

class OptionGroups {
  final List<FilmOption>? films;
  final List<LensOption>? lenses;
  final List<PaperOption>? papers;
  final List<RatioOption>? ratios;
  final List<WatermarkOption>? watermarks;

  OptionGroups({this.films, this.lenses, this.papers, this.ratios, this.watermarks});

  factory OptionGroups.fromJson(Map<String, dynamic> json) {
    return OptionGroups(
      films: (json['films'] as List?)?.map((e) => FilmOption.fromJson(e)).toList(),
      lenses: (json['lenses'] as List?)?.map((e) => LensOption.fromJson(e)).toList(),
      papers: (json['papers'] as List?)?.map((e) => PaperOption.fromJson(e)).toList(),
      ratios: (json['ratios'] as List?)?.map((e) => RatioOption.fromJson(e)).toList(),
      watermarks: (json['watermarks'] as List?)?.map((e) => WatermarkOption.fromJson(e)).toList(),
    );
  }
}

class FilmOption {
  final String id;
  final String name;
  final bool isDefault;
  final Map<String, dynamic> rendering;

  FilmOption({required this.id, required this.name, required this.isDefault, required this.rendering});

  factory FilmOption.fromJson(Map<String, dynamic> json) {
    return FilmOption(
      id: json['id'],
      name: json['name'],
      isDefault: json['isDefault'] ?? false,
      rendering: json['rendering'] ?? {},
    );
  }
}

class LensOption {
  final String id;
  final String name;
  final bool isDefault;
  final Map<String, dynamic> rendering;

  LensOption({required this.id, required this.name, required this.isDefault, required this.rendering});

  factory LensOption.fromJson(Map<String, dynamic> json) {
    return LensOption(
      id: json['id'],
      name: json['name'],
      isDefault: json['isDefault'] ?? false,
      rendering: json['rendering'] ?? {},
    );
  }
}

class PaperOption {
  final String id;
  final String name;
  final bool isDefault;
  final Map<String, dynamic> rendering;

  PaperOption({required this.id, required this.name, required this.isDefault, required this.rendering});

  factory PaperOption.fromJson(Map<String, dynamic> json) {
    return PaperOption(
      id: json['id'],
      name: json['name'],
      isDefault: json['isDefault'] ?? false,
      rendering: json['rendering'] ?? {},
    );
  }
}

class RatioOption {
  final String id;
  final String name;
  final bool isDefault;
  final String value;

  RatioOption({required this.id, required this.name, required this.isDefault, required this.value});

  factory RatioOption.fromJson(Map<String, dynamic> json) {
    return RatioOption(
      id: json['id'],
      name: json['name'],
      isDefault: json['isDefault'] ?? false,
      value: json['value'],
    );
  }
}

class WatermarkOption {
  final String id;
  final String name;
  final bool isDefault;
  final String type;
  final Map<String, dynamic> rendering;

  WatermarkOption({required this.id, required this.name, required this.isDefault, required this.type, required this.rendering});

  factory WatermarkOption.fromJson(Map<String, dynamic> json) {
    return WatermarkOption(
      id: json['id'],
      name: json['name'],
      isDefault: json['isDefault'] ?? false,
      type: json['type'],
      rendering: json['rendering'] ?? {},
    );
  }
}

class UiCapabilities {
  final bool showFilmSelector;
  final bool showLensSelector;
  final bool showPaperSelector;
  final bool showRatioSelector;
  final bool showWatermarkSelector;

  UiCapabilities({
    required this.showFilmSelector,
    required this.showLensSelector,
    required this.showPaperSelector,
    required this.showRatioSelector,
    required this.showWatermarkSelector,
  });

  factory UiCapabilities.fromJson(Map<String, dynamic> json) {
    return UiCapabilities(
      showFilmSelector: json['showFilmSelector'] ?? false,
      showLensSelector: json['showLensSelector'] ?? false,
      showPaperSelector: json['showPaperSelector'] ?? false,
      showRatioSelector: json['showRatioSelector'] ?? false,
      showWatermarkSelector: json['showWatermarkSelector'] ?? false,
    );
  }
}
```

### 2. iOS 模型 (Swift 侧)

```swift
// ios/Classes/Models/CameraDefinition.swift
import Foundation

struct CameraDefinition: Codable {
    let id: String
    let name: String
    let category: String
    let outputType: String
    let baseModel: BaseModel
    let optionGroups: OptionGroups?
    let uiCapabilities: UiCapabilities
}

struct BaseModel: Codable {
    let sensor: SensorModel
    let color: ColorModel
    let optical: OpticalModel?
}

struct SensorModel: Codable {
    let type: String
    let iso: Double?
    let dynamicRange: Double?
}

struct ColorModel: Codable {
    let lut: String
    let temperature: Double?
    let tint: Double?
}

struct OpticalModel: Codable {
    let focalLength: Double?
    let aperture: Double?
}

struct OptionGroups: Codable {
    let films: [FilmOption]?
    let lenses: [LensOption]?
    let papers: [PaperOption]?
    let ratios: [RatioOption]?
    let watermarks: [WatermarkOption]?
}

struct FilmOption: Codable {
    let id: String
    let name: String
    let isDefault: Bool
    let rendering: [String: AnyCodable]
}

struct LensOption: Codable {
    let id: String
    let name: String
    let isDefault: Bool
    let rendering: [String: AnyCodable]
}

struct PaperOption: Codable {
    let id: String
    let name: String
    let isDefault: Bool
    let rendering: [String: AnyCodable]
}

struct RatioOption: Codable {
    let id: String
    let name: String
    let isDefault: Bool
    let value: String
}

struct WatermarkOption: Codable {
    let id: String
    let name: String
    let isDefault: Bool
    let type: String
    let rendering: [String: AnyCodable]
}

struct UiCapabilities: Codable {
    let showFilmSelector: Bool
    let showLensSelector: Bool
    let showPaperSelector: Bool
    let showRatioSelector: Bool
    let showWatermarkSelector: Bool
}

// AnyCodable 用于处理动态的 rendering 字典
struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) { value = intVal }
        else if let doubleVal = try? container.decode(Double.self) { value = doubleVal }
        else if let boolVal = try? container.decode(Bool.self) { value = boolVal }
        else if let stringVal = try? container.decode(String.self) { value = stringVal }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "AnyCodable value cannot be decoded") }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let intVal = value as? Int { try container.encode(intVal) }
        else if let doubleVal = value as? Double { try container.encode(doubleVal) }
        else if let boolVal = value as? Bool { try container.encode(boolVal) }
        else if let stringVal = value as? String { try container.encode(stringVal) }
        else { throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "AnyCodable value cannot be encoded")) }
    }
}
```

### 3. Android 模型 (Kotlin 侧)

```kotlin
// android/src/main/kotlin/com/retrocam/app/models/CameraDefinition.kt
package com.retrocam.app.models

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

@Serializable
data class CameraDefinition(
    val id: String,
    val name: String,
    val category: String,
    val outputType: String,
    val baseModel: BaseModel,
    val optionGroups: OptionGroups? = null,
    val uiCapabilities: UiCapabilities
)

@Serializable
data class BaseModel(
    val sensor: SensorModel,
    val color: ColorModel,
    val optical: OpticalModel? = null
)

@Serializable
data class SensorModel(
    val type: String,
    val iso: Double? = null,
    val dynamicRange: Double? = null
)

@Serializable
data class ColorModel(
    val lut: String,
    val temperature: Double? = null,
    val tint: Double? = null
)

@Serializable
data class OpticalModel(
    val focalLength: Double? = null,
    val aperture: Double? = null
)

@Serializable
data class OptionGroups(
    val films: List<FilmOption>? = null,
    val lenses: List<LensOption>? = null,
    val papers: List<PaperOption>? = null,
    val ratios: List<RatioOption>? = null,
    val watermarks: List<WatermarkOption>? = null
)

@Serializable
data class FilmOption(
    val id: String,
    val name: String,
    val isDefault: Boolean = false,
    val rendering: Map<String, JsonElement>
)

@Serializable
data class LensOption(
    val id: String,
    val name: String,
    val isDefault: Boolean = false,
    val rendering: Map<String, JsonElement>
)

@Serializable
data class PaperOption(
    val id: String,
    val name: String,
    val isDefault: Boolean = false,
    val rendering: Map<String, JsonElement>
)

@Serializable
data class RatioOption(
    val id: String,
    val name: String,
    val isDefault: Boolean = false,
    val value: String
)

@Serializable
data class WatermarkOption(
    val id: String,
    val name: String,
    val isDefault: Boolean = false,
    val type: String,
    val rendering: Map<String, JsonElement>
)

@Serializable
data class UiCapabilities(
    val showFilmSelector: Boolean,
    val showLensSelector: Boolean,
    val showPaperSelector: Boolean,
    val showRatioSelector: Boolean,
    val showWatermarkSelector: Boolean
)
```
