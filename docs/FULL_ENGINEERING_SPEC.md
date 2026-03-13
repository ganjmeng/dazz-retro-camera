# DAZZ 复古相机 App — 完整工程化方案

> **版本**: v1.0.0 · **日期**: 2026-03-13 · **状态**: 可立项 · **技术栈**: Flutter + Swift/Metal + Kotlin/CameraX/OpenGL ES

---

## 目录

1. [产品定位与核心流程](#1-产品定位与核心流程)
2. [技术架构总览](#2-技术架构总览)
3. [工程目录结构](#3-工程目录结构)
4. [Flutter 层设计](#4-flutter-层设计)
5. [原生插件层设计](#5-原生插件层设计)
6. [Flutter ↔ Native 桥接 API](#6-flutter--native-桥接-api)
7. [Preset（虚拟相机）数据模型](#7-preset虚拟相机数据模型)
8. [渲染管线详解](#8-渲染管线详解)
9. [开发路线图](#9-开发路线图)
10. [风险清单](#10-风险清单)

---

## 1. 产品定位与核心流程

### 1.1 产品定位

本产品是一款**复古相机 / CCD 相机模拟器**，核心竞争力在于：

- **实时渲染**：用户在取景时即可看到完整的复古效果，所见即所得
- **相机即滤镜**：每个"虚拟相机"是一个完整的视觉风格包，而非普通后期滤镜
- **拍完即得**：拍照/录像结束后直接输出带效果的成片，无需二次处理

### 1.2 核心用户流程

```
进入 App
  └─ 相机选择页（横向滚动，分 Photo / Video 两类）
       └─ 选择虚拟相机（如 FQS、D Classic、VHS）
            └─ 实时预览页（全屏预览 + 效果实时叠加）
                 ├─ 调整参数（色温、曝光、焦距）
                 ├─ 拍照 → 成片预览 → 保存/分享
                 └─ 录像 → 成片预览 → 保存/分享
```

---

## 2. 技术架构总览

### 2.1 分层架构图

```
┌─────────────────────────────────────────────────────────────┐
│                    Flutter 应用层                            │
│  页面路由 │ 状态管理(Riverpod) │ 业务逻辑 │ Preset 配置调度   │
├─────────────────────────────────────────────────────────────┤
│               Flutter ↔ Native 桥接层                        │
│     MethodChannel (控制指令)  │  EventChannel (状态回调)     │
│     Texture Widget (渲染输出) │  FlutterTexture (纹理注册)   │
├──────────────────────────┬──────────────────────────────────┤
│     iOS 原生插件层        │      Android 原生插件层           │
│  Swift + AVFoundation    │   Kotlin + CameraX               │
│  Metal 渲染管线           │   OpenGL ES 渲染管线             │
│  AVAssetWriter 导出       │   MediaCodec/MediaMuxer 导出     │
├──────────────────────────┴──────────────────────────────────┤
│                    硬件层                                    │
│         Camera Sensor  │  GPU  │  File System               │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 核心设计原则

| 原则 | 说明 |
|------|------|
| **Dart 不做像素级处理** | 所有 YUV/BGRA 像素操作、GPU 着色器、编码压缩全部在原生层完成 |
| **Preset 驱动渲染** | Flutter 只传递 JSON 配置，原生层根据配置动态组装渲染管线 |
| **Texture Widget 零拷贝** | 原生渲染结果通过 `FlutterTexture` 注册，Flutter 用 `Texture(textureId)` 直接显示，无内存拷贝 |
| **双端 API 对称** | iOS 和 Android 实现相同的 MethodChannel 方法签名，Flutter 层无需区分平台 |

---

## 3. 工程目录结构

```
retro_cam_project/
├── flutter_app/                    # Flutter 主工程
│   ├── lib/
│   │   ├── main.dart               # 应用入口
│   │   ├── app.dart                # MaterialApp + 主题配置
│   │   ├── core/
│   │   │   ├── constants.dart      # Channel 名称、错误码、事件类型
│   │   │   └── theme.dart          # 全局暗色主题
│   │   ├── router/
│   │   │   └── app_router.dart     # GoRouter 路由配置
│   │   ├── models/
│   │   │   └── preset.dart         # Preset 数据模型（含 JSON 序列化）
│   │   ├── services/
│   │   │   ├── camera_service.dart # MethodChannel + EventChannel 封装
│   │   │   └── preset_repository.dart # Preset 加载与管理
│   │   └── features/
│   │       ├── camera/
│   │       │   ├── camera_screen.dart          # 主相机页
│   │       │   ├── camera_preview_widget.dart  # Texture Widget 封装
│   │       │   ├── camera_controls_widget.dart # 快门、翻转、闪光灯
│   │       │   └── preset_selector_widget.dart # 横向 Preset 选择器
│   │       ├── gallery/
│   │       │   └── gallery_screen.dart         # 作品列表页
│   │       ├── settings/
│   │       │   └── settings_screen.dart        # 设置页
│   │       └── subscription/
│   │           └── subscription_screen.dart    # 订阅/购买页
│   ├── assets/
│   │   ├── presets/                # 内置 Preset JSON 配置文件
│   │   │   ├── ccd_cool.json
│   │   │   ├── ccd_flash.json
│   │   │   └── ccd_night.json
│   │   └── images/                 # 相机图标等静态资源
│   └── pubspec.yaml
│
├── native_plugin/
│   ├── ios/
│   │   └── Classes/
│   │       ├── RetroCamPlugin.swift            # Flutter Plugin 入口，注册 Channel
│   │       ├── Managers/
│   │       │   └── CameraSessionManager.swift  # AVCaptureSession 生命周期管理
│   │       ├── Renderers/
│   │       │   └── MetalRenderer.swift         # Metal 渲染管线（待实现）
│   │       ├── Models/
│   │       │   └── Preset.swift                # Preset 数据模型
│   │       └── Shaders/
│   │           └── CameraShaders.metal         # CCD 效果 Metal 着色器
│   │
│   └── android/
│       └── src/main/kotlin/com/retrocam/app/
│           ├── RetroCamPlugin.kt               # Flutter Plugin 入口
│           ├── managers/
│           │   └── CameraManager.kt            # CameraX 生命周期管理
│           ├── renderers/
│           │   └── GLRenderer.kt               # OpenGL ES 渲染管线（待实现）
│           ├── models/
│           │   └── Preset.kt                   # Preset 数据模型
│           └── shaders/
│               └── fragment_ccd.glsl           # CCD 效果 GLSL 片段着色器
│
└── docs/
    ├── FULL_ENGINEERING_SPEC.md    # 本文档
    ├── architecture.md             # 架构设计详解
    ├── bridge-api.md               # 桥接 API 完整规范
    ├── preset-design.md            # Preset 模型与 JSON Schema
    └── roadmap.md                  # 开发路线图
```

---

## 4. Flutter 层设计

### 4.1 状态管理策略

采用 **Riverpod** 作为状态管理方案，核心 Provider 如下：

| Provider | 类型 | 职责 |
|----------|------|------|
| `cameraServiceProvider` | `StateNotifierProvider<CameraService, CameraState>` | 管理相机初始化、Preset 切换、拍照等所有相机操作 |
| `presetListProvider` | `FutureProvider<List<Preset>>` | 异步加载所有内置 Preset 配置 |
| `presetRepositoryProvider` | `Provider<PresetRepository>` | Preset 数据源，支持本地 JSON 和远程扩展 |

### 4.2 相机状态机

```
UNINITIALIZED
     │ initCamera()
     ▼
  LOADING
     │ textureId 返回
     ▼
   READY ◄──────────────────────────────────────┐
     │ setPreset(preset)                         │
     ▼                                           │
PRESET_APPLIED                                   │
     │ takePhoto() / startRecording()            │
     ▼                                           │
  CAPTURING / RECORDING                          │
     │ 完成                                      │
     ▼                                           │
 RESULT_READY ──────────────────────────────────►┘
```

### 4.3 页面路由

| 路径 | 页面 | 说明 |
|------|------|------|
| `/` | `CameraScreen` | 主相机页，应用启动后直接进入 |
| `/gallery` | `GalleryScreen` | 作品列表，支持查看、分享、删除 |
| `/settings` | `SettingsScreen` | 应用设置 |
| `/subscription` | `SubscriptionScreen` | 订阅/购买页 |

### 4.4 CameraScreen 布局结构

```
CameraScreen (Stack)
├── 黑色背景层
├── CameraPreviewWidget (Texture Widget, 4:3 居中)
│   └── Texture(textureId: xxx)  ← 原生渲染输出
├── 预览内叠加层 (Stack)
│   ├── 参数显示行 (色温 / 焦距 / 曝光)
│   └── 可选：网格线 / 小框模式
├── PresetSelectorWidget (底部横向列表)
└── CameraControlsWidget (快门行 + 功能按钮行)
```

---

## 5. 原生插件层设计

### 5.1 iOS 插件架构（Swift + Metal）

#### 渲染管线流程

```
AVCaptureSession
  └─ AVCaptureVideoDataOutput (kCVPixelFormatType_32BGRA)
       └─ captureOutput(_:didOutput:) 回调
            └─ CVPixelBuffer → MTLTexture (零拷贝)
                 └─ Metal Render Pass
                      ├─ vertexShader (全屏四边形)
                      └─ ccdFragmentShader
                           ├─ 色差 (Chromatic Aberration)
                           ├─ 色温/对比度/饱和度
                           ├─ 高光溢出 (Bloom/Halation)
                           ├─ 胶片颗粒 (Grain Texture)
                           ├─ 动态数字噪点
                           └─ 暗角 (Vignette)
                 └─ 渲染结果写入 FlutterTexture
                      └─ Flutter Texture Widget 显示
```

#### 拍照流程（高分辨率）

```
Flutter: takePhoto() ─► MethodChannel ─► iOS
iOS:
  1. AVCapturePhotoOutput.capturePhoto()
  2. photoOutput(_:didFinishProcessingPhoto:) 回调
  3. 获取 RAW/JPEG 数据
  4. 在 Metal 中以全分辨率重新渲染（应用相同 Preset 参数）
  5. 叠加日期水印（如果 dateStamp.enabled）
  6. 写入相册 / 沙盒
  7. 回调 filePath 给 Flutter
```

### 5.2 Android 插件架构（Kotlin + CameraX + OpenGL ES）

#### 渲染管线流程

```
CameraX Preview UseCase
  └─ SurfaceRequest → GLRenderer.getInputSurface()
       └─ SurfaceTexture (GL_TEXTURE_EXTERNAL_OES)
            └─ onFrameAvailable() 回调
                 └─ OpenGL ES Render Pass
                      ├─ vertex shader (全屏四边形)
                      └─ fragment_ccd.glsl
                           ├─ 色差 (Chromatic Aberration)
                           ├─ 色温/对比度/饱和度
                           ├─ 高光溢出 (Bloom)
                           ├─ 胶片颗粒 (Grain Texture)
                           ├─ 动态数字噪点
                           └─ 暗角 (Vignette)
                 └─ 渲染结果写入 FlutterTextureEntry
                      └─ Flutter Texture Widget 显示
```

---

## 6. Flutter ↔ Native 桥接 API

### 6.1 Channel 定义

| Channel | 类型 | 方向 | 用途 |
|---------|------|------|------|
| `com.retrocam.app/camera_control` | MethodChannel | Flutter → Native | 控制指令（初始化、拍照、切换等） |
| `com.retrocam.app/camera_events` | EventChannel | Native → Flutter | 状态回调（就绪、错误、录制状态等） |

### 6.2 MethodChannel 方法签名

#### `initCamera`

```json
// 请求参数
{
  "resolution": "1080p",   // "720p" | "1080p" | "4K"
  "lens": "back"           // "back" | "front"
}

// 返回值
{
  "textureId": 1,          // Flutter Texture ID，必须 > 0
  "width": 1080,
  "height": 1440
}
```

#### `setPreset`

```json
// 请求参数（完整 Preset JSON，见第 7 节）
{
  "preset": { ... }
}

// 返回值
{
  "success": true
}
```

#### `takePhoto`

```json
// 请求参数
{
  "flashMode": "auto"   // "auto" | "on" | "off"
}

// 返回值
{
  "filePath": "/path/to/photo.jpg",
  "width": 3024,
  "height": 4032
}
```

#### `switchLens`

```json
// 请求参数
{
  "lens": "front"   // "back" | "front"
}

// 返回值
{
  "success": true
}
```

#### `startRecording` / `stopRecording`

```json
// startRecording 请求参数
{
  "outputPath": "/path/to/video.mp4",
  "fps": 30,
  "bitrate": 8000000
}

// stopRecording 返回值
{
  "filePath": "/path/to/video.mp4",
  "duration": 5234   // 毫秒
}
```

### 6.3 EventChannel 事件格式

所有事件统一格式：

```json
{
  "type": "onCameraReady",
  "payload": { ... }
}
```

| 事件类型 | Payload | 说明 |
|----------|---------|------|
| `onCameraReady` | `{}` | 相机初始化完成 |
| `onPermissionDenied` | `{ "permission": "camera" }` | 权限被拒绝 |
| `onPhotoCaptured` | `{ "filePath": "..." }` | 拍照完成 |
| `onVideoRecorded` | `{ "filePath": "...", "duration": 5234 }` | 录像完成 |
| `onRecordingStateChanged` | `{ "isRecording": true }` | 录制状态变化 |
| `onError` | `{ "code": 1001, "message": "..." }` | 错误事件 |

---

## 7. Preset（虚拟相机）数据模型

### 7.1 JSON Schema

```json
{
  "id": "ccd_cool_01",
  "name": "CCD Cool",
  "category": "CCD",
  "supportsPhoto": true,
  "supportsVideo": true,
  "isPremium": false,
  "resources": {
    "lutName": "lut_ccd_cool.png",
    "grainTextureName": "grain_fine.png",
    "leakTextureNames": [],
    "frameOverlayName": null
  },
  "params": {
    "exposureBias": 0.2,
    "contrast": 1.15,
    "saturation": 0.85,
    "temperatureShift": -400.0,
    "tintShift": 8.0,
    "sharpen": 0.4,
    "blurRadius": 1.2,
    "grainAmount": 0.25,
    "noiseAmount": 0.15,
    "vignetteAmount": 0.4,
    "chromaticAberration": 0.018,
    "bloomAmount": 0.3,
    "halationAmount": 0.1,
    "jpegArtifacts": 0.05,
    "scanlineAmount": 0.0,
    "dateStamp": {
      "enabled": true,
      "format": "yyyy MM dd",
      "color": "#FFFFA500",
      "position": "bottomRight"
    }
  }
}
```

### 7.2 参数说明

| 参数 | 范围 | 说明 |
|------|------|------|
| `exposureBias` | -3.0 ~ +3.0 EV | 曝光补偿 |
| `contrast` | 0.5 ~ 2.0 | 对比度倍率，1.0 为原始 |
| `saturation` | 0.0 ~ 2.0 | 饱和度，0.0 为黑白 |
| `temperatureShift` | -2000 ~ +2000 K | 色温偏移，负数偏冷蓝，正数偏暖黄 |
| `tintShift` | -100 ~ +100 | 色调偏移，负数偏绿，正数偏洋红 |
| `grainAmount` | 0.0 ~ 1.0 | 胶片颗粒强度 |
| `noiseAmount` | 0.0 ~ 1.0 | CCD 数字噪点强度（动态） |
| `vignetteAmount` | 0.0 ~ 1.0 | 暗角强度 |
| `chromaticAberration` | 0.0 ~ 0.05 | 色差偏移量（UV 坐标单位） |
| `bloomAmount` | 0.0 ~ 1.0 | 高光溢出强度 |
| `halationAmount` | 0.0 ~ 1.0 | 胶片光晕强度 |
| `jpegArtifacts` | 0.0 ~ 1.0 | JPEG 压缩块状失真模拟 |
| `scanlineAmount` | 0.0 ~ 1.0 | 扫描线强度（VHS/CRT 专用） |

### 7.3 内置 Preset 列表（MVP 阶段）

| ID | 名称 | 分类 | 特色 | 是否付费 |
|----|------|------|------|----------|
| `ccd_cool_01` | CCD Cool | CCD | 冷色调，蓝移，细颗粒 | 免费 |
| `ccd_flash_01` | CCD Flash | CCD | 暖色调，高光溢出，闪光感 | 免费 |
| `ccd_night_01` | CCD Night | CCD | 暗部噪点，高对比，夜景专用 | 付费 |
| `film_kodak_01` | Kodak 400 | Film | 暖黄，低饱和，胶片颗粒 | 付费 |
| `film_fuji_01` | Fuji 400H | Film | 冷绿，高细节，日系风格 | 付费 |
| `disposable_01` | Disposable | Disposable | 低清晰度，色差明显，廉价感 | 免费 |
| `vhs_01` | VHS | Video | 扫描线，色彩偏移，模糊 | 免费 |
| `8mm_01` | 8mm Film | Video | 颗粒感强，暖色，老电影风 | 付费 |

---

## 8. 渲染管线详解

### 8.1 CCD 效果实现原理

CCD 相机的视觉特征来自其传感器和光学系统的物理局限性，本方案通过以下 GPU 着色器 Pass 逐一模拟：

**Pass 1 — 色差（Chromatic Aberration）**

CCD 镜头的色差表现为 RGB 三通道在边缘产生位移。实现方式：对 R 通道采样 `uv + (ca, 0)`，G 通道采样 `uv`，B 通道采样 `uv - (ca, 0)`，三通道重新合并。

**Pass 2 — 色彩调整（Color Grading）**

按顺序执行：色温偏移（RGB 通道加权偏移）→ 对比度（线性拉伸）→ 饱和度（与灰度插值）。

**Pass 3 — 高光溢出（Bloom / Halation）**

当像素亮度超过阈值（0.8）时，向 RGB 通道叠加暖色光晕，模拟 CCD 传感器在强光下的溢出效应。

**Pass 4 — 胶片颗粒（Grain）**

从预烘焙的高斯噪点纹理中采样，以加法混合叠加到画面，强度由 `grainAmount` 控制。

**Pass 5 — 动态数字噪点（Noise）**

使用 `sin(dot(uv, seed))` 伪随机函数生成每帧不同的噪点，在暗部区域（`1.0 - luminance`）增强，模拟 CCD 暗电流噪声。

**Pass 6 — 暗角（Vignette）**

计算像素到画面中心的距离，以二次函数衰减边缘亮度，模拟镜头口径渐晕。

### 8.2 LUT 色彩重映射

对于需要精确色彩还原的 Preset（如 Kodak、Fuji 胶片模拟），使用预计算的 **64×64×64 3D LUT**（展开为 512×512 的 2D PNG）进行色彩重映射。LUT 采样在 Pass 2 之后执行，将基础色彩调整后的结果映射到目标色彩空间。

### 8.3 性能指标目标

| 指标 | iOS 目标 | Android 目标 |
|------|----------|--------------|
| 实时预览帧率 | ≥ 60 fps | ≥ 30 fps |
| 预览延迟 | < 50ms | < 80ms |
| 拍照处理时间 | < 500ms | < 800ms |
| 内存占用 | < 150MB | < 200MB |
| GPU 占用率 | < 40% | < 50% |

---

## 9. 开发路线图

### Phase 0 — 工程初始化（第 1 周）

- [ ] 创建 Flutter 工程，配置 `pubspec.yaml`，集成 Riverpod、GoRouter
- [ ] 创建 iOS Plugin 工程，配置 `Podspec`，申请相机/麦克风权限
- [ ] 创建 Android Plugin 工程，配置 `build.gradle`，集成 CameraX 依赖
- [ ] 建立 MethodChannel 通信骨架，验证 Flutter ↔ Native 双向通信
- [ ] 搭建 CI/CD 基础（GitHub Actions，自动构建 iOS/Android）

### Phase 1 — 相机基础功能（第 2-3 周）

- [ ] iOS: AVCaptureSession 初始化，输出 CVPixelBuffer
- [ ] iOS: Metal 渲染管线搭建，将 CVPixelBuffer 渲染到 FlutterTexture
- [ ] Android: CameraX 初始化，SurfaceTexture 绑定
- [ ] Android: OpenGL ES 渲染管线搭建，渲染到 FlutterTextureEntry
- [ ] Flutter: Texture Widget 接入，验证双端实时预览
- [ ] 双端: 实现 `switchLens`（前后置切换）

### Phase 2 — Preset 系统与滤镜渲染（第 4-6 周）

- [ ] 实现 Preset JSON 加载与解析（Flutter 层）
- [ ] iOS Metal Shader: 实现 6 个 CCD 效果 Pass
- [ ] Android GLSL Shader: 实现对应的 6 个效果 Pass
- [ ] 实现 `setPreset` Channel 方法，动态更新 Shader Uniform
- [ ] 制作 3 套内置 Preset（CCD Cool、CCD Flash、CCD Night）
- [ ] Flutter: 实现 PresetSelectorWidget 横向滚动选择器

### Phase 3 — 拍照与录像（第 7-9 周）

- [ ] iOS: AVCapturePhotoOutput 高分辨率拍照，Metal 全分辨率渲染
- [ ] iOS: AVAssetWriter 视频录制，实时写入带效果的帧
- [ ] Android: ImageCapture UseCase 拍照，OpenGL ES 全分辨率渲染
- [ ] Android: MediaCodec + MediaMuxer 视频录制
- [ ] 双端: 日期水印叠加（dateStamp）
- [ ] Flutter: 拍照成片预览页，保存/分享功能

### Phase 4 — 相册与作品管理（第 10 周）

- [ ] Flutter: GalleryScreen 实现，接入 `photo_manager`
- [ ] 支持查看、删除、分享作品
- [ ] 成片详情页，显示使用的 Preset 名称

### Phase 5 — 商业化与打磨（第 11-12 周）

- [ ] 订阅/购买页（iOS IAP + Android Billing）
- [ ] Preset 付费锁定逻辑
- [ ] 性能优化（帧率、内存、启动速度）
- [ ] 用户体验打磨（动画、触感反馈）
- [ ] TestFlight / Google Play 内测发布

---

## 10. 风险清单

| 风险 | 等级 | 缓解措施 |
|------|------|----------|
| Android 机型碎片化导致 OpenGL ES 兼容性问题 | 高 | 建立设备测试矩阵（覆盖高中低端机型），降级到 OpenGL ES 2.0 兼容模式 |
| iOS Metal 渲染与 AVCaptureSession 线程竞争 | 中 | 使用独立的 `sessionQueue` 和 `renderQueue`，严格隔离线程 |
| 高分辨率拍照时内存峰值过高 | 中 | 使用 Metal Heaps 或 OpenGL PBO 异步读取，避免 CPU/GPU 同步等待 |
| Flutter Texture Widget 在部分 Android 设备上闪烁 | 中 | 使用 `SurfaceView` 替代方案，或升级 Flutter Engine 版本 |
| 视频录制时 GPU 占用过高导致帧率下降 | 中 | 降低录制分辨率至 1080p，或使用硬件编码器（VideoToolbox/MediaCodec） |
| Preset 参数调整实时生效的性能开销 | 低 | Uniform 更新为轻量操作，无需重建管线，可每帧更新 |

---

*本文档由工程化方案生成工具自动生成，可作为正式立项文档使用。*
