# Platform Compatibility Notes: iOS 26 & Android 16

## iOS 26 Key Changes for Camera Apps

### AVFoundation & Camera
- **Capture Controls**: iOS 26 introduces new `CaptureControls` API allowing programmatic mapping of physical buttons (volume up/down) to camera actions
- **AVCaptureMetadataOutput .face**: No longer triggers callbacks in iOS 26 Beta — avoid relying on face detection metadata
- **Metal 4**: New GPU/ML graphics optimizations; Metal Performance Shaders integrated with Core ML
- **Spatial Photo Support**: Devices with depth hardware (iPhone 12+) can capture 3D spatial photos
- **Lens Cleaning Hints**: New image analysis API detects smudges — can be ignored for our use case
- **Minimum Deployment Target**: iOS 26 requires iPhone 11+ (drops XS, XS Max, XR)
- **App Store Requirement**: All submissions must use Xcode 26 + iOS 26 SDK from April 2026

### Privacy & Permissions (iOS 26)
- Camera and microphone permissions remain via `NSCameraUsageDescription` / `NSMicrophoneUsageDescription`
- No breaking changes to existing permission model for camera apps
- Privacy & Security settings path unchanged

### Swift & Xcode
- Swift 6 strict concurrency — use `@MainActor` for UI, `actor` for camera session management
- Xcode 26 build caching: ~30-40% faster build times
- `elegantTextHeight` deprecated — use standard font APIs

### Required Info.plist Keys (iOS 26)
```xml
<key>NSCameraUsageDescription</key>
<string>DAZZ uses the camera to capture retro-style photos and videos.</string>
<key>NSMicrophoneUsageDescription</key>
<string>DAZZ uses the microphone to record video with audio.</string>
<key>NSPhotoLibraryAddUsageDescription</key>
<string>DAZZ saves your retro photos and videos to your photo library.</string>
```

---

## Android 16 (API 36) Key Changes for Camera Apps

### Mandatory Changes (Breaking)
1. **Edge-to-Edge Enforced**: `R.attr#windowOptOutEdgeToEdgeEnforcement` is DISABLED for apps targeting API 36. Apps MUST support edge-to-edge layout. Use `WindowCompat.setDecorFitsSystemWindows(window, false)` and handle insets.
2. **MediaStore Version Lockdown**: `MediaStore#getVersion()` is now unique per app — do not rely on its format for fingerprinting.
3. **Predictive Back**: Must migrate or opt-out. Use `android:enableOnBackInvokedCallback="true"` in manifest.
4. **Adaptive Layouts**: `screenOrientation="portrait"` locks are IGNORED on large screens. Camera app must handle orientation gracefully.
5. **Fixed Rate Work Scheduling**: `scheduleAtFixedRate` behavior changed — use `WorkManager` instead.

### Camera-Specific New Features (Android 16)
- **Precise Color Temperature & Tint**: New Camera2 API for fine color control (useful for future white balance feature)
- **Hybrid Auto-Exposure**: New Camera2 hybrid AE modes — manual + auto hybrid
- **Camera Night Mode Scene Detection**: `EXTENSION_NIGHT_MODE_INDICATOR` in Camera2
- **UltraHDR in HEIC format**: New image format support
- **Motion Photo Capture Intents**: `ACTION_MOTION_PHOTO_CAPTURE` standard intent

### Graphics (Android 16)
- **Vulkan is now the official graphics API** — OpenGL ES is still supported but no longer under active feature development
- **AGSL Custom Graphical Effects**: `RuntimeColorFilter`, `RuntimeXfermode` for custom shader effects
- **16 KB Page Size Compatibility Mode**: Native libraries must be compiled with 16KB page alignment

### Security (Android 16)
- **Safer Intents**: Opt-in strict intent resolution via `android:intentMatchingFlags="enforceIntentFilter"`
- **GPU Syscall Filtering**: New security layer for GPU operations
- **Local Network Permission**: New permission required for local network access

### Required Manifest Changes (Android 16 / API 36)
```xml
<!-- AndroidManifest.xml -->
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />

<application
    android:enableOnBackInvokedCallback="true"
    ...>
    <activity
        android:screenOrientation="unspecified"  <!-- Do NOT use "portrait" for API 36 -->
        ...>
```

### build.gradle (Android 16 Target)
```kotlin
android {
    compileSdk = 36
    defaultConfig {
        minSdk = 26          // Android 8.0 — CameraX minimum
        targetSdk = 36       // Android 16
    }
}
```

### CameraX Version for Android 16
- Use CameraX `1.4.x` or later (supports API 36)
- `camera-camera2: 1.4.1`
- `camera-lifecycle: 1.4.1`
- `camera-video: 1.4.1`
- `camera-view: 1.4.1`

---

## Flutter Plugin Compatibility

### pubspec.yaml minimum versions
```yaml
environment:
  sdk: ">=3.3.0 <4.0.0"
  flutter: ">=3.19.0"

dependencies:
  flutter:
    sdk: flutter
  riverpod: ^2.5.1
  go_router: ^13.2.0
  permission_handler: ^11.3.1
  image_gallery_saver: ^2.0.3
```

### iOS Deployment Target
```
IPHONEOS_DEPLOYMENT_TARGET = 17.0  # Minimum for Metal 3 features; iOS 26 compatible
```

### Android NDK Page Size (16 KB)
Add to `CMakeLists.txt` or `build.gradle`:
```
android.defaultConfig.externalNativeBuild.cmake.arguments += "-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON"
```
