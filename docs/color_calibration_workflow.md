# Color Calibration Workflow (ColorChecker + Gray Card)

## Goal
- Keep cross-device output stable.
- Quantify tuning quality with objective metrics instead of subjective-only tweaking.
- Feed exact device calibration profiles instead of relying on brand-family fallback only.

## Capture Protocol
- Use a fixed scene with a ColorChecker chart and a gray card in the same frame.
- Lock exposure and white balance for reference shots whenever possible.
- Capture at least:
  - daylight outdoor
  - indoor warm light (2700K~3500K)
  - mixed/contrast scene (backlit)

## Data Format
- Export chart samples into CSV:
```csv
id,r,g,b
patch1,115,82,68
patch2,194,150,130
patch19,161,161,161
```
- `reference.csv`: target chart values.
- `measured.csv`: app output sampled values.

## Metrics
- `deltaEAvg`: average color error (CIE76).
- `deltaEMax`: worst patch error.
- `skinDeltaEAvg`: average error on skin-like patches (`patch11`~`patch16`).
- `wbBiasAvg`: gray-patch white-balance channel bias indicator.

## Run Benchmark
```bash
cd flutter_app
dart run tool/color_calibration_cli.dart reference.csv measured.csv
```

## Suggested Acceptance Gates
- `deltaEAvg <= 6.0`
- `skinDeltaEAvg <= 5.0`
- `deltaEMax <= 12.0`
- `wbBiasAvg <= 0.06`

## Device-Level Calibration Policy
- Every target device must be calibrated in three scenes:
  - daylight outdoor
  - indoor warm light
  - backlit / mixed contrast
- A device profile is not considered production-ready until all three scenes pass the gates.
- Exact profiles should be added to:
  - `flutter_app/lib/features/camera/device_calibration_profiles.dart`
- Match keys should be at least:
  - device brand
  - device model
  - runtime camera id when available
  - sensor megapixels when needed to disambiguate variants

## Tuning Order (Best Practice)
1. Tune device profile (`runtimeDeviceBrand/runtimeDeviceModel` calibration offsets).
2. Tune scene adaptation (`highlightRolloff/shadows/whites` deltas).
3. Tune dynamic skin protect (`skinSatProtect/skinLumaSoften/skinRedLimit` linkage).
4. Re-run benchmark after each change and keep regressions blocked by thresholds.

## Practical Rollout
1. Capture `reference.csv` / `measured.csv` for daylight.
2. Run `dart run tool/color_calibration_cli.dart reference.csv measured.csv`.
3. Repeat for indoor warm light and backlit.
4. Consolidate the three reports into one exact calibration entry in `device_calibration_profiles.dart`.
5. Verify both `Replica` mode and `Smart` mode before shipping.

## Template Emission Helper
- The CLI can emit copy-paste calibration scaffolds:
```bash
cd flutter_app
dart run tool/color_calibration_cli.dart \
  reference.csv \
  measured.csv \
  --preset fxn_r \
  --scene daylight \
  --brand xiaomi \
  --model "14 ultra" \
  --runtime-camera-id 0 \
  --sensor-mp 50 \
  --emit-profile-template
```
- Use the emitted `SceneCalibrationDelta` block for the current scene.
- Use the emitted `ExactDeviceCalibrationProfile` block the first time you add a new device.
- A detailed fill guide lives in:
  - `docs/device_calibration_fill_guide.md`
