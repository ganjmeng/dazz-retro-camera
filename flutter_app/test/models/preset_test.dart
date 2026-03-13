import 'package:flutter_test/flutter_test.dart';
import 'package:retro_cam/models/preset.dart';

void main() {
  group('Preset Model Tests', () {
    test('should parse minimal valid JSON', () {
      final json = {
        'id': 'test_cam_01',
        'name': 'Test Cam',
        'category': 'ccd',
        'outputType': 'photo',
        'baseModel': {
          'sensor': {'type': 'ccd-2005'}
        }
      };

      final preset = Preset.fromJson(json);

      expect(preset.id, 'test_cam_01');
      expect(preset.name, 'Test Cam');
      expect(preset.category, 'ccd');
      expect(preset.outputType, 'photo');
      expect(preset.baseModel['sensor']?['type'], 'ccd-2005');
      expect(preset.optionGroups, isEmpty);
      expect(preset.uiCapabilities, isNotNull);
      expect(preset.uiCapabilities.showFilmSelector, isFalse);
    });

    test('should parse full JSON with optionGroups and uiCapabilities', () {
      final json = {
        'id': 'full_cam',
        'name': 'Full Cam',
        'category': 'film',
        'outputType': 'photo',
        'isPremium': true,
        'baseModel': {
          'sensor': {'type': 'film-sim'}
        },
        'optionGroups': {
          'films': [
            {
              'id': 'film_1',
              'name': 'Film 1',
              'isDefault': true,
              'rendering': {'lut': 'film_1.cube'}
            }
          ]
        },
        'uiCapabilities': {
          'showFilmSelector': true,
          'showLensSelector': false,
          'showPaperSelector': false,
          'showRatioSelector': true,
          'showWatermarkSelector': false
        }
      };

      final preset = Preset.fromJson(json);

      expect(preset.isPremium, isTrue);
      expect(preset.optionGroups, isNotEmpty);
      expect(preset.optionGroups['films']?.first.id, 'film_1');
      expect(preset.uiCapabilities.showFilmSelector, isTrue);
      expect(preset.uiCapabilities.showLensSelector, isFalse);
      expect(preset.uiCapabilities.showRatioSelector, isTrue);
    });
  });
}
