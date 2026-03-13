import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:retro_cam/services/preset_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PresetRepository Tests', () {
    test('loadPresets should load and parse preset JSON files', () async {
      // Mock asset bundle
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('flutter/assets', (ByteData? message) async {
        final String key = String.fromCharCodes(message!.buffer.asUint8List());
        if (key == 'AssetManifest.json') {
          return const StringCodec().encodeMessage('{"assets/presets/test_cam.json":[]}');
        } else if (key == 'assets/presets/test_cam.json') {
          return const StringCodec().encodeMessage('''
          {
            "id": "test_cam",
            "name": "Test Cam",
            "category": "ccd",
            "outputType": "photo",
            "baseModel": {}
          }
          ''');
        }
        return null;
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);

      final presets = await container.read(presetListProvider.future);
      
      expect(presets, isNotEmpty);
      expect(presets.first.id, 'test_cam');
      expect(presets.first.name, 'Test Cam');
    });
  });
}
