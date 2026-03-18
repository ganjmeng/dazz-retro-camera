# DAZZ Retro Camera

> A production-grade retro / CCD camera simulator app for iOS and Android, built with Flutter + Swift/Metal + Kotlin/OpenGL ES.

---

## Product Overview

DAZZ Retro Camera is a **real-time retro camera simulator** — not a post-processing filter app. Users select a virtual camera, see the retro effect live in the viewfinder, shoot, and get the final image instantly. The experience mirrors the feel of shooting with a real CCD camera, film camera, instant camera, or VHS camcorder.

### User Flow

```
Launch App → Select Camera → Real-time Preview with Effect → Shoot / Record → Instant Result → Save / Share
```

---

## Technology Stack

| Layer | Technology | Responsibility |
|---|---|---|
| **UI / State / Routing** | Flutter 3.x + Dart | All screens, navigation, state management (Riverpod), business logic |
| **iOS Native** | Swift 5.9 + AVFoundation + Metal | Camera capture, real-time GPU filter rendering, photo/video export |
| **Android Native** | Kotlin + CameraX + OpenGL ES 3.0 | Camera capture, real-time GPU filter rendering, photo/video export |
| **Plugin Bridge** | Flutter MethodChannel + EventChannel | Dart to Native communication |

> **Constraint**: Dart/Flutter does **not** perform any pixel-level processing. All GPU rendering lives in the native plugin layer.

---

## Repository Structure

```
dazz-retro-camera/
├── flutter_app/                    # Flutter application
│   ├── lib/
│   │   ├── main.dart
│   │   ├── app.dart
│   │   ├── core/                   # Theme, constants
│   │   ├── router/                 # GoRouter configuration
│   │   ├── models/                 # CameraDefinition, OptionItem, etc.
│   │   ├── services/               # CameraService (MethodChannel wrapper)
│   │   └── features/
│   │       ├── camera/             # Camera screen, preview, controls, selector
│   │       ├── gallery/            # Gallery screen
│   │       ├── settings/           # Settings screen
│   │       └── subscription/       # Subscription / paywall screen
│   ├── assets/
│   │   └── cameras/                # Camera definition JSON files
│   └── pubspec.yaml
│
├── docs/                           # Engineering documentation
│   ├── FULL_ENGINEERING_SPEC.md
│   ├── v3_camera_system_architecture.md
│   ├── v3_camera_definitions.md
│   ├── v3_tri_platform_models_and_api.md
│   ├── v2_gpu_rendering_pipeline.md
│   ├── bridge-api.md
│   └── roadmap.md
```

---

## Camera System Design

Each camera is a **self-contained JSON entity** (`CameraDefinition`). All options (filters, lenses, frames, ratios, watermarks) are **private to that camera** and never shared across cameras.

```json
{
  "id": "ccd_r",
  "name": "CCD R",
  "category": "ccd",
  "outputType": "photo",
  "baseModel": {
    "sensor": { "type": "ccd", "dynamic_range": 7.0, "noise": 0.32 },
    "color": { "contrast": 1.1, "saturation": 1.1 }
  },
  "modules": {
    "filters": [],
    "lenses": [
      { "id": "std", "name": "Standard", "isDefault": true }
    ],
    "ratios": [{ "id": "ratio_4_3", "value": "4:3", "isDefault": true }],
    "frames": [{ "id": "instant_default", "name": "Default", "isDefault": false }]
  },
  "uiCapabilities": {
    "showFilterSelector": false, "showLensSelector": true,
    "showFrameSelector": true, "showRatioSelector": true
  }
}
```

The `uiCapabilities` field drives the Flutter UI dynamically — selectors are only shown when the camera supports them.

---

## GPU Rendering Pipeline

The rendering pipeline is implemented natively on both iOS (Metal) and Android (OpenGL ES 3.0) to ensure maximum performance. The pipeline consists of 19 distinct passes:

1. **Chromatic Aberration** (色差)
2. **Temperature & Tint** (色温 + Tint)
3. **Blacks & Whites** (黑场/白场)
4. **Highlights & Shadows** (高光/阴影压缩)
5. **Contrast** (对比度)
6. **Clarity** (中间调微对比度)
7. **Saturation & Vibrance** (饱和度 + Vibrance)
8. **Color Bias** (RGB 通道偏移)
9. **Bloom** (高光光晕)
10. **Halation** (高光辉光)
11. **Highlight Rolloff** (高光柔和滚落)
12. **Center Gain** (中心增亮)
13. **Skin Protection** (肤色保护)
14. **Edge Falloff & Corner Warm Shift** (边缘衰减 + 角落暖色偏移)
15. **Chemical Irregularity** (化学不规则感)
16. **Paper Texture** (相纸纹理)
17. **Film Grain** (胶片颗粒)
18. **Digital Noise** (数字噪点)
19. **Vignette** (暗角)

> Paper and frame effects are rendered **directly into the exported photo** at the moment of capture — no post-processing step is required after shooting.

---

## Included Cameras (11 Production Presets)

| ID | Name | Category | Filters | Lenses | Frames | Ratios |
|---|---|---|---|---|---|---|
| `bw_classic` | 黑白经典 | film | 2 | 5 | 0 | 3 |
| `ccd_r` | CCD R | ccd | 0 | 5 | 6 | 4 |
| `cpm35` | CPM35 | film | 3 | 3 | 6 | 3 |
| `d_classic` | D Classic | digital | 0 | 4 | 6 | 4 |
| `fisheye` | FISHEYE | creative | 0 | 3 | 0 | 1 |
| `fqs` | FQS | film | 2 | 4 | 6 | 3 |
| `fxn_r` | FXN-R | film | 3 | 4 | 6 | 3 |
| `grd_r` | GRD R | digital | 0 | 4 | 0 | 4 |
| `inst_c` | INST C | instant | 0 | 3 | 6 | 2 |
| `inst_sqc` | INST SQC | instant | 0 | 3 | 6 | 2 |
| `u300` | U300 | film | 3 | 3 | 6 | 3 |

---

## Getting Started

### Prerequisites

- Flutter SDK 3.19+
- Xcode 15+ (iOS development, Metal debugging)
- Android Studio (Android development, OpenGL ES debugging)
- Physical device recommended for camera and GPU testing

### Run

```bash
cd flutter_app
flutter pub get
flutter run -d <device_id>
```

---

## CI/CD & Release

The project uses GitHub Actions for continuous integration and deployment:

- **Flutter CI**: Runs tests and lints on every push to `main`.
- **Android/iOS Build Check**: Verifies debug builds on every push.
- **Release Workflows**: Triggered automatically when a tag matching `v*.*.*` is pushed. Builds release APK/AAB and creates a GitHub Release draft.

---

## Documentation

| Document | Description |
|---|---|
| [`docs/FULL_ENGINEERING_SPEC.md`](docs/FULL_ENGINEERING_SPEC.md) | Complete engineering specification (10 chapters) |
| [`docs/v3_camera_system_architecture.md`](docs/v3_camera_system_architecture.md) | V3 JSON Schema and design principles |
| [`docs/v3_camera_definitions.md`](docs/v3_camera_definitions.md) | Production camera preset definitions |
| [`docs/v3_tri_platform_models_and_api.md`](docs/v3_tri_platform_models_and_api.md) | Dart / Swift / Kotlin models + Bridge API |
| [`docs/v2_gpu_rendering_pipeline.md`](docs/v2_gpu_rendering_pipeline.md) | GPU rendering pipeline design |
| [`docs/bridge-api.md`](docs/bridge-api.md) | MethodChannel / EventChannel API reference |
| [`docs/roadmap.md`](docs/roadmap.md) | Development roadmap |

---

## License

MIT License — see [LICENSE](LICENSE) for details.
