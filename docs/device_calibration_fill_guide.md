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
- Template entries are sample scaffolds only.
- Active shipped exact overrides should be added to:
  - `kLocalExactDeviceCalibrationProfiles`

## Hot Device Registration Rule
- Put iPhone exact overrides into `_kIphoneHotExactOverrides`.
- Put Samsung Ultra exact overrides into `_kSamsungUltraHotExactOverrides`.
- Put Xiaomi Ultra exact overrides into `_kXiaomiUltraHotExactOverrides`.
- Keep `kLocalExactDeviceCalibrationProfiles` as the merged export only.
- Prefer one device-line block per family instead of a single flat unsorted list.
- Add only verified devices that are worth shipping broadly.

## First-Wave Coverage List
- iPhone:
  - `iPhone 15 Pro`
  - `iPhone 15 Pro Max`
  - `iPhone 16 Pro`
  - `iPhone 16 Pro Max`
- Samsung Ultra:
  - `Galaxy S23 Ultra`
  - `Galaxy S24 Ultra`
  - `Galaxy S25 Ultra`
- Xiaomi Ultra:
  - `Xiaomi 13 Ultra`
  - `Xiaomi 14 Ultra`
  - `Xiaomi 15 Ultra`

## First-Wave Priority Order
1. `iPhone 15 Pro / 15 Pro Max`
2. `Galaxy S24 Ultra`
3. `Xiaomi 14 Ultra`
4. `iPhone 16 Pro / 16 Pro Max`
5. `Galaxy S23 Ultra / S25 Ultra`
6. `Xiaomi 13 Ultra / 15 Ultra`

## Naming / Scope Rule
- `brand` must match runtime normalized brand, such as `apple`, `samsung`, `xiaomi`.
- `model` should be the concrete marketed runtime model string.
- `cameraId` should stay preset-specific, for example `fxn_r` or `grd_r`.
- If the same physical phone needs overrides for multiple presets, add separate entries.
- Use `runtimeCameraId` and `sensorMp` to separate main / ultra-wide / tele variants.

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
- Default all users to family calibration unless a verified exact override exists.
- Do not enable a device entry in production until all three scenes pass.
- Keep one exact profile per preset per physical camera module when the target look differs.
