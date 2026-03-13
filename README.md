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
│   │   └── presets/                # Camera definition JSON files
│   └── pubspec.yaml
│
├── native_plugin/                  # Flutter plugin (iOS + Android)
│   ├── lib/                        # Dart plugin interface
│   ├── ios/
│   │   ├── Classes/
│   │   │   ├── RetroCamPlugin.swift
│   │   │   ├── Managers/CameraSessionManager.swift
│   │   │   ├── Models/CameraDefinition.swift
│   │   │   └── Shaders/CameraShaders.metal
│   │   └── retro_cam_plugin.podspec
│   ├── android/
│   │   ├── src/main/kotlin/com/retrocam/app/
│   │   │   ├── RetroCamPlugin.kt
│   │   │   ├── managers/CameraManager.kt
│   │   │   ├── models/CameraDefinition.kt
│   │   │   └── shaders/fragment_ccd.glsl
│   │   └── build.gradle
│   └── pubspec.yaml
│
└── docs/                           # Engineering documentation
    ├── FULL_ENGINEERING_SPEC.md
    ├── v3_camera_system_architecture.md
    ├── v3_camera_definitions.md
    ├── v3_tri_platform_models_and_api.md
    ├── v2_gpu_rendering_pipeline.md
    ├── bridge-api.md
    └── roadmap.md
```

---

## Camera System Design

Each camera is a **self-contained JSON entity** (`CameraDefinition`). All options (films, lenses, papers, ratios, watermarks) are **private to that camera** and never shared across cameras.

```json
{
  "id": "ccd_2005",
  "name": "CCD-2005",
  "category": "digital_ccd",
  "outputType": "photo",
  "baseModel": {
    "sensor": { "type": "ccd", "dynamic_range": 7.0, "noise": 0.32 },
    "color": { "contrast": 1.1, "saturation": 1.1 }
  },
  "optionGroups": {
    "films": [
      { "id": "ccd_default", "name": "Standard CCD", "isDefault": true,
        "rendering": { "lut": "ccd_standard.cube", "grain": 0.25 } }
    ],
    "ratios": [{ "id": "ratio_4_3", "value": "4:3", "isDefault": true }],
    "watermarks": [{ "id": "ccd_date", "type": "digital_date", "position": "bottom_right", "isDefault": true }]
  },
  "uiCapabilities": {
    "showFilmSelector": true, "showLensSelector": false,
    "showPaperSelector": false, "showRatioSelector": true, "showWatermarkSelector": true
  }
}
```

The `uiCapabilities` field drives the Flutter UI dynamically — selectors are only shown when the camera supports them.

---

## GPU Rendering Pipeline

```
Camera Frame (YUV to RGB)
  |
  v
PASS 1: Sensor & Base Color   <- baseModel (sensor noise, base LUT, white balance)
  |
  v
PASS 2: Film Simulation       <- active FilmOption (film LUT, grain)
  |
  v
PASS 3: Lens Optics           <- active LensOption (vignette, distortion, chromatic aberration)
  |
  v
PASS 4: Bloom & Halation      <- active LensOption (highlight bloom, separate downsample pass)
  |
  v
PASS 5: Scan Artifacts        <- special cameras (VHS scanlines, DV noise)
  |
  v
PASS 6: Paper & Frame         <- active PaperOption (instant border texture, ratio crop)
  |
  v
PASS 7: Watermark             <- active WatermarkOption (date stamp, REC overlay, logo)
  |
  v
FlutterTexture (preview 60fps) / JPEG export (full resolution)
```

> Paper and frame effects are rendered **directly into the exported photo** at the moment of capture — no post-processing step is required after shooting.

---

## Included Cameras (10 Production Presets)

| # | ID | Name | Category | Films | Lenses | Papers |
|---|---|---|---|---|---|---|
| 1 | `ccd_2005` | CCD-2005 | digital_ccd | 2 | — | — |
| 2 | `film_gold200` | Gold 200 | film | 2 | — | — |
| 3 | `fuji_superia` | Superia | film | 2 | — | — |
| 4 | `disposable_flash` | Disposable Flash | disposable | 1 | — | — |
| 5 | `polaroid_classic` | Polaroid Classic | instant | 1 | 2 | 2 |
| 6 | `ccd_night` | Night CCD | digital_ccd | 1 | — | — |
| 7 | `vhs_cam` | VHS Camcorder | video | — | — | — |
| 8 | `dv2003` | DV-2003 | video | — | — | — |
| 9 | `portrait_soft` | Soft Portrait | film | 1 | 1 | — |
| 10 | `film_scan` | Film Scan | scanner | 2 | — | — |

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

## Documentation

| Document | Description |
|---|---|
| [`docs/FULL_ENGINEERING_SPEC.md`](docs/FULL_ENGINEERING_SPEC.md) | Complete engineering specification (10 chapters) |
| [`docs/v3_camera_system_architecture.md`](docs/v3_camera_system_architecture.md) | V3 JSON Schema and design principles |
| [`docs/v3_camera_definitions.md`](docs/v3_camera_definitions.md) | 10 production camera preset definitions |
| [`docs/v3_tri_platform_models_and_api.md`](docs/v3_tri_platform_models_and_api.md) | Dart / Swift / Kotlin models + Bridge API |
| [`docs/v2_gpu_rendering_pipeline.md`](docs/v2_gpu_rendering_pipeline.md) | GPU rendering pipeline design |
| [`docs/bridge-api.md`](docs/bridge-api.md) | MethodChannel / EventChannel API reference |
| [`docs/roadmap.md`](docs/roadmap.md) | Development roadmap (Phase 0-3) |

---

## License

MIT License — see [LICENSE](LICENSE) for details.
