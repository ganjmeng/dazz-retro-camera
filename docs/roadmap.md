# Retro Cam 项目 MVP 路线图与阶段拆分

为了保证项目顺利推进，降低技术风险，我们将开发计划拆分为四个阶段（Phase 0 到 Phase 3）。每个阶段都有明确的交付目标和可验证的结果。

## Phase 0：技术验证 (Tech Spike)

本阶段的核心目标是打通 Flutter 与双端原生渲染插件的核心链路，验证架构的可行性。

在这一阶段，我们需要首先搭建 Flutter 主工程骨架与双端插件目录结构。随后，在 iOS 侧使用 AVFoundation 结合 Metal 实现基础相机预览，并输出到 Flutter Texture；在 Android 侧则使用 CameraX 结合 OpenGL ES 实现类似功能。同时，我们需要实现基于 `MethodChannel` 的基础通信，例如 `initCamera` 和 `startPreview` 指令。最后，实现一个硬编码的简单 CCD 效果（如基础的冷色 LUT 和高斯模糊）并在预览中成功跑通。

此阶段的最终交付物是一个可以运行的 Demo，能够在 Flutter 界面中看到带有基础滤镜的实时相机预览。

## Phase 1：最小可运行版本 (MVP Core)

本阶段旨在完成基础的拍照和相册闭环，使应用具备基础产品形态。

我们需要完善 Flutter UI，包括首页以及包含快门、翻转、闪光灯等功能的相机控制区。同时，实现 Preset 模型解析，完成 Flutter 向原生层传递 Preset JSON 并动态切换效果的功能。在核心链路方面，必须实现高分辨率的拍照功能：iOS 端捕获 `CMSampleBuffer` 送入 Metal 渲染并保存，Android 端捕获 `ImageProxy` 送入 OpenGL 渲染并保存。此外，还需要实现基础的 Gallery 页面以读取和展示本地相册结果，并完成基础设置页面的开发。

此阶段的交付物为内部测试版 v0.1，该版本支持切换 2-3 个基础 Preset，并能够成功拍照保存至相册。

## Phase 2：体验优化 (Experience Polish)

本阶段的重点是提升 CCD 滤镜质感，优化系统性能，并严格对齐双端的视觉效果。

在图像处理方面，我们需要深化 CCD Shader 算法，加入噪点（Grain/Noise）、高光溢出（Bloom）、色差（Chromatic Aberration）和暗角等高级效果。同时，实现复古日期时间戳功能，由原生层在最终渲染图上叠加文字纹理。在性能方面，建立预览质量与导出质量分离策略（例如预览使用 720p，导出使用 4K）以保证流畅度。此外，还需要处理各种异常情况（如相机被占用、后台切前台等），并严格对齐 iOS 和 Android 的渲染参数，确保同一 Preset 在双端的视觉表现一致。

此阶段的交付物为内部测试版 v0.5，具备高质量的 CCD 效果和稳定的性能，准备进行小范围灰度测试。

## Phase 3：商业化与预留扩展 (Commercial & Future-proofing)

本阶段的目标是为应用的正式上线和后续迭代做准备。

我们需要初步实现视频录制链路，使用 `AVAssetWriter` 和 `MediaCodec` 对渲染后的纹理进行编码。在 UI 层面，加入订阅引导页（Paywall）占位，并为 Premium Preset 增加锁定状态的视觉提示。同时，在关键用户路径（如点击快门、切换 Preset 等）预留埋点接口。最后，完善资源管理模块，支持从网络下载新的 LUT 和 Texture 资源到本地沙盒供原生加载使用。

此阶段的交付物为 1.0 Release Candidate 版本，具备核心功能和商业化占位，可提交应用商店审核。
