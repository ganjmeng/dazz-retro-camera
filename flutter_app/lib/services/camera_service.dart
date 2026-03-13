import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/preset.dart';
import '../core/constants.dart';

/// 相机状态模型
class CameraState {
  final bool isReady;
  final bool isLoading;
  final String? error;
  final int? textureId;
  final Preset? currentPreset;
  final bool isRecording;
  final String currentLens; // "front" | "back"

  const CameraState({
    this.isReady = false,
    this.isLoading = false,
    this.error,
    this.textureId,
    this.currentPreset,
    this.isRecording = false,
    this.currentLens = 'back',
  });

  CameraState copyWith({
    bool? isReady,
    bool? isLoading,
    String? error,
    int? textureId,
    Preset? currentPreset,
    bool? isRecording,
    String? currentLens,
  }) {
    return CameraState(
      isReady: isReady ?? this.isReady,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      textureId: textureId ?? this.textureId,
      currentPreset: currentPreset ?? this.currentPreset,
      isRecording: isRecording ?? this.isRecording,
      currentLens: currentLens ?? this.currentLens,
    );
  }
}

/// 封装 MethodChannel 和 EventChannel，管理相机的所有原生交互
class CameraService extends StateNotifier<CameraState> {
  CameraService() : super(const CameraState());

  static const MethodChannel _channel = MethodChannel(AppConstants.cameraControlChannel);
  static const EventChannel _eventChannel = EventChannel(AppConstants.cameraEventsChannel);

  /// 初始化相机，获取 Texture ID 并开始预览
  Future<void> initCamera() async {
    state = state.copyWith(isLoading: true, error: null);
    
    // 检查并请求权限
    final statuses = await [
      Permission.camera,
      Permission.microphone,
      Permission.storage,
    ].request();
    
    final hasPermissions = statuses[Permission.camera]?.isGranted == true;
    if (!hasPermissions) {
      state = state.copyWith(
        isLoading: false, 
        error: 'Camera permission denied. Please grant permission in settings.',
      );
      return;
    }

    try {
      // 监听原生事件流
      _eventChannel.receiveBroadcastStream().listen(_onNativeEvent);

      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('initCamera', {
        'resolution': '1080p',
        'lens': state.currentLens,
      });

      if (result == null || result['textureId'] == null) {
        throw Exception('initCamera returned null textureId');
      }

      final textureId = result['textureId'] as int;
      state = state.copyWith(isLoading: false, isReady: true, textureId: textureId);
      await startPreview();
    } catch (e) {
      state = state.copyWith(isLoading: false, error: 'Failed to init camera: $e');
    }
  }

  Future<void> startPreview() async {
    try {
      await _channel.invokeMethod('startPreview');
    } catch (e) {
      print('Error starting preview: $e');
    }
  }

  Future<void> stopPreview() async {
    try {
      await _channel.invokeMethod('stopPreview');
    } catch (e) {
      print('Error stopping preview: $e');
    }
  }

  /// 切换 Preset（相机型号）
  Future<void> setPreset(Preset preset) async {
    try {
      await _channel.invokeMethod('setPreset', {'preset': preset.toJson()});
      state = state.copyWith(currentPreset: preset);
    } catch (e) {
      print('Error setting preset: $e');
    }
  }

  /// 切换前后置摄像头
  Future<void> switchLens() async {
    final newLens = state.currentLens == 'back' ? 'front' : 'back';
    try {
      await _channel.invokeMethod('switchLens', {'lens': newLens});
      state = state.copyWith(currentLens: newLens);
    } catch (e) {
      print('Error switching lens: $e');
    }
  }

  /// 触发拍照，返回文件路径
  Future<String?> takePhoto() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('takePhoto', {
        'flashMode': 'auto',
      });
      return result?['filePath'] as String?;
    } catch (e) {
      print('Error taking photo: $e');
      return null;
    }
  }

  /// 开始录制视频
  Future<bool> startRecording() async {
    if (!state.isReady) return false;
    
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('startRecording');
      if (result?['success'] == true) {
        state = state.copyWith(isRecording: true);
        return true;
      }
      return false;
    } catch (e) {
      print('Failed to start recording: $e');
      return false;
    }
  }

  /// 停止录制视频，返回文件路径
  Future<String?> stopRecording() async {
    if (!state.isReady || !state.isRecording) return null;
    
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('stopRecording');
      state = state.copyWith(isRecording: false);
      return result?['filePath'] as String?;
    } catch (e) {
      print('Failed to stop recording: $e');
      state = state.copyWith(isRecording: false);
      return null;
    }
  }

  /// 释放所有资源
  Future<void> disposeCamera() async {
    try {
      await _channel.invokeMethod('dispose');
    } catch (e) {
      print('Error disposing camera: $e');
    }
  }

  /// 处理原生回调事件
  void _onNativeEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['type'] as String?;
    final payload = event['payload'] as Map<dynamic, dynamic>?;

    switch (type) {
      case AppConstants.eventCameraReady:
        state = state.copyWith(isReady: true);
        break;
      case AppConstants.eventError:
        final message = payload?['message'] as String? ?? 'Unknown error';
        state = state.copyWith(error: message);
        break;
      case AppConstants.eventRecordingStateChanged:
        final isRecording = payload?['isRecording'] as bool? ?? false;
        state = state.copyWith(isRecording: isRecording);
        break;
      default:
        break;
    }
  }

  @override
  void dispose() {
    disposeCamera();
    super.dispose();
  }
}

// Provider 暴露
final cameraServiceProvider = StateNotifierProvider<CameraService, CameraState>((ref) {
  return CameraService();
});
