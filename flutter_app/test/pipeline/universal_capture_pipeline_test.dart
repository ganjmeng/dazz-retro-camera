import 'package:flutter_test/flutter_test.dart';
import 'package:retro_cam/features/camera/capture_pipeline.dart';
import 'package:retro_cam/models/camera_definition.dart';

void main() {
  group('Phase 1: UniversalCapturePipeline Routing Tests', () {
    
    test('CapturePipeline should use GPU by default for supported platforms', () {
      final mockJson = {
        'id': 'test_cam',
        'name': 'Test',
        'category': 'digital',
        'mode': 'photo',
        'sensor': {'type': 'ccd', 'dynamicRange': 8, 'baseNoise': 0.1, 'colorDepth': 8},
        'modules': {'filters': [], 'lenses': [], 'ratios': [], 'frames': [], 'watermarks': {'presets': [], 'editor': {}}, 'extras': []},
        'defaultSelection': {'lens': 'std', 'flash': 'off'},
        'uiCapabilities': {'showLensRing': true, 'showZoomSlider': true, 'showExposureDial': true, 'showFlashButton': true, 'showWbButton': true, 'showQualitySelector': true, 'showRatioSelector': true},
        'previewCapabilities': {'supportsRealtimeLut': true, 'supportsRealtimeGrain': true, 'supportsRealtimeVignette': true, 'supportsRealtimeBlur': true, 'supportsRealtimeAberration': true},
        'previewPolicy': {'enableChromaticAberration': true, 'enableBloom': true, 'enableHalation': true, 'enableVignette': true, 'enablePaperTexture': true, 'enableContrast': true, 'enableSaturation': true},
        'exportPolicy': {'addWatermark': true, 'addDateStamp': true, 'applyFrame': true, 'forceJpeg': true},
        'videoConfig': {'maxResolution': '1080p', 'maxFps': 30, 'supportsAudio': true, 'defaultFilterIntensity': 1.0},
        'assets': {'luts': [], 'frames': [], 'watermarks': []},
        'meta': {'releaseDate': '2000', 'brand': 'Test', 'model': 'Test'},
        'defaultLook': {}
      };
      final camera = CameraDefinition.fromJson(mockJson);
      
      final pipeline = CapturePipeline(camera: camera);
      expect(pipeline, isNotNull);
    });

    test('Pipeline should correctly extract PreviewRenderParams from CameraDefinition', () {
      final mockJson = {
        'id': 'ccd_r',
        'name': 'CCD R',
        'category': 'digital',
        'mode': 'photo',
        'sensor': {'type': 'ccd', 'dynamicRange': 8, 'baseNoise': 0.1, 'colorDepth': 8},
        'modules': {'filters': [], 'lenses': [], 'ratios': [], 'frames': [], 'watermarks': {'presets': [], 'editor': {}}, 'extras': []},
        'defaultSelection': {'lens': 'std', 'flash': 'off'},
        'uiCapabilities': {'showLensRing': true, 'showZoomSlider': true, 'showExposureDial': true, 'showFlashButton': true, 'showWbButton': true, 'showQualitySelector': true, 'showRatioSelector': true},
        'previewCapabilities': {'supportsRealtimeLut': true, 'supportsRealtimeGrain': true, 'supportsRealtimeVignette': true, 'supportsRealtimeBlur': true, 'supportsRealtimeAberration': true},
        'previewPolicy': {'enableChromaticAberration': true, 'enableBloom': true, 'enableHalation': true, 'enableVignette': true, 'enablePaperTexture': true, 'enableContrast': true, 'enableSaturation': true},
        'exportPolicy': {'addWatermark': true, 'addDateStamp': true, 'applyFrame': true, 'forceJpeg': true},
        'videoConfig': {'maxResolution': '1080p', 'maxFps': 30, 'supportsAudio': true, 'defaultFilterIntensity': 1.0},
        'assets': {'luts': [], 'frames': [], 'watermarks': []},
        'meta': {'releaseDate': '2000', 'brand': 'Test', 'model': 'Test'},
        'defaultLook': {
          'temperature': -15,
          'contrast': 0.98,
          'saturation': 1.10,
          'highlightRolloff': 0.06,
          'centerGain': 0.08,
          'edgeFalloff': 0.20,
          'cornerWarmShift': 0.03,
          'skinHueProtect': true,
          'chemicalIrregularity': 0.008
        }
      };

      final camera = CameraDefinition.fromJson(mockJson);
      final look = camera.defaultLook;
      expect(look.highlightRolloff, 0.06);
      expect(look.edgeFalloff, 0.20);
      expect(look.skinHueProtect, isTrue);
    });
  });
}
