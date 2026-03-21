import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_cam/models/camera_definition.dart';

void main() {
  group('Phase 1: Camera JSON Integrity & DefaultLook Tests', () {
    final assetsDir = Directory('assets/cameras');
    late List<File> jsonFiles;

    setUpAll(() {
      if (assetsDir.existsSync()) {
        jsonFiles = assetsDir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
      } else {
        // CI/CD or specific test run path adjustment
        jsonFiles = [];
      }
    });

    test('All camera JSON files should exist', () {
      expect(jsonFiles.isNotEmpty, isTrue, reason: 'No camera JSON files found in assets/cameras');
    });

    test('All camera JSON files should parse successfully into CameraDefinition', () async {
      for (final file in jsonFiles) {
        final content = await file.readAsString();
        final json = jsonDecode(content);
        
        try {
          final camera = CameraDefinition.fromJson(json);
          expect(camera.id, isNotEmpty, reason: 'Camera ID missing in ${file.path}');
          expect(camera.defaultLook, isNotNull, reason: 'defaultLook missing in ${file.path}');
        } catch (e) {
          fail('Failed to parse ${file.path}: $e');
        }
      }
    });

    test('Non-fisheye cameras include ND right after standard lens', () async {
      for (final file in jsonFiles) {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        final cameraId = json['id'] as String? ?? '';
        final lenses = (json['modules'] as Map<String, dynamic>)['lenses'] as List<dynamic>;
        final lensIds = lenses
            .map((lens) => (lens as Map<String, dynamic>)['id'] as String)
            .toList();

        if (cameraId == 'fisheye') {
          expect(
            lensIds.contains('nd'),
            isFalse,
            reason: 'Fish eye camera should not expose ND lens',
          );
          continue;
        }

        final stdIndex = lensIds.indexOf('std');
        expect(stdIndex, isNonNegative,
            reason: 'Standard lens missing in ${file.path}');
        expect(
          lensIds.length > stdIndex + 1 ? lensIds[stdIndex + 1] : null,
          'nd',
          reason: 'ND lens should be placed immediately after standard in ${file.path}',
        );
      }
    });

    test('DefaultLook parameters should be correctly parsed', () async {
      // Create a mock JSON with all DefaultLook parameters to verify parsing
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
        'defaultLook': {
          'temperature': -15,
          'contrast': 1.1,
          'saturation': 1.2,
          'vignette': 0.1,
          'distortion': 0.05,
          'chromaticAberration': 0.08,
          'bloom': 0.04,
          'flare': 0.02,
          'highlightRolloff': 0.25,
          'centerGain': 0.05,
          'edgeFalloff': 0.15,
          'cornerWarmShift': -0.02,
          'skinHueProtect': true,
          'chemicalIrregularity': 0.03
        }
      };

      final camera = CameraDefinition.fromJson(mockJson);
      final look = camera.defaultLook;

      expect(look.temperature, -15);
      expect(look.contrast, 1.1);
      expect(look.saturation, 1.2);
      expect(look.vignette, 0.1);
      expect(look.chromaticAberration, 0.08);
      expect(look.highlightRolloff, 0.25);
      expect(look.centerGain, 0.05);
      expect(look.edgeFalloff, 0.15);
      expect(look.cornerWarmShift, -0.02);
      expect(look.skinHueProtect, isTrue);
      expect(look.chemicalIrregularity, 0.03);
    });

    test('PreviewPolicy should correctly map data-driven flags', () {
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
        'exportPolicy': {'addWatermark': true, 'addDateStamp': true, 'applyFrame': true, 'forceJpeg': true},
        'videoConfig': {'maxResolution': '1080p', 'maxFps': 30, 'supportsAudio': true, 'defaultFilterIntensity': 1.0},
        'assets': {'luts': [], 'frames': [], 'watermarks': []},
        'meta': {'releaseDate': '2000', 'brand': 'Test', 'model': 'Test'},
        'defaultLook': {},
        'previewPolicy': {
          'enableChromaticAberration': false, // Phase 1: Ensure this can be disabled
          'enableBloom': false,
          'enableHalation': false
        }
      };

      final camera = CameraDefinition.fromJson(mockJson);
      final policy = camera.previewPolicy;

      expect(policy.enableChromaticAberration, isFalse);
      expect(policy.enableBloom, isFalse);
      expect(policy.enableHalation, isFalse);
    });
  });
}
