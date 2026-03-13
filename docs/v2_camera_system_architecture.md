# 生产级相机系统架构设计说明

## 1. 相机系统设计原则

本架构设计彻底摒弃了传统的“全局滤镜库”模式，采用**“以相机为中心”**的实体化设计。系统中的每一个配置实体都代表一台真实的、具有独立特性的虚拟相机。

1. **相机实体化**：每台相机是一个完整的封闭系统，拥有自己的基础成像模型（Base Model）。
2. **选项私有化**：胶卷（Films）、镜头（Lenses）、相纸（Papers）、比例（Ratios）、水印（Watermarks）均作为相机的私有选项存在。不同相机的选项不保证通用。
3. **能力动态化**：UI 层不硬编码任何选择器逻辑，完全由相机的 `uiCapabilities` 动态驱动界面元素的显示与隐藏。
4. **管线模块化**：GPU 渲染管线根据相机配置的组合（基础模型 + 当前选中的胶卷/镜头/相纸等）动态拼装渲染 Pass。

## 2. JSON Schema 定义

以下是系统核心数据模型 `CameraDefinition` 的完整 JSON Schema 设计。

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "CameraDefinition",
  "type": "object",
  "required": ["id", "name", "category", "outputType", "baseModel", "optionGroups", "uiCapabilities"],
  "properties": {
    "id": { "type": "string", "description": "相机唯一标识" },
    "name": { "type": "string", "description": "相机显示名称" },
    "category": { "type": "string", "enum": ["ccd", "film", "instant", "disposable", "camcorder", "scanner"] },
    "outputType": { "type": "string", "enum": ["photo", "video", "both"] },
    "baseModel": {
      "type": "object",
      "required": ["sensor"],
      "properties": {
        "sensor": {
          "type": "object",
          "properties": {
            "type": { "type": "string" },
            "iso": { "type": "number" },
            "dynamicRange": { "type": "number" }
          }
        },
        "color": {
          "type": "object",
          "properties": {
            "lut": { "type": "string" },
            "temperature": { "type": "number" },
            "tint": { "type": "number" }
          }
        },
        "optical": {
          "type": "object",
          "properties": {
            "focalLength": { "type": "number" },
            "aperture": { "type": "number" }
          }
        }
      }
    },
    "optionGroups": {
      "type": "object",
      "properties": {
        "films": {
          "type": "array",
          "items": { "$ref": "#/definitions/FilmOption" }
        },
        "lenses": {
          "type": "array",
          "items": { "$ref": "#/definitions/LensOption" }
        },
        "papers": {
          "type": "array",
          "items": { "$ref": "#/definitions/PaperOption" }
        },
        "ratios": {
          "type": "array",
          "items": { "$ref": "#/definitions/RatioOption" }
        },
        "watermarks": {
          "type": "array",
          "items": { "$ref": "#/definitions/WatermarkOption" }
        }
      }
    },
    "uiCapabilities": {
      "type": "object",
      "required": ["showFilmSelector", "showLensSelector", "showPaperSelector", "showRatioSelector", "showWatermarkSelector"],
      "properties": {
        "showFilmSelector": { "type": "boolean" },
        "showLensSelector": { "type": "boolean" },
        "showPaperSelector": { "type": "boolean" },
        "showRatioSelector": { "type": "boolean" },
        "showWatermarkSelector": { "type": "boolean" }
      }
    }
  },
  "definitions": {
    "FilmOption": {
      "type": "object",
      "required": ["id", "name", "isDefault", "rendering"],
      "properties": {
        "id": { "type": "string" },
        "name": { "type": "string" },
        "isDefault": { "type": "boolean" },
        "rendering": {
          "type": "object",
          "properties": {
            "lut": { "type": "string" },
            "grainIntensity": { "type": "number" },
            "colorScience": { "type": "string" },
            "highlightBehavior": { "type": "number" },
            "toneCurve": { "type": "string" }
          }
        }
      }
    },
    "LensOption": {
      "type": "object",
      "required": ["id", "name", "isDefault", "rendering"],
      "properties": {
        "id": { "type": "string" },
        "name": { "type": "string" },
        "isDefault": { "type": "boolean" },
        "rendering": {
          "type": "object",
          "properties": {
            "vignette": { "type": "number" },
            "distortion": { "type": "number" },
            "chromaticAberration": { "type": "number" },
            "bloom": { "type": "number" },
            "flare": { "type": "string" }
          }
        }
      }
    },
    "PaperOption": {
      "type": "object",
      "required": ["id", "name", "isDefault", "rendering"],
      "properties": {
        "id": { "type": "string" },
        "name": { "type": "string" },
        "isDefault": { "type": "boolean" },
        "rendering": {
          "type": "object",
          "properties": {
            "frameBorder": { "type": "string" },
            "paperTexture": { "type": "string" },
            "paperColor": { "type": "string" }
          }
        }
      }
    },
    "RatioOption": {
      "type": "object",
      "required": ["id", "name", "isDefault", "value"],
      "properties": {
        "id": { "type": "string" },
        "name": { "type": "string" },
        "isDefault": { "type": "boolean" },
        "value": { "type": "string", "enum": ["4:3", "3:2", "1:1", "16:9", "9:16"] }
      }
    },
    "WatermarkOption": {
      "type": "object",
      "required": ["id", "name", "isDefault", "type", "rendering"],
      "properties": {
        "id": { "type": "string" },
        "name": { "type": "string" },
        "isDefault": { "type": "boolean" },
        "type": { "type": "string", "enum": ["digital_time", "ccd_date", "polaroid_text", "brand_logo", "rec_info"] },
        "rendering": {
          "type": "object",
          "properties": {
            "textFormat": { "type": "string" },
            "font": { "type": "string" },
            "color": { "type": "string" },
            "position": { "type": "string" },
            "opacity": { "type": "number" },
            "frameIntegration": { "type": "boolean" }
          }
        }
      }
    }
  }
}
```
