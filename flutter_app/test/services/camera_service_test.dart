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
      // Mock the camera control channel
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.retrocam.app/camera_control'),
        (MethodCall methodCall) async {
          log.add(methodCall);
          if (methodCall.method == 'initCamera') {
            return {'textureId': 1};
          } else if (methodCall.method == 'takePhoto') {
            return {'filePath': '/path/to/photo.jpg'};
          }
          return null;
        },
      );
      log.clear();
      container = ProviderContainer();
    });

    tearDown(() {
      container.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.retrocam.app/camera_control'),
        null,
      );
    });

    test('initial state should be uninitialized', () {
      final state = container.read(cameraServiceProvider);
      expect(state.isInitialized, isFalse);
      expect(state.textureId, isNull);
      expect(state.currentPreset, isNull);
    });

    test('setPreset should update state', () async {
      final preset = Preset.fromJson({
        'id': 'test_cam',
        'name': 'Test Cam',
        'category': 'ccd',
        'outputType': 'photo',
        'baseModel': 'Sony CCD',
      });
      await container.read(cameraServiceProvider.notifier).setPreset(preset);
      final state = container.read(cameraServiceProvider);
      expect(state.currentPreset?.id, 'test_cam');
    });

    test('CameraState isInitialized alias works correctly', () {
      final state = container.read(cameraServiceProvider);
      expect(state.isInitialized, equals(state.isReady));
      expect(state.isProcessing, equals(state.isLoading));
    });
  });
}
