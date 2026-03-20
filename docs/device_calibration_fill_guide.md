# Device Calibration Fill Guide

## Goal
- Fill exact per-device calibration profiles for replica mode without affecting other presets.
- Keep each replica preset tied to one target look on one physical device/camera module.

## Target Presets
- `fxn_r`
- `ccd_r`
- `grd_r`
- `cpm35`
- `inst_c`

## Where To Fill
- Exact profile templates live in:
  - `flutter_app/lib/features/camera/device_calibration_profiles.dart`
- CLI benchmark helper lives in:
  - `flutter_app/tool/color_calibration_cli.dart`

## Match Keys
- `brand`: use the runtime debug brand, lowercased.
- `model`: use the runtime debug model, lowercased.
- `cameraId`: keep the preset id fixed, such as `fxn_r`.
- `runtimeCameraId`: use the native camera id reported by debug info.
- `sensorMp`: fill only when needed to distinguish variants of the same module.

## Three-Scene Fill Rule
- `daylight`: outdoor daylight reference.
- `indoor`: warm indoor light, roughly 2700K to 3500K.
- `backlit`: mixed contrast or backlit scene.

## Recommended Workflow
1. Capture `reference.csv` and `measured.csv` for one scene.
2. Run:
   ```bash
   cd flutter_app
   dart run tool/color_calibration_cli.dart reference.csv measured.csv --preset fxn_r --scene daylight --brand xiaomi --model "14 ultra" --runtime-camera-id 0 --sensor-mp 50 --emit-profile-template
   ```
3. Copy the emitted `SceneCalibrationDelta` block into the matching scene field.
4. For the first scene on a new device, also copy the emitted `ExactDeviceCalibrationProfile` template.
5. Repeat for `indoor` and `backlit`.
6. Replace all `__fill_*__` placeholders before shipping.

## What To Adjust
- `temperatureOffset`: first fix obvious warm/cool drift.
- `tintOffset`: then fix magenta/green drift.
- `contrastScale`: fix global flatness or excessive punch.
- `saturationScale`: fix overall color density after white balance is close.
- `colorBiasROffset/GOffset/BOffset`: use only for residual channel skew after the above.
- `ccm`: fill only after chart-based matrix fitting is available.
- `whiteScaleR/G/B`: fill only when gray-card derived neutral gains are known.
- `gamma`: adjust only when tonal mismatch is systematic across scenes.

## Preset Intent
- `fxn_r`: cool, thin, negative-scan style.
- `ccd_r`: crisp blue-cyan compact digital.
- `grd_r`: hard, dry, street-contrast signature.
- `cpm35`: warm Kodak-style compact film.
- `inst_c`: soft instant film chemistry and paper feel.

## Acceptance Gate
- `deltaEAvg <= 6.0`
- `skinDeltaEAvg <= 5.0`
- `deltaEMax <= 12.0`
- `wbBiasAvg <= 0.06`

## Shipping Rule
- Do not enable a device entry in production until all three scenes pass.
- Keep one exact profile per preset per physical camera module when the target look differs.
