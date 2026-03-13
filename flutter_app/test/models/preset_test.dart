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
        'baseModel': 'Sony CCD-TRV108',
      };
      final preset = Preset.fromJson(json);
      expect(preset.id, 'test_cam_01');
      expect(preset.name, 'Test Cam');
      expect(preset.category, 'ccd');
      expect(preset.outputType, 'photo');
      expect(preset.baseModel, 'Sony CCD-TRV108');
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
        'baseModel': 'Nikon FM2',
        'optionGroups': [
          {
            'type': 'films',
            'label': '胶卷',
            'defaultId': 'film_1',
            'items': [
              {
                'id': 'film_1',
                'name': 'Film 1',
                'lutName': 'film_1.cube',
              }
            ]
          }
        ],
        'uiCapabilities': {
          'showFilmSelector': true,
          'showLensSelector': false,
          'showPaperSelector': false,
          'showRatioSelector': true,
          'showWatermarkSelector': false,
        }
      };
      final preset = Preset.fromJson(json);
      expect(preset.isPremium, isTrue);
      expect(preset.optionGroups, isNotEmpty);
      expect(preset.optionGroups.first.type, 'films');
      expect(preset.optionGroups.first.items.first.id, 'film_1');
      expect(preset.uiCapabilities.showFilmSelector, isTrue);
      expect(preset.uiCapabilities.showLensSelector, isFalse);
      expect(preset.uiCapabilities.showRatioSelector, isTrue);
    });

    test('should derive outputType from legacy supportsVideo field', () {
      final json = {
        'id': 'legacy_cam',
        'name': 'Legacy Cam',
        'category': 'video',
        'supportsVideo': true,
        'supportsPhoto': false,
        'baseModel': 'Sony Handycam',
      };
      final preset = Preset.fromJson(json);
      expect(preset.outputType, 'video');
      expect(preset.supportsVideo, isTrue);
      expect(preset.supportsPhoto, isFalse);
    });

    test('should serialize to JSON and back', () {
      final original = Preset(
        id: 'round_trip',
        name: 'Round Trip',
        category: 'ccd',
        outputType: 'photo',
        baseModel: 'Test Model',
        isPremium: false,
      );
      final json = original.toJson();
      final restored = Preset.fromJson(json);
      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.outputType, original.outputType);
      expect(restored.baseModel, original.baseModel);
    });
  });
}
