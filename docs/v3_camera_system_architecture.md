# 生产级相机系统架构设计说明 (V3)

## 1. 架构核心思想

基于“DAZZ 风格真实产品逻辑”，本架构彻底贯彻**相机即封闭系统**的理念：

1. **相机实体化**：每台相机拥有独立的 `baseModel`，定义了其不可更改的传感器特性、色彩科学和镜头光学基础。
2. **选项私有化**：胶卷（films）、镜头（lenses）、相纸（papers）、比例（ratios）、水印（watermarks）等所有 `optionGroups` 均为当前相机私有，绝不跨相机复用。
3. **渲染参数内联化**：在胶卷或镜头等选项中，除了基础的 ID 和名称，特定的渲染参数（如 `lut`, `grain`, `vignette`, `bloom` 等）直接内联在选项对象中（如 `rendering` 字段或直接展平），以保证极高的灵活性。
4. **UI 动态降级**：通过 `uiCapabilities` 明确声明该相机在 UI 层应该展示哪些选择器。如果不包含某个选项组，其对应的选择器必须隐藏。

## 2. JSON Schema 定义

为了适应真实预设中高度灵活的参数结构（例如某些相机 `baseModel` 里有 `scan`，有些有 `noise`，某些选项直接将参数放在顶层），Schema 设计采用了**宽松的动态字典**策略，但对核心层级进行严格约束。

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "CameraDefinition",
  "type": "object",
  "required": ["id", "name", "baseModel", "optionGroups", "uiCapabilities"],
  "properties": {
    "id": { "type": "string", "description": "相机唯一标识" },
    "name": { "type": "string", "description": "相机显示名称" },
    "category": { "type": "string", "description": "相机分类" },
    "outputType": { "type": "string", "enum": ["photo", "video", "both"] },
    
    "baseModel": {
      "type": "object",
      "description": "基础成像模型，包含传感器、色彩、光学等固有属性，结构极度灵活",
      "additionalProperties": { "type": "object" }
    },
    
    "optionGroups": {
      "type": "object",
      "properties": {
        "films": {
          "type": "array",
          "items": { "$ref": "#/definitions/OptionItem" }
        },
        "lenses": {
          "type": "array",
          "items": { "$ref": "#/definitions/OptionItem" }
        },
        "papers": {
          "type": "array",
          "items": { "$ref": "#/definitions/OptionItem" }
        },
        "ratios": {
          "type": "array",
          "items": { "$ref": "#/definitions/RatioItem" }
        },
        "watermarks": {
          "type": "array",
          "items": { "$ref": "#/definitions/WatermarkItem" }
        }
      }
    },
    
    "uiCapabilities": {
      "type": "object",
      "properties": {
        "showFilmSelector": { "type": "boolean", "default": false },
        "showLensSelector": { "type": "boolean", "default": false },
        "showPaperSelector": { "type": "boolean", "default": false },
        "showRatioSelector": { "type": "boolean", "default": false },
        "showWatermarkSelector": { "type": "boolean", "default": false }
      }
    }
  },
  "definitions": {
    "OptionItem": {
      "type": "object",
      "required": ["id", "name"],
      "properties": {
        "id": { "type": "string" },
        "name": { "type": "string" },
        "isDefault": { "type": "boolean" },
        "rendering": { "type": "object" }
      },
      "additionalProperties": true
    },
    "RatioItem": {
      "type": "object",
      "required": ["id", "value"],
      "properties": {
        "id": { "type": "string" },
        "value": { "type": "string" },
        "isDefault": { "type": "boolean" }
      },
      "additionalProperties": true
    },
    "WatermarkItem": {
      "type": "object",
      "required": ["id", "type"],
      "properties": {
        "id": { "type": "string" },
        "name": { "type": "string" },
        "type": { "type": "string" },
        "isDefault": { "type": "boolean" }
      },
      "additionalProperties": true
    }
  }
}
```

### Schema 设计亮点说明

1. **`baseModel` 的 `additionalProperties`**：允许直接传入 `"sensor": {...}`, `"color": {...}`, `"scan": {...}`, `"noise": {...}` 等完全自定义的键值对，原生渲染管线通过约定的 Key 去解析，极大地增强了不同种类相机的扩展性。
2. **`OptionItem` 的展平结构**：在实际业务中，某些简单的渲染参数（如 `bloom: 0.15` 或 `text: "POLAROID"`）直接写在选项的顶层，而复杂的参数可以放在 `rendering` 字典中。`additionalProperties: true` 完美支持了这种写法。
