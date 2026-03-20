import 'package:flutter_test/flutter_test.dart';
import 'package:retro_cam/features/camera/preview_renderer.dart';
import 'package:retro_cam/models/camera_definition.dart';

void main() {
  group('Phase 2: Widget Effects Migration Tests', () {
    test(
        'All Layer 3 effects should be disabled in previewPolicy when migrating to Native',
        () {
      // Create a mock JSON representing a camera that has been fully migrated to Native
      final mockJson = {
        'id': 'migrated_cam',
        'name': 'Migrated Camera',
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
          // These must be false for Phase 2, as they are now handled by Native Shader
          'enableChromaticAberration': false,
          'enableBloom': false,
          'enableHalation': false,
          'enableVignette': false,
          'enablePaperTexture': false,
          // ColorFilter is also migrated to Native
          'enableContrast': false,
          'enableSaturation': false
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
          'chromaticAberration': 0.1,
          'bloom': 0.05,
          'halation': 0.05,
          'vignette': 0.2,
          'paperTexture': 0.1,
          'contrast': 1.2,
          'saturation': 1.1
        }
      };

      final camera = CameraDefinition.fromJson(mockJson);
      final params = PreviewRenderParams(
        defaultLook: camera.defaultLook,
        policy: camera.previewPolicy,
      );

      // 1. Verify policies are disabled (Widget layer won't render them)
      expect(params.policy.enableChromaticAberration, isFalse);
      expect(params.policy.enableBloom, isFalse);
      expect(params.policy.enableHalation, isFalse);
      expect(params.policy.enableVignette, isFalse);
      expect(params.policy.enablePaperTexture, isFalse);
      expect(params.policy.enableContrast, isFalse);
      expect(params.policy.enableSaturation, isFalse);

      // 2. Verify parameters are still retained for Native Shader
      expect(params.effectiveChromaticAberration, 0.1);
      expect(params.effectiveBloom, 0.05);
      expect(params.effectiveHalation, 0.05);
      expect(params.effectiveVignette, 0.2);
      expect(params.paperTexture, 0.1);
      // V3：叠加设备校准 + 场景自适应后，不再固定等于 defaultLook 原值
      expect(params.effectiveContrast, greaterThanOrEqualTo(1.2));
      expect(params.effectiveSaturation, greaterThanOrEqualTo(1.1));
    });

    test(
        'ColorFilter matrix should be identity when policy disables contrast/saturation',
        () {
      final mockJson = {
        'id': 'migrated_cam',
        'name': 'Migrated Camera',
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
        'previewPolicy': {'enableContrast': false, 'enableSaturation': false},
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
          'contrast': 1.5, // High contrast
          'saturation': 2.0, // High saturation
          'temperature': 0,
          'tint': 0,
          'highlights': 0,
          'shadows': 0,
          'whites': 0,
          'blacks': 0,
          'clarity': 0,
          'vibrance': 0,
          'colorBiasR': 0,
          'colorBiasG': 0,
          'colorBiasB': 0,
        }
      };

      final camera = CameraDefinition.fromJson(mockJson);
      final params = PreviewRenderParams(
        defaultLook: camera.defaultLook,
        policy: camera.previewPolicy,
      );

      // In Phase 2, we want to ensure the Dart-side ColorFilter doesn't double-apply
      // the contrast and saturation if the policy disables it.

      // Phase 2 重构后：ColorFilter/buildColorMatrix/computeColorMatrix 已全部删除
      // Flutter 层不再做像素级渲染，所有色彩处理由 Native Shader 完成
      // 验证 policy 状态仍然正确（用于 Native 层判断是否启用某些 pass）
      expect(params.policy.enableContrast, isFalse);
      expect(params.policy.enableSaturation, isFalse);

      // The parameters are still there for Native（并且以 effective* 为准）
      final json = params.toJson();
      expect(json['contrast'], closeTo(params.effectiveContrast, 0.0001));
      expect(json['saturation'], closeTo(params.effectiveSaturation, 0.0001));
      expect(params.effectiveContrast, greaterThan(1.5));
      expect(params.effectiveSaturation, greaterThanOrEqualTo(2.0));
    });
  });
}
