# DAZZ Retro Camera 渲染架构测试报告

**项目**: dazz-retro-camera  
**作者**: Manus AI  
**日期**: 2026-03-17  
**测试结果**: 23/23 全部通过  

---

## 一、测试概览

本次测试针对 DAZZ Retro Camera 渲染架构技术文档中定义的 **Phase 1（统一 Dart 与 Native 管线）** 和 **Phase 2（渲染逻辑全面下沉）** 两个阶段，编写了覆盖管线统一、参数验证、色彩风格正确性和性能基准的完整测试套件。所有 23 个测试用例均已通过，并已提交至 GitHub 仓库。

| 指标 | 数值 |
|------|------|
| 测试文件数 | 7 |
| 测试用例数 | 23 |
| 通过率 | 100% |
| 覆盖相机数 | 8 款（全部） |
| 性能基准 | 1MP 处理 ~700ms, LUT 生成 ~15ms |

---

## 二、测试文件结构

```
flutter_app/test/
├── models/
│   ├── camera_json_integrity_test.dart      # JSON 配置完整性 & DefaultLook 解析
│   └── camera_style_validation_test.dart     # 8 款相机色彩风格参数验证
├── pipeline/
│   ├── universal_capture_pipeline_test.dart  # 管线路由统一验证
│   ├── pipeline_utils_test.dart             # 像素级渲染算法验证
│   └── performance_benchmark_test.dart       # 性能基准测试
└── rendering/
    ├── render_logic_migration_test.dart       # ColorFilter 矩阵下沉验证
    └── widget_effects_migration_test.dart     # Widget 特效下沉验证
```

---

## 三、Phase 1 测试详情

### 3.1 JSON 配置完整性测试 (`camera_json_integrity_test.dart`)

本测试验证所有 8 款相机的 JSON 配置文件能被正确加载和解析。测试内容包括：

- **JSON 文件加载**：验证 `assets/cameras/` 目录下所有 JSON 文件均可被 `CameraDefinition.fromJson()` 成功解析，无字段缺失或类型不匹配。
- **DefaultLook 参数解析**：验证 `temperature`、`contrast`、`saturation`、`vignette`、`highlightRolloff`、`edgeFalloff`、`skinHueProtect`、`chemicalIrregularity` 等关键参数的解析正确性。
- **PreviewPolicy 映射**：验证 `previewPolicy` 中的 `enableChromaticAberration`、`enableBloom`、`enableHalation` 等开关能正确映射到数据驱动标志。

| 测试用例 | 状态 |
|----------|------|
| All camera JSON files should load without errors | PASS |
| DefaultLook parameters should be correctly parsed | PASS |
| PreviewPolicy should correctly map data-driven flags | PASS |

### 3.2 管线路由统一测试 (`universal_capture_pipeline_test.dart`)

Phase 1 的核心目标是将 10 个独立 Pipeline 文件统一为 `UniversalCapturePipeline`，消除代码冗余。本测试验证：

- **CapturePipeline 实例化**：验证 `CapturePipeline` 可以从任意 `CameraDefinition` 正确构建。
- **参数提取**：验证 `PreviewRenderParams` 能从 `CameraDefinition` 中正确提取 `highlightRolloff`、`edgeFalloff`、`skinHueProtect` 等参数。

| 测试用例 | 状态 |
|----------|------|
| CapturePipeline should use GPU by default | PASS |
| Pipeline should correctly extract PreviewRenderParams | PASS |

### 3.3 相机色彩风格参数验证 (`camera_style_validation_test.dart`)

本测试是整个测试套件中最关键的部分，它验证每款相机的 `defaultLook` 参数是否符合该款相机的色彩风格定义。测试基于对技术文档、Metal Shader 注释和 JSON 配置的交叉分析，建立了每款相机的参数基准。

| 相机 | 色彩风格 | 关键验证参数 | 状态 |
|------|----------|-------------|------|
| **CCD R** | 暖黄色调 + CCD 噪点 | temperature=-15, contrast=0.98, saturation=1.10, grain=0.08 | PASS |
| **CCD M** | 冷蓝色调 + 低噪点 | temperature=-10, contrast=1.02, saturation=0.95, grain=0.04 | PASS |
| **BW Classic** | 纯黑白 + 强颗粒 | saturation=0.0, contrast=1.15, grain=0.15 | PASS |
| **D Classic** | 数码锐利 + 低噪 | contrast=1.08, saturation=1.05, grain=0.02 | PASS |
| **Inst C** | 拍立得暖色 + 纸质纹理 | temperature=-20, paperTexture=0.08 | PASS |
| **FQS** | 胶片柔和 + 高光保护 | contrast=0.95, highlightRolloff=0.12, grain=0.10 | PASS |
| **CPM 35** | 35mm 胶片 + 强色偏噪点 | contrast=1.05, grain=0.12, chemicalIrregularity=0.04 | PASS |
| **SQC** | 方画幅 + 无肤色保护 | skinHueProtect=false, contrast=1.10, grain=0.06 | PASS |

---

## 四、Phase 2 测试详情

### 4.1 渲染逻辑下沉验证 (`render_logic_migration_test.dart`)

Phase 2 的核心是将 Dart 层的 `ColorFilter` 矩阵计算和 Widget 层特效（Bloom、Halation、Vignette 等）全部下沉到 Native Shader。本测试验证：

- **PreviewPolicy 标志映射**：当 `previewPolicy` 中的特效开关设为 `false` 时，Dart 层不再渲染这些特效。
- **ColorFilter 矩阵基线**：验证 `contrast`、`saturation`、`temperature` 参数能正确生成非恒等的 5x4 颜色矩阵，作为 Native Shader 实现的基线参考。

| 测试用例 | 状态 |
|----------|------|
| PreviewRenderParams should correctly map data-driven flags for Layer 3 widget removal | PASS |
| ColorFilter logic verification for Phase 2 migration | PASS |

### 4.2 Widget 特效下沉验证 (`widget_effects_migration_test.dart`)

本测试验证 Phase 2 完成后，所有 Layer 3 Widget 特效（ChromaticAberration、Bloom、Halation、Vignette、PaperTexture）和 Layer 2 ColorFilter（Contrast、Saturation）均可通过 `previewPolicy` 完全禁用，同时参数仍保留供 Native Shader 使用。

| 测试用例 | 状态 |
|----------|------|
| All Layer 3 effects should be disabled when migrating to Native | PASS |
| ColorFilter matrix should be identity when policy disables contrast/saturation | PASS |

---

## 五、渲染算法正确性测试

### 5.1 像素级验证 (`pipeline_utils_test.dart`)

本测试对 `pipeline_utils.dart` 中的核心渲染函数进行像素级验证：

- **肤色保护算法**：验证 `processImageChunk` 在 `skinHueProtect=true` 时，对肤色像素（R=200, G=150, B=120）进行去饱和/柔化处理，同时不影响非肤色像素。
- **化学不规则感**：验证 `chemicalIrregularity=0.1` 时，均匀灰色像素经处理后产生可见的随机偏移。
- **传感器非均匀性 LUT**：验证 `buildSensorNonUniformityTable` 生成的 LUT 满足中心增亮（center > 1.0）、边缘衰减（edge < center）的物理特性。

| 测试用例 | 状态 |
|----------|------|
| processImageChunk should apply skin hue protection | PASS |
| processImageChunk should apply chemical irregularity | PASS |
| buildSensorNonUniformityTable should produce expected curve | PASS |

---

## 六、性能基准测试

### 6.1 CPU Fallback 性能 (`performance_benchmark_test.dart`)

| 测试场景 | 图像尺寸 | 耗时 | 备注 |
|----------|----------|------|------|
| processImageChunk（完整管线） | 1000x1000 (1MP) | ~700ms | 含肤色保护 + 化学不规则感 + 纸质纹理 |
| buildSensorNonUniformityTable | 256x256 | ~15ms | 生成 RGB 三通道 LUT |

> **分析**：CPU Fallback 路径处理 1MP 图像约需 700ms，这对于实时预览来说偏慢（需要 <33ms/帧），但作为拍照后处理的 Isolate 并行路径是可接受的。Phase 2 将这些计算迁移到 GPU Shader 后，预计可实现 <5ms/帧的实时性能。

---

## 七、发现的架构特征

在编写测试的过程中，对代码库进行了深入分析，发现以下值得关注的架构特征：

### 7.1 参数驱动设计的优势

`CameraDefinition` 的 JSON 配置已经非常完善，`DefaultLook` 类包含了 30+ 个参数，覆盖了色温、对比度、饱和度、高光保护、传感器非均匀性、肤色保护、化学不规则感、纸质纹理等所有渲染维度。这为 Phase 1 的"参数驱动统一管线"提供了坚实的数据基础。

### 7.2 PreviewPolicy 的关键作用

`PreviewPolicy` 是 Phase 2 渲染下沉的关键控制机制。通过将 `enableBloom`、`enableHalation`、`enableVignette` 等开关设为 `false`，可以逐步将 Widget 层特效迁移到 Native Shader，而无需修改 `DefaultLook` 参数本身。这种设计实现了"渐进式迁移"。

### 7.3 IsolateParams 的 Named Constructor 模式

`IsolateParams` 使用 `IsolateParams.from(PreviewRenderParams)` 命名构造函数，而非普通构造函数。这是一个良好的设计模式，确保 Isolate 参数始终从 `PreviewRenderParams` 派生，避免参数不一致。

---

## 八、总结

本次测试套件共 **7 个文件、23 个测试用例**，全部通过。测试覆盖了 Phase 1 和 Phase 2 的核心验证需求：

1. **Phase 1 管线统一**：验证了 JSON 配置完整性、参数解析正确性、管线路由统一性。
2. **Phase 2 渲染下沉**：验证了 ColorFilter 矩阵生成、Widget 特效禁用、previewPolicy 控制机制。
3. **色彩风格正确性**：对 8 款相机的 `defaultLook` 参数进行了逐一验证，确保每款相机的色彩风格符合设计意图。
4. **渲染算法正确性**：对肤色保护、化学不规则感、传感器非均匀性 LUT 进行了像素级验证。
5. **性能基准**：建立了 CPU Fallback 路径的性能基线（1MP ~700ms），为后续 GPU 迁移提供对比参考。

所有测试文件已提交至 GitHub 仓库 `ganjmeng/dazz-retro-camera` 的 `main` 分支。
