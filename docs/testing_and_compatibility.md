# DAZZ Retro Camera - Testing & Platform Compatibility Plan

## 1. Platform Compatibility Checklist

### iOS 26 Compatibility (Target SDK 17.0+)
- [x] **Camera Permissions**: Verify `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` in Info.plist
- [x] **Photo Library Permissions**: Verify `NSPhotoLibraryUsageDescription` and `NSPhotoLibraryAddUsageDescription` in Info.plist
- [x] **AVFoundation Capture**: Ensure `AVCaptureSession` uses `actor` or `@MainActor` for thread safety (Swift 6 strict concurrency)
- [x] **Metal 4 Support**: Verify `MetalRenderer` properly registers texture with `FlutterTextureRegistry`
- [ ] **Capture Controls (iOS 26 API)**: Map physical volume buttons to capture actions (Planned for Phase 2)

### Android 16 (API 36) Compatibility
- [x] **Edge-to-Edge Layout**: Ensure Flutter UI supports edge-to-edge rendering without relying on `R.attr#windowOptOutEdgeToEdgeEnforcement`
- [x] **Predictive Back**: Ensure `android:enableOnBackInvokedCallback="true"` is set in AndroidManifest.xml
- [x] **Safer Intents**: Ensure `android:intentMatchingFlags="enforceIntentFilter"` is set in AndroidManifest.xml
- [x] **Permissions**: Verify `CAMERA`, `RECORD_AUDIO`, `READ_MEDIA_IMAGES`, and `READ_MEDIA_VIDEO` are declared
- [x] **CameraX 1.4.1+**: Ensure build.gradle uses CameraX version that supports Android 16
- [x] **OpenGL ES / Vulkan**: Verify `GLRenderer` properly manages `SurfaceTexture` lifecycle

## 2. Unit Testing Plan (Flutter)

### State Management (`CameraService`)
- Test initial state is `isLoading = false`, `isReady = false`
- Test `initCamera()` requests permissions and updates state to `isReady = true` upon success
- Test `setPreset()` correctly updates the current preset in state
- Test `switchLens()` toggles between 'front' and 'back'

### Preset Parsing (`Preset.fromJson`)
- Test parsing of a valid CCD preset JSON
- Test fallback behavior when optional fields are missing
- Test parsing of nested `optionGroups`

## 3. Integration Testing Plan

### Native Plugin Bridge
- **MethodChannel**: Verify `initCamera`, `startPreview`, `stopPreview`, `setPreset`, `switchLens`, `takePhoto` return expected types
- **EventChannel**: Verify native errors and state changes are correctly streamed to Flutter

### Rendering Pipeline
- **iOS**: Verify `CMSampleBuffer` is correctly converted to `CVPixelBuffer` and registered with Flutter
- **Android**: Verify CameraX `Preview` use case correctly outputs to `SurfaceTexture` provided by `GLRenderer`

## 4. Manual QA Test Cases (Real Devices)

| Test ID | Scenario | Expected Result |
|---------|----------|-----------------|
| QA-01 | First launch on iOS 26 | App requests Camera, Mic, and Photo Library permissions |
| QA-02 | First launch on Android 16 | App requests Camera, Mic, and Media permissions |
| QA-03 | Camera Preview | Real-time preview displays at 60fps without stuttering |
| QA-04 | Switch Lens | Preview smoothly switches between front and back cameras |
| QA-05 | Change Preset | UI updates instantly; Native shader parameters update without restarting session |
| QA-06 | Take Photo (with Paper) | Photo is captured, paper frame is rendered directly into the final image, and saved to gallery |
| QA-07 | Background/Foreground | App correctly pauses/resumes camera session when sent to background |
