# DAZZ Retro Camera 渲染管线架构指南

**Author**: Manus AI
**Date**: March 17, 2026

## 1. 架构概述

DAZZ Retro Camera 经过 Phase 1 与 Phase 2 的深度重构后，已全面迁移至**参数驱动的统一 Native GPU 渲染架构**。本次重构彻底废弃了原有的多层渲染模式（Flutter Widget 特效层 + Flutter ColorFilter 矩阵 + 多相机独立 Shader），实现了预览与成片管线的高度统一。

重构后的架构具有以下核心特征：
- **数据驱动**：所有相机的色彩风格与光学特效完全由 JSON 配置文件（`defaultLook`、`filters`、`lenses`）定义，彻底消除了相机专用的 Pipeline 类与 Shader 文件。
- **性能优先**：所有像素级渲染逻辑全部下沉至 Android (OpenGL ES) 与 iOS (Metal) 的底层 GPU 着色器，Flutter 层仅负责参数聚合与最终 Texture 的展示。
- **所见即所得**：预览与成片共享完全一致的色彩算法（如温度、色调系数严格对齐），确保成片不发生色偏。

---

## 2. 预览管线 (Preview Pipeline)

预览管线的核心目标是在保证 60fps 实时渲染的前提下，尽可能还原胶片相机的色彩与光学特性。

### 2.1 数据流转

预览管线的数据流转经历了从配置读取到 GPU 渲染的完整过程：

1. **参数聚合**：Flutter 层的 `PreviewRenderParams` 将相机 JSON 的 `defaultLook`、当前滤镜（Filter）、当前镜头（Lens）以及用户的实时调节（如曝光、色温偏移）进行合并计算。
2. **序列化传递**：通过 `toJson()` 方法生成包含 40+ 个键值对的参数字典，经由 MethodChannel 发送至 Native 层。
3. **GPU 渲染**：
   - **Android**：`CameraGLRenderer.kt` 接收参数并更新 `@Volatile` 字段，随后在 EGL 线程的 GLSL Fragment Shader 中对 CameraX 传来的 OES 纹理进行实时处理，最终通过 `eglSwapBuffers` 将结果送入 Flutter 的 `SurfaceTexture`。
   - **iOS**：`MetalRenderer.swift` 接收参数并填充 `CCDParams` 结构体，随后在 `CameraShaders.metal` 中对 AVCapture 传来的 `CVPixelBuffer` 进行处理，最终返回给 Flutter 的 `Texture`。
4. **UI 展示**：Flutter 的 `PreviewFilterWidget` 仅作为一个纯净的容器显示底层 Texture，并在其上叠加非破坏性的 `WatermarkOverlay`（日期水印）与 `GridOverlay`（九宫格）。

![预览管线流程图](./preview_pipeline.png)

### 2.2 Shader 渲染 Pass (Android GLSL)

Android 端的 `CameraGLRenderer.kt` 使用了一个高度集成的 Fragment Shader，按照严格的光学与色彩逻辑顺序执行 20 个 Pass：

| 阶段 | Pass 名称 | 描述 |
|:---:|:---|:---|
| **预处理** | Pass 0: Sharpen | Unsharp Mask 锐化，增强原始纹理细节 |
| **光学畸变** | Pass 1: Chromatic Aberration | 模拟镜头边缘的红蓝/紫绿相差 |
| **基础色彩** | Pass 2: Temperature + Tint | 白平衡调整（正值偏暖/偏洋红） |
| | Pass 3: Blacks / Whites | Lightroom 风格黑白场控制 |
| | Pass 4: Highlights / Shadows | 高光压制与阴影提亮 |
| | Pass 5: Contrast | 基础对比度调整 |
| | Pass 6: Clarity | 局部微对比度增强（中间调通透度） |
| | Pass 7: Saturation + Vibrance | 基础饱和度与智能饱和度（保护高饱和区域） |
| | Pass 8: ColorBias | RGB 通道独立偏移（胶片底色模拟） |
| **高光特效** | Pass 9: Bloom | 阈值以上高光区域的光晕扩散 |
| | Pass 10: Halation | 模拟胶片防晕层失效产生的红色辉光 |
| | Pass 11: Highlight Rolloff | 高光柔和滚落，防止死白（预览版简化） |
| **传感器特性**| Pass 12: Sensor Non-uniformity | 包含中心增亮、边缘衰减、曝光波动及边角偏暖 |
| | Pass 13: Skin Protection | 基于 HSL 遮罩的肤色保护（防止冷色调使肤色发青） |
| | Pass 14: Development Softness | 模拟胶片显影过程中的轻微柔化 |
| **高级色彩** | Pass 15: Highlight Rolloff 2 | 配合 Tone Curve 的二次高光滚落 |
| | Pass 16: Tone Curve | 分段线性插值的胶片特征曲线（如 FXN-R） |
| **物理质感** | Pass 17: Paper Texture | 伪随机相纸纹理叠加 |
| | Pass 18: Film Grain | 胶片银盐颗粒感 |
| | Pass 19: Digital Noise | 包含亮度噪声与色度噪声的 CCD 噪点模拟 |
| **收尾** | Pass 20: Vignette | 镜头暗角（鱼眼模式下自动禁用） |

---

## 3. 成片管线 (Capture Pipeline)

成片管线在用户按下快门后触发，目标是对全分辨率 JPEG 进行最高质量的处理，包含部分因性能原因未在预览中启用的高级特效。

### 3.1 处理流程

成片管线（`capture_pipeline.dart`）的处理逻辑如下：

1. **原始解码**：读取系统相机拍摄的 JPEG 文件，为避免内存溢出（OOM），根据目标画质（如中画质 `kMaxDimMid = 2688`）在解码时限制最大边长。
2. **GPU 加速处理**：优先调用 Native 的 `processWithGpu` 接口。
   - **Android**：`CaptureGLProcessor.kt` 创建 EGL PBuffer 离屏上下文，将 JPEG 上传为 GL 纹理，执行与预览对齐的 19 Pass 完整管线（包含暗角、颗粒、色差、Bloom 等全部像素级效果），通过 `glReadPixels` 回读并编码为临时 JPEG。
   - **iOS**：`CaptureProcessor.swift` 调用 `CapturePipeline.metal` 的 Compute Shader（包含 17 个 Kernel Pass）进行高性能并行处理。
3. **Dart 降级处理**：若 GPU 处理失败，则回退到 Dart 层的参数驱动管线，依次应用高光滚落、传感器非均匀性、肤色保护、化学不规则感、相纸纹理、显影柔化 6 个步骤。
4. **裁剪与构图**：根据用户选择的比例（如 3:4、1:1）计算中心裁剪区域 `_calcCropRect`。
5. **Canvas 合成**：在 Dart Canvas 上完成最终图像的组装。

> **关键设计：GPU 与 Canvas 的职责分离**
>
> Canvas 层的绘制步骤严格区分为两类：
> - **始终执行**的步骤：背景色填充、主图绘制、内嵌阴影（相框专属）、漏光（相框专属）、鱼眼遮罩（几何遮罩）、相框 PNG 叠加、水印绘制。这些步骤属于构图层面的合成操作，GPU Shader 不负责处理。
> - **仅在 Dart 降级时执行**的步骤：暗角（Vignette）、颗粒（Grain + Noise）、色差（Chromatic Aberration）、Bloom / 柔焦。这些效果已由 GPU 成片管线完整处理，Canvas 层仅在 `gpuProcessed == false` 时作为降级补充。

完整的 Canvas 绘制顺序如下：

| 步骤 | 操作 | 执行条件 | 说明 |
|:---:|:---|:---|:---|
| 4a | 背景色填充 | 始终 | 画布底色（白色或相框指定色） |
| 4b | 主图绘制 | 始终 | GPU 已处理的图像直接 `drawImageRect`，不叠加 `colorMatrix` |
| 4c | 暗角 Vignette | `!gpuProcessed` | GPU 管线已包含 Vignette Pass |
| 4c3 | 颗粒 Grain + 噪点 | `!gpuProcessed` | GPU 管线已包含 Film Grain + Digital Noise Pass |
| 4c2 | 内嵌阴影 | 始终（相框专属） | 模拟相纸内凹厚度感，GPU 不处理 |
| 4d | 漏光 Light Leak | 始终（相框专属） | 角落径向暖色渐变，GPU 不处理 |
| 4e | 色差 Chromatic Aberration | `!gpuProcessed` | GPU 管线已包含 Chromatic Aberration Pass |
| 4e2 | Bloom / 柔焦 | `!gpuProcessed` | GPU 管线已包含 Bloom Pass |
| 4e3 | 鱼眼遮罩 | 始终（鱼眼模式） | 圆形外区域纯黑遮罩，几何操作 |
| 4f | 相框纹理 PNG 叠加 | 始终（有相框时） | 高分辨率相框 PNG 覆盖绘制 |
| 4g | 水印绘制 | 始终（有水印时） | 日期/时间文字水印 |

6. **最终输出**：根据设备方向旋转图像，最后以指定质量（如 `quality=80`）编码为 JPEG 输出 `CaptureResult`。

![成片管线流程图](./capture_pipeline.png)

### 3.2 成片专属 Shader Pass

成片管线的 Shader（Android: `CaptureGLProcessor.kt` / iOS: `CapturePipeline.metal`）在色彩处理上与预览管线保持了严格的系数一致性（彻底修复了之前的色偏 Bug）。此外，成片管线拥有更精细的物理模拟 Pass：

| 专属 Pass | 功能描述 |
|:---|:---|
| **Highlight Rolloff** | 采用更复杂的 S 形曲线压制高光，保留云层等亮部细节的色彩层次。 |
| **Center Gain & Edge Falloff** | 模拟老式镜头的中心通光量大、边缘衰减严重的物理光学缺陷。 |
| **Chemical Irregularity** | 模拟拍立得或胶片显影过程中化学药水分布不均造成的局部亮度/色彩波动。 |
| **Skin Protection** | 精确的 HSL 肤色遮罩，在应用强烈冷色调滤镜（如 CCD M）时，强行拉回并保护人物面部肤色。 |

---

## 4. 关键架构改进与 Bug 修复

### 4.1 统一路由与文件精简
- **移除硬编码**：删除了 10 个 Dart 端的 `xxx_pipeline.dart` 文件以及 iOS/Android 端共 16 个相机专用的 Shader/Renderer 文件。
- **通用管线**：所有的相机逻辑全部收敛于 `capture_pipeline.dart` 的统一路由中，消除了冗长的 `switch/case` 结构。

### 4.2 渲染逻辑全面下沉
- **废弃 Widget 特效**：删除了 `_ChromaticAberrationLayer`、`_BloomLayer` 等 5 个 Flutter 层的特效 Widget，将所有像素级操作（包括 `ColorFilter.matrix`）下沉至 Native Shader。
- **性能提升**：减少了 Flutter 层的图层嵌套与 Draw Call，显著降低了预览时的 CPU 占用，提升了取景器的流畅度。

### 4.3 核心 Bug 修复
- **成片严重色偏修复**：修复了 `CaptureGLProcessor.kt` 中色温与色调系数被错误放大 333 倍的问题（将 `shift * 0.1` 修正为与预览一致的 `shift / 1000.0 * 0.3`），彻底解决了 FQS、CCD R 等相机的成片变蓝/变橙问题。
- **相框逻辑修正**：从 9 个非拍立得相机的 JSON 配置中清空了错误的 `frames` 数组，并在管线中增加了 `supportedRatios` 校验，解决了 2:3 比例及数码相机下异常出现拍立得相框的 Bug。
- **成片效果双重叠加修复**：修复了 GPU 成片管线处理成功后，Dart Canvas 层仍然重复叠加暗角、颗粒、色差、Bloom 四个效果的 Bug。通过在这四个步骤前增加 `!gpuProcessed` 守卫条件，确保 GPU 已处理的效果不会被 Canvas 二次叠加。

---

## 5. 总结

通过本次重构，DAZZ Retro Camera 建立了一套**高内聚、低耦合**的跨平台渲染引擎。新增相机风格只需在 `cameras/` 目录下添加 JSON 配置文件即可，无需修改任何 Dart 或 Native 代码。这不仅极大提升了后续滤镜的研发效率，也为未来引入 3D LUT、更复杂的物理光学模拟奠定了坚实的架构基础。
