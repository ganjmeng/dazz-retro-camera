import 'package:flutter/services.dart';
import 'dart:async';
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
  // V3 aliases for compatibility
  bool get isInitialized => isReady;
  bool get isProcessing => isLoading;
  String? get errorMessage => error;
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

  // 原生事件流订阅（每次 initCamera 先取消旧订阅再重新订阅，防止重复监听）
  StreamSubscription? _eventSubscription;

  /// 初始化相机，获取 Texture ID 并开始预览
  Future<void> initCamera() async {
    state = state.copyWith(isLoading: true, error: null);
    
    // 相机权限已在 CameraScreen._requestPermissions() 中一次性请求
    // 这里只检查相机权限是否已授予，不再重复弹出权限对话框
    final cameraGranted = await Permission.camera.isGranted;
    if (!cameraGranted) {
      state = state.copyWith(
        isLoading: false,
        error: 'Camera permission denied. Please grant permission in settings.',
      );
      return;
    }

    try {
      // 取消旧订阅，防止重复监听
      await _eventSubscription?.cancel();
      _eventSubscription = _eventChannel.receiveBroadcastStream().listen(_onNativeEvent);

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

  /// 设置闪光灯模式 ('off' | 'on' | 'auto')
  Future<void> setFlash(String mode) async {
    try {
      await _channel.invokeMethod('setFlash', {'mode': mode});
    } catch (e) {
      print('Error setting flash: $e');
    }
  }

  /// 设置白平衡模式
  Future<void> setWhiteBalance(String mode) async {
    try {
      await _channel.invokeMethod('setWhiteBalance', {'mode': mode});
    } catch (e) {
      print('Error setting white balance: \$e');
    }
  }

  /// 设置缩放倍率（x0.6 ~ x20）
  Future<void> setZoom(double zoom) async {
    try {
      await _channel.invokeMethod('setZoom', {'zoom': zoom});
    } catch (e) {
      print('Error setting zoom: $e');
    }
  }

  /// 设置清晰度（锐化强度）
  /// [level] 0.0=低, 0.5=中, 1.0=高
  Future<void> setSharpen(double level) async {
    try {
      await _channel.invokeMethod('setSharpen', {'level': level});
    } catch (e) {
      print('Error setting sharpen: $e');
    }
  }

  /// 更新镜头参数（切换镜头时将参数传递到原生层渲染管线）
  /// [distortion] Brown-Conrady k1：负值=桶形(鱼眼), 正值=枕形, 0=无畸变
  /// [vignette] 暗角强度 0.0~1.0（原生层 GPU shader 叠加）
  /// [zoomFactor] 镜头缩放倍数（1.0=标准，0.5=超广角/鱼眼）
  /// [fisheyeMode] 圆形鱼眼模式：画面映射为圆形+四周黑色（等距投影）
  Future<void> updateLensParams({
    required double distortion,
    double vignette = 0.0,
    double zoomFactor = 1.0,
    bool fisheyeMode = false,
  }) async {
    try {
      await _channel.invokeMethod('updateLensParams', {
        'distortion': distortion,
        'vignette': vignette,
        'zoomFactor': zoomFactor,
        'fisheyeMode': fisheyeMode,
      });
    } catch (e) {
      print('Error updating lens params: $e');
    }
  }

  /// 切换前后置摄像头（switchCamera 为 switchLens 的别名）
  Future<void> switchCamera() async => switchLens();

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

  /// 将处理后的图片文件保存到相册（DCIM/DAZZ）
  /// [filePath] 必须是 dart:io File 可读的绝对路径（cache dir）
  /// [cameraId] 相机 ID，用于文件命名，使相册可按相机分类
  Future<String?> saveToGallery(String filePath, {String cameraId = ''}) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('saveToGallery', {
        'filePath': filePath,
        if (cameraId.isNotEmpty) 'cameraId': cameraId,
      });
      return result?['uri'] as String?;
    } catch (e) {
      print('Error saving to gallery: $e');
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
