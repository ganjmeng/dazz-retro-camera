import 'package:flutter_test/flutter_test.dart';
import 'package:retro_cam/features/camera/preview_renderer.dart';
import 'package:retro_cam/features/camera/pipelines/pipeline_utils.dart';
import 'package:retro_cam/models/camera_definition.dart';

void main() {
  group('Phase 2: Render Logic Migration Tests', () {
    test(
        'PreviewRenderParams should correctly map data-driven flags for Layer 3 widget removal',
        () {
      // Phase 2 requires removing Flutter Widget layer effects (Bloom, Halation, Vignette)
      // and moving them to Native Shader. The previewPolicy should allow disabling them.
      final mockJson = {
        'id': 'test_cam',
        'name': 'Test',
        'category': 'digital',
        'mode': 'photo',
        'sensor': {
          'type': 'ccd',
          'dynamicRange': 8,
          'baseNoise': 0.1,
          'colorDepth': 8
        },
        'modules': {
          'filters': [],
          'lenses': [],
          'ratios': [],
          'frames': [],
          'watermarks': {'presets': [], 'editor': {}},
          'extras': []
        },
        'defaultSelection': {'lens': 'std', 'flash': 'off'},
        'uiCapabilities': {
          'showLensRing': true,
          'showZoomSlider': true,
          'showExposureDial': true,
          'showFlashButton': true,
          'showWbButton': true,
          'showQualitySelector': true,
          'showRatioSelector': true
        },
        'previewCapabilities': {
          'supportsRealtimeLut': true,
          'supportsRealtimeGrain': true,
          'supportsRealtimeVignette': true,
          'supportsRealtimeBlur': true,
          'supportsRealtimeAberration': true
        },
        'exportPolicy': {
          'addWatermark': true,
          'addDateStamp': true,
          'applyFrame': true,
          'forceJpeg': true
        },
        'videoConfig': {
          'maxResolution': '1080p',
          'maxFps': 30,
          'supportsAudio': true,
          'defaultFilterIntensity': 1.0
        },
        'assets': {'luts': [], 'frames': [], 'watermarks': []},
        'meta': {'releaseDate': '2000', 'brand': 'Test', 'model': 'Test'},
        'previewPolicy': {
          'enableBloom': false,
          'enableHalation': false,
          'enableVignette': false,
          'enableChromaticAberration': false
        },
        'defaultLook': {
          'bloom': 0.5,
          'halation': 0.5,
          'vignette': 0.5,
          'chromaticAberration': 0.1
        }
      };

      final camera = CameraDefinition.fromJson(mockJson);
      final params = PreviewRenderParams(
        defaultLook: camera.defaultLook,
        policy: camera.previewPolicy,
      );

      // Verify the policy disables the Flutter-side rendering
      expect(params.policy.enableBloom, isFalse);
      expect(params.policy.enableHalation, isFalse);
      expect(params.policy.enableVignette, isFalse);
      expect(params.policy.enableChromaticAberration, isFalse);

      // But the parameters themselves should still hold the values to pass to Native
      expect(params.effectiveBloom, 0.5);
      expect(params.effectiveHalation, 0.5);
      expect(params.effectiveVignette, 0.5);
      expect(params.effectiveChromaticAberration, 0.1);
    });

    test('ColorFilter logic verification for Phase 2 migration', () {
      // In Phase 2, the ColorFilter matrix calculation is moved to Native.
      // We test the Dart implementation here to ensure we understand the baseline
      // that needs to be replicated in GLSL/Metal.

      final mockJson = {
        'id': 'test_cam',
        'name': 'Test',
        'category': 'digital',
        'mode': 'photo',
        'sensor': {
          'type': 'ccd',
          'dynamicRange': 8,
          'baseNoise': 0.1,
          'colorDepth': 8
        },
        'modules': {
          'filters': [],
          'lenses': [],
          'ratios': [],
          'frames': [],
          'watermarks': {'presets': [], 'editor': {}},
          'extras': []
        },
        'defaultSelection': {'lens': 'std', 'flash': 'off'},
        'uiCapabilities': {
          'showLensRing': true,
          'showZoomSlider': true,
          'showExposureDial': true,
          'showFlashButton': true,
          'showWbButton': true,
          'showQualitySelector': true,
          'showRatioSelector': true
        },
        'previewCapabilities': {
          'supportsRealtimeLut': true,
          'supportsRealtimeGrain': true,
          'supportsRealtimeVignette': true,
          'supportsRealtimeBlur': true,
          'supportsRealtimeAberration': true
        },
        'previewPolicy': {
          'enableChromaticAberration': true,
          'enableBloom': true,
          'enableHalation': true,
          'enableVignette': true,
          'enablePaperTexture': true,
          'enableContrast': true,
          'enableSaturation': true
        },
        'exportPolicy': {
          'addWatermark': true,
          'addDateStamp': true,
          'applyFrame': true,
          'forceJpeg': true
        },
        'videoConfig': {
          'maxResolution': '1080p',
          'maxFps': 30,
          'supportsAudio': true,
          'defaultFilterIntensity': 1.0
        },
        'assets': {'luts': [], 'frames': [], 'watermarks': []},
        'meta': {'releaseDate': '2000', 'brand': 'Test', 'model': 'Test'},
        'defaultLook': {
          'contrast': 1.2,
          'saturation': 1.5,
          'temperature': 50, // Warm
        }
      };

      final camera = CameraDefinition.fromJson(mockJson);
      final params = PreviewRenderParams(
        defaultLook: camera.defaultLook,
        policy: camera.previewPolicy,
      );

      // Verify the parameters that will be sent to the native shader
      // 注意：V3 加入了设备校准 + 场景自适应，因此不再固定等于 defaultLook 原值。
      expect(params.effectiveContrast, greaterThan(1.2));
      expect(params.effectiveSaturation, greaterThan(1.5));
      expect(params.effectiveTemperature, greaterThan(50.0));

      // Phase 2 重构后：computeColorMatrix 已删除，所有色彩处理由 Native Shader 完成
      // 验证 toJson 包含所有必要的参数
      final json = params.toJson();
      expect(json['contrast'], closeTo(params.effectiveContrast, 0.0001));
      expect(json['saturation'], closeTo(params.effectiveSaturation, 0.0001));
      expect(json['temperatureShift'],
          closeTo(params.effectiveTemperature, 0.0001));
    });
  });
}
