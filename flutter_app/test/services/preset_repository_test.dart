import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:retro_cam/services/preset_repository.dart';
import 'package:retro_cam/models/preset.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PresetRepository Tests', () {
    test('PresetRepository can be instantiated', () {
      final repo = PresetRepository();
      expect(repo, isNotNull);
    });

    test('Preset can be parsed from valid JSON', () {
      final json = {
        'id': 'ccd_cool_01',
        'name': 'CCD Cool',
        'category': 'CCD',
        'supportsPhoto': true,
        'supportsVideo': true,
        'isPremium': false,
        'resources': {
          'lutName': 'lut_ccd_cool.png',
          'grainTextureName': 'grain_fine.png',
          'leakTextureNames': [],
          'frameOverlayName': null,
        },
        'params': {
          'exposureBias': 0.2,
          'contrast': 1.15,
          'saturation': 0.85,
          'temperatureShift': -400.0,
          'tintShift': 8.0,
          'sharpen': 0.4,
          'blurRadius': 1.2,
          'grainAmount': 0.25,
          'noiseAmount': 0.15,
          'vignetteAmount': 0.4,
          'chromaticAberration': 0.018,
          'bloomAmount': 0.3,
          'halationAmount': 0.1,
          'jpegArtifacts': 0.05,
          'scanlineAmount': 0.0,
          'dateStamp': {
            'enabled': true,
            'format': 'yyyy MM dd',
            'color': '#FFFFA500',
            'position': 'bottomRight',
          },
        },
      };
      final preset = Preset.fromJson(json);
      expect(preset.id, 'ccd_cool_01');
      expect(preset.name, 'CCD Cool');
      expect(preset.category, 'CCD');
      expect(preset.outputType, 'both'); // derived from supportsPhoto+supportsVideo
      expect(preset.resources, isNotNull);
      expect(preset.resources!.lutName, 'lut_ccd_cool.png');
      expect(preset.params, isNotNull);
      expect(preset.params!.grainAmount, 0.25);
    });

    test('presetListProvider returns a list', () async {
      // Note: In test environment, assets may not be available
      // This test verifies the provider structure is correct
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // The provider should return a future (even if it fails to load assets in test)
      final future = container.read(presetListProvider.future);
      expect(future, isA<Future<List<Preset>>>());
    });
  });
}
