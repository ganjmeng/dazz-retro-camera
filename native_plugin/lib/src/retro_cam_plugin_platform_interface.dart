import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'retro_cam_plugin_method_channel.dart';

abstract class RetroCamPluginPlatform extends PlatformInterface {
  RetroCamPluginPlatform() : super(token: _token);
  static final Object _token = Object();
  static RetroCamPluginPlatform _instance = MethodChannelRetroCamPlugin();
  static RetroCamPluginPlatform get instance => _instance;
  static set instance(RetroCamPluginPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<bool> initialize() => throw UnimplementedError();
  Future<void> setCameraConfig(Map<String, dynamic> config) => throw UnimplementedError();
  Future<void> updateActiveOptions(Map<String, String> options) => throw UnimplementedError();
  Future<String?> takePhoto({String flashMode = 'off'}) => throw UnimplementedError();
  Future<void> startRecording() => throw UnimplementedError();
  Future<String?> stopRecording() => throw UnimplementedError();
  Future<void> dispose() => throw UnimplementedError();
}
