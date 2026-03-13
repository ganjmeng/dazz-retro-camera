import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:retro_cam/services/camera_service.dart';
import 'package:retro_cam/models/preset.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CameraService Tests', () {
    late ProviderContainer container;
    final List<MethodCall> log = [];

    setUp(() {
      const MethodChannel('com.retrocam.app/camera').setMockMethodCallHandler((MethodCall methodCall) async {
        log.add(methodCall);
        if (methodCall.method == 'initCamera') {
          return 1; // mock textureId
        } else if (methodCall.method == 'takePhoto') {
          return '/path/to/photo.jpg';
        }
        return null;
      });
      log.clear();
      container = ProviderContainer();
    });

    tearDown(() {
      container.dispose();
    });

    test('initial state should be uninitialized', () {
      final state = container.read(cameraServiceProvider);
      expect(state.isInitialized, isFalse);
      expect(state.textureId, isNull);
      expect(state.currentPreset, isNull);
    });

    test('setPreset should update state and call native channel', () async {
      final preset = Preset.fromJson({
        'id': 'test_cam',
        'name': 'Test Cam',
        'category': 'ccd',
        'outputType': 'photo',
        'baseModel': {}
      });

      await container.read(cameraServiceProvider.notifier).setPreset(preset);

      final state = container.read(cameraServiceProvider);
      expect(state.currentPreset?.id, 'test_cam');
      
      expect(log.length, 1);
      expect(log.first.method, 'setPreset');
      expect(log.first.arguments, isA<Map>());
      expect((log.first.arguments as Map)['id'], 'test_cam');
    });

    test('takePhoto should call native channel and set isProcessing', () async {
      // Setup
      final service = container.read(cameraServiceProvider.notifier);
      
      // Execute
      final future = service.takePhoto();
      
      // Verify processing state
      expect(container.read(cameraServiceProvider).isProcessing, isTrue);
      
      // Wait for completion
      await future;
      
      // Verify final state
      expect(container.read(cameraServiceProvider).isProcessing, isFalse);
      
      // Verify channel call
      expect(log.any((call) => call.method == 'takePhoto'), isTrue);
    });
  });
}
