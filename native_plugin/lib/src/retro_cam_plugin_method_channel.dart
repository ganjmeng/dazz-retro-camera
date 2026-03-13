import 'package:flutter/services.dart';
import 'retro_cam_plugin_platform_interface.dart';

class MethodChannelRetroCamPlugin extends RetroCamPluginPlatform {
  static const MethodChannel _channel = MethodChannel('com.retrocam.app/camera_control');

  @override
  Future<bool> initialize() async {
    final result = await _channel.invokeMethod<bool>('initialize');
    return result ?? false;
  }

  @override
  Future<void> setCameraConfig(Map<String, dynamic> config) async {
    await _channel.invokeMethod('setCameraConfig', config);
  }

  @override
  Future<void> updateActiveOptions(Map<String, String> options) async {
    await _channel.invokeMethod('updateActiveOptions', options);
  }

  @override
  Future<String?> takePhoto({String flashMode = 'off'}) async {
    return await _channel.invokeMethod<String>('takePhoto', {'flashMode': flashMode});
  }

  @override
  Future<void> startRecording() async {
    await _channel.invokeMethod('startRecording');
  }

  @override
  Future<String?> stopRecording() async {
    return await _channel.invokeMethod<String>('stopRecording');
  }

  @override
  Future<void> dispose() async {
    await _channel.invokeMethod('dispose');
  }
}
