## 三端数据模型与 Bridge API 设计 (V3)

为适配极其灵活的 JSON 结构，三端模型需要使用动态字典（Map/Dictionary）来承载未定字段。

### 1. Flutter 模型 (Dart)

```dart
// lib/models/camera_definition.dart
class CameraDefinition {
  final String id;
  final String name;
  final String category;
  final String outputType;
  final Map<String, dynamic> baseModel;
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
      category: json['category'] ?? 'unknown',
      outputType: json['outputType'] ?? 'photo',
      baseModel: json['baseModel'] ?? {},
      optionGroups: OptionGroups.fromJson(json['optionGroups'] ?? {}),
      uiCapabilities: UiCapabilities.fromJson(json['uiCapabilities'] ?? {}),
    );
  }
}

class OptionGroups {
  final List<OptionItem> films;
  final List<OptionItem> lenses;
  final List<OptionItem> papers;
  final List<OptionItem> ratios;
  final List<OptionItem> watermarks;

  OptionGroups({
    this.films = const [],
    this.lenses = const [],
    this.papers = const [],
    this.ratios = const [],
    this.watermarks = const [],
  });

  factory OptionGroups.fromJson(Map<String, dynamic> json) {
    return OptionGroups(
      films: (json['films'] as List?)?.map((e) => OptionItem.fromJson(e)).toList() ?? [],
      lenses: (json['lenses'] as List?)?.map((e) => OptionItem.fromJson(e)).toList() ?? [],
      papers: (json['papers'] as List?)?.map((e) => OptionItem.fromJson(e)).toList() ?? [],
      ratios: (json['ratios'] as List?)?.map((e) => OptionItem.fromJson(e)).toList() ?? [],
      watermarks: (json['watermarks'] as List?)?.map((e) => OptionItem.fromJson(e)).toList() ?? [],
    );
  }
}

class OptionItem {
  final String id;
  final String? name;
  final bool isDefault;
  final Map<String, dynamic> properties; // 承载所有额外属性

  OptionItem({required this.id, this.name, this.isDefault = false, required this.properties});

  factory OptionItem.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> props = Map.from(json);
    props.remove('id');
    props.remove('name');
    props.remove('isDefault');
    
    return OptionItem(
      id: json['id'],
      name: json['name'],
      isDefault: json['isDefault'] ?? false,
      properties: props,
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
    this.showFilmSelector = false,
    this.showLensSelector = false,
    this.showPaperSelector = false,
    this.showRatioSelector = false,
    this.showWatermarkSelector = false,
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

### 2. iOS 模型 (Swift)

```swift
// ios/Classes/Models/CameraDefinition.swift
import Foundation

struct CameraDefinition: Codable {
    let id: String
    let name: String
    let category: String?
    let outputType: String?
    let baseModel: [String: AnyCodable]
    let optionGroups: OptionGroups?
    let uiCapabilities: UiCapabilities?
}

struct OptionGroups: Codable {
    let films: [OptionItem]?
    let lenses: [OptionItem]?
    let papers: [OptionItem]?
    let ratios: [OptionItem]?
    let watermarks: [OptionItem]?
}

struct OptionItem: Codable {
    let id: String
    let name: String?
    let isDefault: Bool?
    // 使用一个通用的字典来接管剩余的所有字段，需要自定义解码逻辑
    var properties: [String: AnyCodable] = [:]
    
    private struct DynamicCodingKeys: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { return nil }
        init?(intValue: Int) { return nil }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKeys.self)
        var props: [String: AnyCodable] = [:]
        
        // 提取已知字段
        id = try container.decode(String.self, forKey: DynamicCodingKeys(stringValue: "id")!)
        name = try container.decodeIfPresent(String.self, forKey: DynamicCodingKeys(stringValue: "name")!)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: DynamicCodingKeys(stringValue: "isDefault")!)
        
        // 提取未知字段
        for key in container.allKeys {
            if key.stringValue != "id" && key.stringValue != "name" && key.stringValue != "isDefault" {
                if let value = try? container.decode(AnyCodable.self, forKey: key) {
                    props[key.stringValue] = value
                }
            }
        }
        properties = props
    }
}

struct UiCapabilities: Codable {
    let showFilmSelector: Bool?
    let showLensSelector: Bool?
    let showPaperSelector: Bool?
    let showRatioSelector: Bool?
    let showWatermarkSelector: Bool?
}

// AnyCodable 的实现与之前相同
```

### 3. Android 模型 (Kotlin)

```kotlin
// android/src/main/kotlin/com/retrocam/app/models/CameraDefinition.kt
package com.retrocam.app.models

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder

@Serializable
data class CameraDefinition(
    val id: String,
    val name: String,
    val category: String? = null,
    val outputType: String? = null,
    val baseModel: Map<String, JsonElement>,
    val optionGroups: OptionGroups? = null,
    val uiCapabilities: UiCapabilities? = null
)

@Serializable
data class OptionGroups(
    val films: List<OptionItem>? = null,
    val lenses: List<OptionItem>? = null,
    val papers: List<OptionItem>? = null,
    val ratios: List<OptionItem>? = null,
    val watermarks: List<OptionItem>? = null
)

@Serializable(with = OptionItemSerializer::class)
data class OptionItem(
    val id: String,
    val name: String? = null,
    val isDefault: Boolean = false,
    val properties: Map<String, JsonElement> = emptyMap()
)

// 自定义序列化器处理展平的动态属性
object OptionItemSerializer : KSerializer<OptionItem> {
    override val descriptor: SerialDescriptor = JsonObject.serializer().descriptor

    override fun deserialize(decoder: Decoder): OptionItem {
        val jsonDecoder = decoder as JsonDecoder
        val jsonObject = jsonDecoder.decodeJsonElement() as JsonObject
        
        val id = jsonObject["id"]?.let { jsonDecoder.json.decodeFromJsonElement<String>(it) } ?: ""
        val name = jsonObject["name"]?.let { jsonDecoder.json.decodeFromJsonElement<String>(it) }
        val isDefault = jsonObject["isDefault"]?.let { jsonDecoder.json.decodeFromJsonElement<Boolean>(it) } ?: false
        
        val properties = jsonObject.filterKeys { it != "id" && it != "name" && it != "isDefault" }
        
        return OptionItem(id, name, isDefault, properties)
    }

    override fun serialize(encoder: Encoder, value: OptionItem) {
        // 略，如果不需要从原生传回 Flutter 则无需实现
    }
}

@Serializable
data class UiCapabilities(
    val showFilmSelector: Boolean = false,
    val showLensSelector: Boolean = false,
    val showPaperSelector: Boolean = false,
    val showRatioSelector: Boolean = false,
    val showWatermarkSelector: Boolean = false
)
```

### 4. Bridge API 接口更新

MethodChannel `com.retrocam.app/camera_control`

由于相机配置变得极其复杂且动态，建议 Flutter 端不要在每次切换小选项时发送零散指令，而是**每次有选项变更时，发送完整的相机当前状态快照**。

| 方法名 | 参数 (JSON) | 返回值 | 说明 |
|---|---|---|---|
| `setCameraConfig` | `{ "camera": <CameraDefinition JSON>, "activeOptions": { "film": "ccd_cool", "ratio": "ratio_4_3" } }` | `{"success": true}` | 初始化或切换相机时，发送完整的相机定义及当前选中的各组选项 ID。原生层解析后重建渲染管线。 |
| `updateActiveOptions` | `{ "film": "ccd_default", "watermark": "none" }` | `{"success": true}` | 用户在 UI 上切换某个选项时，发送增量更新。原生层查找 `CameraDefinition` 中对应的 `OptionItem` 并更新 Shader Uniforms。 |
| `takePhoto` | `{ "flashMode": "off" }` | `{"filePath": "..."}` | 拍照。注意：**相纸和水印效果将在此时被直接渲染进导出的照片中**。 |
