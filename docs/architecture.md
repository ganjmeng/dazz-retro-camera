# 复古相机 App 项目架构与工程方案

## 第一部分：项目总览与关键架构决策

### 1. 项目概述
本项目旨在开发一款双端移动 App，核心定位是“复古相机 / CCD 相机模拟器”。用户可以选择不同的虚拟相机（Preset），实时预览复古效果并进行拍摄或录像，拍完即得成片。项目采用 Flutter + 原生渲染插件的架构方案，确保跨平台开发效率与高性能图像处理的完美结合。

### 2. 关键架构决策解析

#### 2.1 为什么 Flutter 只负责 UI 和状态，不负责高性能渲染？
Flutter 的强项在于构建跨平台的高性能 UI 和复杂的业务逻辑。然而，在实时视频流处理和复杂的像素级滤镜渲染（如 CCD 效果所需的色差、噪点、高光溢出等）方面，Dart 语言和 Flutter 引擎的性能无法满足 60fps 的实时处理需求。将繁重的图像处理任务交由原生层执行，可以充分利用 GPU 硬件加速，保证渲染的低延迟和高帧率。

#### 2.2 为什么 iOS 选 Swift + Metal？
Swift 是目前 iOS 开发的主流语言，语法现代且安全。Metal 是 Apple 专为 iOS 和 macOS 设计的底层图形和计算 API，相比传统的 OpenGL ES，Metal 具有更低的 CPU 开销和更高的 GPU 利用率。使用 AVFoundation 进行相机采集，结合 Metal 进行实时滤镜渲染，是目前 iOS 平台上实现高性能相机应用的最佳实践。

#### 2.3 为什么 Android 首版选 CameraX + OpenGL ES？
CameraX 是 Google 推出的 Jetpack 相机库，极大地简化了 Android 设备碎片化带来的相机适配问题，提供了稳定且易用的 API。OpenGL ES 是目前 Android 平台上支持最广泛的图形 API，生态成熟，相关资料丰富，能够满足初版 CCD 滤镜的高性能渲染需求。Vulkan 虽然性能更高，但学习曲线陡峭且部分老旧机型支持不佳，因此作为后续的增强方向。

#### 2.4 桥接方案推荐：Texture
在 Flutter 与原生插件的相机预览桥接方案中，推荐使用 Texture。PlatformView（如 AndroidView 和 UiKitView）虽然可以直接嵌入原生视图，但会引入额外的视图层级和性能开销，尤其是在复杂的 UI 叠加场景下容易出现渲染问题。Texture 方案通过将原生层的渲染结果共享到 Flutter 的纹理缓存中，Flutter 只需要将其作为一个普通的 Widget 进行绘制，性能损耗极小，非常适合高帧率的相机预览。

#### 2.5 预览区域如何在 Flutter 中承载原生渲染输出？
原生层（Metal/OpenGL ES）将渲染好的每一帧图像数据写入到一个共享的纹理中。Flutter 侧通过 Texture Widget 绑定该纹理的 ID。当原生层更新纹理内容时，通知 Flutter 重新渲染 Texture Widget，从而实现实时的相机预览。

#### 2.6 Preset 配置管理：Dart Model 驱动，原生解析
Preset 配置建议采用 Dart Model 管理，JSON 序列化传递，原生层解析的方案。Dart 层负责业务逻辑和配置管理，方便后续的云端下发、A/B 测试和动态更新。当用户切换相机时，Flutter 将 Preset 配置序列化为 JSON 字符串，通过 MethodChannel 传递给原生层。原生层解析 JSON 后，动态加载对应的 Shader 和参数进行渲染。这种方式解耦了配置与渲染，提高了系统的灵活性。

#### 2.7 如何兼顾后续扩展新相机而不改动主渲染架构？
采用数据驱动的渲染管线设计。原生层构建一个通用的渲染管线，该管线支持多个渲染阶段。每个 Preset 对应一个 JSON 配置，配置中定义了所需的 Shader 组合、LUT 纹理、Overlay 纹理以及各项参数。新增相机时，只需在 Dart 层增加新的 Preset 配置和相关资源，无需修改原生层的底层代码，实现了真正的“配置即相机”。

---

## 第二部分：完整技术架构

### 1. 整体技术架构图

架构分为三层：UI 与业务层（Flutter）、桥接层（Platform Channels）、原生渲染与硬件层（iOS/Android）。

**UI 与业务层 (Flutter)**
主要负责页面路由与导航、状态管理（推荐使用 Riverpod）、业务逻辑（如相机选择、相册管理、设置、订阅等），以及作为 Preset 配置中心。

**桥接层 (Platform Channels)**
通过 MethodChannel 发送指令，如初始化、拍照、录像、切换 Preset 等。利用 EventChannel 接收原生回调，包括状态更新、错误抛出、进度通知等。同时，通过 Texture Registry 共享原生渲染的视频流纹理。

**原生渲染与硬件层**
在 iOS 侧，使用 Swift 结合 AVFoundation 进行相机采集，利用 Metal Performance Shaders (MPS) 或自定义 Metal Shader 进行渲染，并通过 AVAssetWriter 进行编码与导出。在 Android 侧，使用 Kotlin 结合 CameraX 进行采集，利用 OpenGL ES 3.0 (GLSL) 进行渲染，并通过 MediaCodec 与 MediaMuxer 进行编码与导出。

### 2. 职责边界划分

| 平台 | 核心职责 |
|---|---|
| **Flutter (Dart)** | 绘制 UI 元素、处理用户交互事件、管理应用状态（如选中相机、权限、相册）、管理 Preset 生命周期、处理业务逻辑。 |
| **原生插件 (Swift/Kotlin)** | 管理相机硬件、接收实时视频流、根据 Preset 参数执行 GPU 渲染、输出纹理供 Flutter 预览、处理拍照录像及文件保存。 |

### 3. 风险点与规避方案

| 风险点 | 描述 | 规避方案 |
|---|---|---|
| **性能瓶颈** | 复杂的 CCD 滤镜可能导致掉帧。 | 优化 Shader 算法；在预览阶段降低渲染分辨率或简化非核心效果；拍照/导出时使用全分辨率（预览与导出质量分离策略）。 |
| **设备碎片化** | Android 设备相机硬件和 OpenGL ES 实现存在差异。 | 严格使用 CameraX 屏蔽硬件差异；GLSL 编写遵循标准，避免特定厂商扩展指令；建立设备黑白名单机制。 |
| **内存泄漏** | 纹理和 GPU 资源管理不当极易引发 OOM。 | 在 Flutter 侧 dispose 时，确保原生侧彻底释放纹理、FBO 和 Shader Program；使用专业内存检测工具进行严格测试。 |
