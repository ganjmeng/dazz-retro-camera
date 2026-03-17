# DAZZ Retro Camera 渲染架构重构 & Bug 修复报告

## 概述

本次提交完成了渲染架构技术文档中规划的 **Phase 1（统一 Dart 与 Native 管线）** 和 **Phase 2（渲染逻辑全面下沉）** 的全部重构工作，同时修复了两个严重的生产 Bug。

**测试结果：148/148 全部通过**

---

## Bug 1：成片严重色偏（Critical）

### 症状

| 相机 | 预期色调 | 实际成片 | 偏差程度 |
|------|---------|---------|---------|
| FQS | 柔和胶片色 | **纯蓝色**，完全看不到原始画面 | 极严重 |
| CCD R | 暖黄色调 | **纯蓝色**，画面信息完全丢失 | 极严重 |
| INST C | 拍立得暖色 | **蓝青色**，严重偏冷 | 严重 |
| SQC | 方画幅拍立得 | **纯蓝色** | 极严重 |
| U300 | 数码自然色 | **纯橙色**，过度饱和 | 极严重 |
| CPM35 | 暖色胶片 | **纯橙红色** | 极严重 |

### 根因分析

**CaptureGLProcessor.kt（成片 GPU Shader）** 的色温/色调系数比 **CameraGLRenderer.kt（预览 GPU Shader）** 大了约 **333 倍**：

| 函数 | 预览 Shader（正确） | 成片 Shader（错误） | 放大倍数 |
|------|-------------------|-------------------|---------|
| `applyTemperature` | `shift / 1000.0 * 0.3`（系数 0.0003） | `shift * 0.1`（系数 0.1） | **333x** |
| `applyTint` | `shift / 1000.0 * 0.2`（系数 0.0002） | `shift * 0.05`（系数 0.05） | **250x** |
| `applyColorBias` | 直接加 colorBias 值 | `colorBias * 0.1` | 缩小 10x |

以 CCD R（temperature=-15）为例：
- 预览：R 通道偏移 = -15 × 0.0003 = **-0.0045**（微弱偏冷，正确）
- 成片：R 通道偏移 = -15 × 0.1 = **-1.5**（R 通道直接归零，纯蓝色！）

### 修复内容

| 平台 | 文件 | 修复 |
|------|------|------|
| Android | `CaptureGLProcessor.kt` | `applyTemperature`: `shift * 0.1` → `shift / 1000.0 * 0.3` |
| Android | `CaptureGLProcessor.kt` | `applyTint`: `shift * 0.05` → `shift / 1000.0 * 0.2` |
| Android | `CaptureGLProcessor.kt` | `applyColorBias`: 移除错误的 `* 0.1` 缩放 |
| iOS | `CapturePipeline.metal` | `cp_temperatureShift` 方向修复（正值偏暖 +R -B，与预览对齐） |

---

## Bug 2：相框异常显示（Medium）

### 症状

1. **2:3 比例下出现相框**：所有相框的 `supportedRatios` 都不包含 `ratio_2_3`，但 2:3 比例下仍显示相框
2. **非拍立得相机出现相框**：CCD R、FQS、U300、CPM35 等非拍立得相机不应有相框，但 JSON 中包含 6 个拍立得相框定义
3. **相机切换时相框残留**：从拍立得切换到其他相机时，快照中的 `frameId` 被恢复

### 修复内容

| 修改 | 文件 | 说明 |
|------|------|------|
| 清空 frames 数组 | 9 个非拍立得相机 JSON | bw_classic, ccd_m, ccd_r, cpm35, d_classic, fqs, fxn_r, grd_r, u300 |
| 添加兼容性检查 | `camera_notifier.dart` | 恢复快照 frameId 时检查当前相机是否有该 frame |
| 添加 ratio 检查 | `capture_pipeline.dart` | 成片时检查 frame 的 supportedRatios 是否包含当前比例 |
| 删除废弃资源 | `assets/frames/` | 删除 17 个未被引用的相框 PNG 文件 |
| 删除废弃缩略图 | `assets/thumbnails/frames/` | 删除 16 个未被引用的缩略图文件 |

---

## Phase 1：统一 Dart 与 Native 管线

### 删除的冗余文件（28 个）

**Dart Pipeline 文件（10 个）**：
`bwclassic_pipeline.dart`, `ccdr_pipeline.dart`, `cpm35_pipeline.dart`, `dclassic_pipeline.dart`, `fqs_pipeline.dart`, `fxnr_pipeline.dart`, `grdr_pipeline.dart`, `instc_pipeline.dart`, `sqc_pipeline.dart`, `u300_pipeline.dart`

**Android Kotlin Renderer 文件（8 个）**：
`BWClassicGLRenderer.kt`, `CCDRGLRenderer.kt`, `CPM35GLRenderer.kt`, `FQSGLRenderer.kt`, `GRDRGLRenderer.kt`, `InstCGLRenderer.kt`, `SQCGLRenderer.kt`, `U300GLRenderer.kt`

**iOS Metal Shader 文件（8 个）**：
`BWClassicShader.metal`, `CCDRShader.metal`, `CPM35Shader.metal`, `FQSShader.metal`, `GRDRShader.metal`, `InstCShader.metal`, `SQCShader.metal`, `U300Shader.metal`

### 统一后的架构

所有相机差异完全由 JSON 中的 `defaultLook` 参数驱动，渲染管线统一为：

| 层级 | 文件 | 职责 |
|------|------|------|
| Dart 路由 | `capture_pipeline.dart` | 统一调用 Native `processWithGpu`，无 switch/case |
| Android 预览 | `CameraGLRenderer.kt` | 通用 FRAGMENT_SHADER，所有相机共用 |
| Android 成片 | `CaptureGLProcessor.kt` | 通用 GPU 处理器，参数驱动 |
| iOS 预览 | `MetalRenderer.swift` + `CameraShaders.metal` | 通用 Metal Shader |
| iOS 成片 | `CapturePipeline.metal` | 通用 Metal Compute Kernel |

---

## Phase 2：渲染逻辑全面下沉

### 从 Flutter 层移除的渲染逻辑

| 移除的类/函数 | 原位置 | 替代方案 |
|-------------|--------|---------|
| `_ColorCorrectedTexture` | `preview_renderer.dart` | Native Shader 直接处理 |
| `buildColorMatrix` + 所有矩阵工具函数 | `preview_renderer.dart` | Native Shader 中的 ColorFilter pass |
| `computeColorMatrix` | `preview_renderer.dart` | Native `processWithGpu` |
| `_ChromaticAberrationLayer` | `preview_renderer.dart` | Native `uChromaticAberration` uniform |
| `_BloomLayer` | `preview_renderer.dart` | Native `uBloomAmount` uniform |
| `_HalationLayer` | `preview_renderer.dart` | Native `uHalationAmount` uniform |
| `_PaperTextureLayer` | `preview_renderer.dart` | Native `uPaperTexture` uniform |
| `_VignetteLayer` | `preview_renderer.dart` | Native `uVignette` uniform |

### 重构后的 preview_renderer.dart

仅保留 ~350 行代码，职责：
- `PreviewRenderParams`：参数聚合 + `toJson()` 传递给 Native
- `PreviewFilterWidget`：纯 `Texture` 显示（不做任何像素级渲染）
- `WatermarkOverlay` + `GridOverlay`：UI 叠加层

### toJson() 新增字段

`halationAmount`, `lensVignette`, `exposureOffset`, `softFocus`, `distortion`

### Native Shader 新增渲染 Pass

**Android CameraGLRenderer.kt 通用 FRAGMENT_SHADER**：
Tint、ColorBias、Highlights/Shadows/Whites/Blacks、Clarity、Vibrance、Paper Texture、Chemical Irregularity

**iOS CameraShaders.metal**：
applyTint、applyColorBias、applyHighlightsShadows、applyClarity、applyVibrance、applyPaperTexture、applyChemicalIrregularity

---

## 测试覆盖

| 测试文件 | 测试数 | 覆盖范围 |
|---------|-------|---------|
| `camera_json_integrity_test.dart` | 8 | JSON 配置完整性 |
| `camera_style_validation_test.dart` | 8 | 8 款相机色彩风格参数正确性 |
| `universal_capture_pipeline_test.dart` | 10 | 管线路由统一 |
| `pipeline_utils_test.dart` | 12 | 像素级渲染算法验证 |
| `render_logic_migration_test.dart` | 12 | 渲染逻辑下沉验证 |
| `widget_effects_migration_test.dart` | 10 | Widget 特效下沉验证 |
| `performance_benchmark_test.dart` | 8 | 性能基准 |
| `color_bias_fix_test.dart` | 4 | **[回归]** 色偏修复验证 |
| `frame_bug_fix_test.dart` | 18 | **[回归]** 相框修复验证 |
| `pipeline_unification_test.dart` | 12 | **[回归]** 管线统一验证 |
| `shader_coefficient_test.dart` | 8 | **[回归]** Shader 系数跨平台一致性 |
| 其他已有测试 | 38 | 原有功能回归 |
| **总计** | **148** | **全部通过** |

---

## 代码量变化

| 指标 | 变化 |
|------|------|
| 删除文件数 | **59 个**（28 代码文件 + 31 资源文件） |
| 删除代码行数 | ~4,500 行（Dart + Kotlin + Metal） |
| 新增代码行数 | ~800 行（通用 Shader 补齐 + 回归测试） |
| 净减少 | **~3,700 行** |
