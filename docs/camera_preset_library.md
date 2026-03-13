# DAZZ 相机预设库 · 完整清单

> 本文档汇总了当前项目中所有相机预设的完整信息，包括运行时 JSON（`assets/presets/`）和文档级相机定义（`docs/v3_camera_definitions.md`）两个层级。

---

## 一、资产层（运行时 JSON）

这 3 个文件是当前已落地到 `flutter_app/assets/presets/` 目录、可被 Flutter 直接加载的运行时预设。它们使用 **V1 扁平结构**（`params` 字段），适合直接映射到 GPU Shader Uniforms。

| 文件名 | ID | 分类 | 付费 | 支持视频 |
|--------|----|------|------|---------|
| `ccd_cool.json` | `ccd_cool_01` | CCD | 免费 | ✅ |
| `ccd_flash.json` | `ccd_flash_01` | CCD | 免费 | ❌ |
| `ccd_night.json` | `ccd_night_01` | CCD | **Premium** | ✅ |

### 渲染参数对比

| 参数 | CCD Cool | CCD Flash | CCD Night |
|------|----------|-----------|-----------|
| `exposureBias` | 0.2 | 0.5 | 0.8 |
| `contrast` | 1.15 | 1.2 | 1.3 |
| `saturation` | 0.85 | 1.1 | 1.2 |
| `temperatureShift` | -400K（冷） | +200K（暖） | -200K（冷） |
| `grainAmount` | 0.25 | 0.20 | **0.45** |
| `noiseAmount` | 0.15 | 0.10 | **0.35** |
| `vignetteAmount` | 0.40 | 0.30 | **0.55** |
| `chromaticAberration` | 0.018 | 0.012 | **0.025** |
| `bloomAmount` | 0.30 | 0.50 | **0.60** |
| `halationAmount` | 0.10 | 0.20 | **0.35** |
| `jpegArtifacts` | 0.05 | 0.08 | **0.12** |
| LUT 文件 | `lut_ccd_cool.png` | `lut_ccd_flash.png` | `lut_ccd_night.png` |
| 颗粒纹理 | `grain_fine.png` | `grain_fine.png` | `grain_coarse.png` |

---

## 二、文档级相机定义（V3 结构）

这 10 个相机定义使用 **V3 宽松结构**（`optionGroups` + `uiCapabilities`），是面向产品的完整相机模型，需要迁移到 `assets/presets/` 并拆分为独立 JSON 文件后才能被运行时加载。

| # | ID | 名称 | 分类 | 输出 | 胶卷选项 | 镜头选项 | 相纸选项 | 比例选项 | 水印选项 |
|---|----|------|------|------|---------|---------|---------|---------|---------|
| 1 | `ccd_2005` | CCD-2005 | digital_ccd | 照片 | 2 | — | — | 2 | 1 |
| 2 | `film_gold200` | Gold 200 | film | 照片 | 2 | — | — | 2 | 1 |
| 3 | `fuji_superia` | Superia | film | 照片 | 2 | — | — | 1 | — |
| 4 | `disposable_flash` | Disposable Flash | disposable | 照片 | 1 | — | — | 1 | 1 |
| 5 | `polaroid_classic` | Polaroid Classic | instant | 照片 | 1 | 2 | 2 | 1 | 1 |
| 6 | `ccd_night` | Night CCD | digital_ccd | 照片 | 1 | — | — | 1 | 1 |
| 7 | `vhs_cam` | VHS Camcorder | video | **视频** | — | — | — | 1 | 1 |
| 8 | `dv2003` | DV-2003 | video | **视频** | — | — | — | 1 | 1 |
| 9 | `portrait_soft` | Soft Portrait | film | 照片 | 1 | 1 | — | 1 | — |
| 10 | `film_scan` | Film Scan | scanner | 照片 | 2 | — | — | 1 | — |

### UI 能力矩阵

| 相机 | 胶卷选择器 | 镜头选择器 | 相纸选择器 | 比例选择器 | 水印选择器 |
|------|-----------|-----------|-----------|-----------|-----------|
| CCD-2005 | ✅ | ❌ | ❌ | ✅ | ✅ |
| Gold 200 | ✅ | ❌ | ❌ | ✅ | ✅ |
| Superia | ✅ | ❌ | ❌ | ✅ | ❌ |
| Disposable Flash | ❌ | ❌ | ❌ | ❌ | ✅ |
| Polaroid Classic | ✅ | ✅ | ✅ | ❌ | ✅ |
| Night CCD | ✅ | ❌ | ❌ | ✅ | ✅ |
| VHS Camcorder | ❌ | ❌ | ❌ | ✅ | ✅ |
| DV-2003 | ❌ | ❌ | ❌ | ✅ | ✅ |
| Soft Portrait | ✅ | ✅ | ❌ | ✅ | ❌ |
| Film Scan | ✅ | ❌ | ❌ | ✅ | ❌ |

---

## 三、资产缺口分析

当前 `assets/` 目录中**尚未包含**以下资源文件，需要在正式开发前补充：

### LUT 文件（`.cube` 或 `.png`）
- `lut_ccd_cool.png`、`lut_ccd_flash.png`、`lut_ccd_night.png`（已定义，文件未创建）
- `ccd_standard.cube`、`ccd_cool.cube`、`kodak_gold.cube`、`superia.cube` 等（V3 相机定义引用）

### 纹理文件
- `grain_fine.png`、`grain_coarse.png`（颗粒纹理）

### 相纸/边框叠加图
- Polaroid 白色边框、奶油色边框（`papers` 选项引用）

### 水印字体/图形资源
- 日期戳字体、VHS REC 图标等

---

## 四、待办：将 V3 相机定义迁移到运行时 JSON

目前 V3 相机定义仅存在于文档中，需要将每个相机拆分为独立的 JSON 文件并放入 `assets/presets/` 目录，同时更新 `PresetRepository` 的加载逻辑以支持 V3 结构的 `optionGroups` 字段。
