import 'package:flutter_test/flutter_test.dart';
import 'package:retro_cam/features/camera/capture_pipeline.dart';
import 'package:retro_cam/features/camera/color_calibration.dart';
import 'package:retro_cam/features/camera/preview_renderer.dart';
import 'package:retro_cam/models/camera_definition.dart';

void main() {
  group('Color Pipeline: device + scene + skin dynamic', () {
    test('device profile should calibrate color biases on Android 200MP family',
        () {
      final params = PreviewRenderParams(
        defaultLook: const DefaultLook(
          temperature: 0,
          tint: 0,
          contrast: 1.0,
          saturation: 1.0,
          vignette: 0,
          distortion: 0,
          chromaticAberration: 0,
          bloom: 0,
          flare: 0,
          colorBiasR: 0.0,
          colorBiasG: 0.0,
          colorBiasB: 0.0,
        ),
        runtimeDeviceBrand: 'xiaomi',
        runtimeDeviceModel: '2407FPN8EG',
        runtimeSensorMp: 200.0,
      );
      final json = params.toJson();
      expect(json['deviceProfileId'], equals('xiaomi_family'));
      expect(json['calibrationVersion'], equals('v3.2'));
      expect((json['colorBiasR'] as num).toDouble(), lessThan(0.0));
      expect((json['colorBiasB'] as num).toDouble(), isNot(closeTo(0.0, 1e-8)));
      expect((json['deviceGamma'] as num).toDouble(), closeTo(2.24, 1e-6));
      expect((json['deviceCcm00'] as num).toDouble(), greaterThan(1.0));
      expect((json['deviceCcm11'] as num).toDouble(), greaterThan(1.0));
    });

    test('scene adaptation should modify highlight/shadows/whites coherently',
        () {
      final params = PreviewRenderParams(
        defaultLook: const DefaultLook(
          temperature: 0,
          contrast: 1.0,
          saturation: 1.0,
          vignette: 0,
          distortion: 0,
          chromaticAberration: 0,
          bloom: 0,
          flare: 0,
          highlights: -10,
          shadows: 5,
          whites: 6,
          highlightRolloff: 0.1,
        ),
        wbMode: 'auto',
        colorTempK: 5000,
        exposureOffset: -1.0, // backlit
      );
      final json = params.toJson();
      expect(json['sceneClass'], equals('backlit'));
      expect((json['highlightRolloff'] as num).toDouble(), greaterThan(0.2));
      expect((json['shadows'] as num).toDouble(), greaterThan(20.0));
      expect((json['whites'] as num).toDouble(), lessThan(-5.0));
    });

    test('dynamic skin protect should react to warm+lowlight', () {
      final params = PreviewRenderParams(
        defaultLook: const DefaultLook(
          temperature: 0,
          contrast: 1.0,
          saturation: 1.0,
          vignette: 0,
          distortion: 0,
          chromaticAberration: 0,
          bloom: 0,
          flare: 0,
          skinHueProtect: true,
          skinSatProtect: 0.95,
          skinLumaSoften: 0.02,
          skinRedLimit: 1.05,
        ),
        colorTempK: 3200,
        exposureOffset: 1.1,
      );
      final json = params.toJson();
      expect((json['skinSatProtect'] as num).toDouble(), lessThan(0.95));
      expect((json['skinLumaSoften'] as num).toDouble(), greaterThan(0.02));
      expect((json['skinRedLimit'] as num).toDouble(), lessThan(1.05));
    });
  });

  group('Color Pipeline: preview/capture consistency benchmark', () {
    test('preview payload and capture color-matrix inputs stay aligned', () {
      final params = PreviewRenderParams(
        defaultLook: const DefaultLook(
          temperature: -8,
          tint: 2,
          contrast: 1.15,
          saturation: 1.08,
          vignette: 0.12,
          distortion: 0,
          chromaticAberration: 0,
          bloom: 0,
          flare: 0,
          highlights: -14,
          shadows: 9,
          whites: 6,
          blacks: -6,
          colorBiasR: 0.01,
          colorBiasG: 0.00,
          colorBiasB: -0.01,
        ),
        wbMode: 'daylight',
        colorTempK: 6200,
        exposureOffset: 0.1,
      );
      final json = params.toJson();
      final matrix = CapturePipeline.buildColorMatrix(params);

      expect((json['contrast'] as num).toDouble(),
          closeTo(params.effectiveContrast, 1e-6));
      expect((json['saturation'] as num).toDouble(),
          closeTo(params.effectiveSaturation, 1e-6));
      expect((json['temperatureShift'] as num).toDouble(),
          closeTo(params.effectiveTemperature, 1e-6));
      expect(matrix.length, equals(20));
    });

    test('scene LUT routing should switch daylight/indoor/night consistently',
        () {
      const look = DefaultLook(
        baseLut: 'assets/lut/cameras/base.cube',
        baseLutDaylight: 'assets/lut/cameras/day.cube',
        baseLutIndoor: 'assets/lut/cameras/indoor.cube',
        baseLutNight: 'assets/lut/cameras/night.cube',
        lutStrength: 0.9,
        temperature: 0,
        contrast: 1.0,
        saturation: 1.0,
        vignette: 0,
        distortion: 0,
        chromaticAberration: 0,
        bloom: 0,
        flare: 0,
      );

      final outdoor = PreviewRenderParams(
        defaultLook: look,
        wbMode: 'daylight',
        colorTempK: 6500,
      ).toJson();
      final indoor = PreviewRenderParams(
        defaultLook: look,
        wbMode: 'incandescent',
        colorTempK: 3500,
      ).toJson();
      final night = PreviewRenderParams(
        defaultLook: look,
        exposureOffset: 1.2,
        colorTempK: 4200,
      ).toJson();

      expect(outdoor['baseLut'], equals('assets/lut/cameras/day.cube'));
      expect(indoor['baseLut'], equals('assets/lut/cameras/indoor.cube'));
      expect(night['baseLut'], equals('assets/lut/cameras/night.cube'));
      expect((night['lutStrength'] as num).toDouble(),
          lessThan((outdoor['lutStrength'] as num).toDouble()));
    });

    test('priority strategy should expose protection mode for gating', () {
      final backlit = PreviewRenderParams(
        defaultLook: const DefaultLook(
          temperature: 0,
          contrast: 1.0,
          saturation: 1.0,
          vignette: 0,
          distortion: 0,
          chromaticAberration: 0,
          bloom: 0,
          flare: 0,
          skinHueProtect: true,
          skinSatProtect: 0.94,
          skinLumaSoften: 0.02,
          skinRedLimit: 1.03,
        ),
        exposureOffset: -1.0,
      ).toJson();
      final lowLight = PreviewRenderParams(
        defaultLook: const DefaultLook(
          temperature: 0,
          contrast: 1.0,
          saturation: 1.0,
          vignette: 0,
          distortion: 0,
          chromaticAberration: 0,
          bloom: 0,
          flare: 0,
        ),
        exposureOffset: 1.2,
      ).toJson();

      expect(backlit['protectionMode'], equals('skin_first'));
      expect(lowLight['protectionMode'], equals('noise_first'));
    });
  });

  group('Color Calibration workflow metrics', () {
    test('deltaE report should be zero for identical chart', () {
      const patches = [
        RgbSample(id: 'patch1', r: 115, g: 82, b: 68),
        RgbSample(id: 'patch12', r: 223, g: 122, b: 87),
        RgbSample(id: 'patch19', r: 160, g: 160, b: 160),
      ];
      final report = ColorCalibration.evaluate(
        reference: patches,
        measured: patches,
      );
      expect(report.count, equals(3));
      expect(report.deltaEAvg, closeTo(0.0, 1e-8));
      expect(report.deltaEMax, closeTo(0.0, 1e-8));
      expect(report.skinDeltaEAvg, closeTo(0.0, 1e-8));
      expect(report.wbBiasAvg, closeTo(0.0, 1e-8));
    });
  });
}
