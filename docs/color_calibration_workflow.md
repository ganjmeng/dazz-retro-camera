# Color Calibration Workflow (ColorChecker + Gray Card)

## Goal
- Keep cross-device output stable.
- Quantify tuning quality with objective metrics instead of subjective-only tweaking.

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

## Tuning Order (Best Practice)
1. Tune device profile (`runtimeDeviceBrand/runtimeDeviceModel` calibration offsets).
2. Tune scene adaptation (`highlightRolloff/shadows/whites` deltas).
3. Tune dynamic skin protect (`skinSatProtect/skinLumaSoften/skinRedLimit` linkage).
4. Re-run benchmark after each change and keep regressions blocked by thresholds.
