import 'package:flutter/services.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/preset.dart';
import '../models/camera_definition.dart';
import '../core/constants.dart';
import '../core/app_logger.dart';

const _tag = 'CameraService';

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
  /// Android Camera2 传感器调试信息（onCameraReady 事件携带）
  final Map<String, dynamic> activeCameraDebugInfo;

  const CameraState({
    this.isReady = false,
    this.isLoading = false,
    this.error,
    this.textureId,
    this.currentPreset,
    this.isRecording = false,
    this.currentLens = 'back',
    this.activeCameraDebugInfo = const {},
  });

  CameraState copyWith({
    bool? isReady,
    bool? isLoading,
    String? error,
    int? textureId,
    Preset? currentPreset,
    bool? isRecording,
    String? currentLens,
    Map<String, dynamic>? activeCameraDebugInfo,
  }) {
    return CameraState(
      isReady: isReady ?? this.isReady,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      textureId: textureId ?? this.textureId,
      currentPreset: currentPreset ?? this.currentPreset,
      isRecording: isRecording ?? this.isRecording,
      currentLens: currentLens ?? this.currentLens,
      activeCameraDebugInfo: activeCameraDebugInfo ?? this.activeCameraDebugInfo,
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
    AppLogger.i(_tag, 'initCamera() start, lens=${state.currentLens}');
    state = state.copyWith(isLoading: true, error: null);

    // 相机权限已在 CameraScreen._onRequestCameraPermission() 中确认授予
    // 这里只做二次检查作为安全层
    final cameraGranted = await Permission.camera.isGranted;
    if (!cameraGranted) {
      AppLogger.w(_tag, 'initCamera: camera permission denied');
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

      AppLogger.d(_tag, 'invoking native initCamera...');
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('initCamera', {
        'resolution': '1080p',
        'lens': state.currentLens,
      });

      if (result == null || result['textureId'] == null) {
        throw Exception('initCamera returned null textureId');
      }

      final textureId = result['textureId'] as int;
      AppLogger.i(_tag, 'initCamera success, textureId=$textureId');
      state = state.copyWith(isLoading: false, isReady: true, textureId: textureId);
      await startPreview();
    } catch (e, st) {
      AppLogger.e(_tag, 'initCamera failed', error: e, stackTrace: st);
      state = state.copyWith(isLoading: false, error: 'Failed to init camera: $e');
    }
  }

  Future<void> startPreview() async {
    try {
      AppLogger.d(_tag, 'startPreview()');
      await _channel.invokeMethod('startPreview');
    } catch (e, st) {
      AppLogger.w(_tag, 'startPreview failed', error: e, stackTrace: st);
    }
  }

  Future<void> stopPreview() async {
    try {
      AppLogger.d(_tag, 'stopPreview()');
      await _channel.invokeMethod('stopPreview');
    } catch (e, st) {
      AppLogger.w(_tag, 'stopPreview failed', error: e, stackTrace: st);
    }
  }

  /// 切换 Preset（相机型号）
  Future<void> setPreset(Preset preset) async {
    try {
      await _channel.invokeMethod('setPreset', {'preset': preset.toJson()});
      state = state.copyWith(currentPreset: preset);
    } catch (e, st) {
      AppLogger.e(_tag, 'setPreset failed', error: e, stackTrace: st);
    }
  }

  /// 切换相机（CameraDefinition），将 defaultLook 色彩参数传递给原生渲染器
  /// 这是修复 FQS 紫色偏色的关键方法：确保 colorBiasR/G/B、grainSize、sharpness 等
  /// 专用字段从 defaultLook JSON 正确传递到 iOS Metal Shader 和 Android GLSL Shader
  Future<void> setCamera(CameraDefinition camera) async {
    try {
      final presetPayload = <String, dynamic>{
        'cameraId': camera.id,
        'defaultLook': camera.defaultLook.toJson(),
      };
      await _channel.invokeMethod('setPreset', {'preset': presetPayload});
    } catch (e, st) {
      AppLogger.e(_tag, 'setCamera failed', error: e, stackTrace: st);
    }
  }

  /// 设置闪光灯模式 ('off' | 'on' | 'auto')
  Future<void> setFlash(String mode) async {
    try {
      await _channel.invokeMethod('setFlash', {'mode': mode});
    } catch (e, st) {
      AppLogger.w(_tag, 'setFlash failed', error: e, stackTrace: st);
    }
  }

  /// 设置白平衡模式
  Future<void> setWhiteBalance(String mode) async {
    try {
      await _channel.invokeMethod('setWhiteBalance', {'mode': mode});
    } catch (e, st) {
      AppLogger.w(_tag, 'setWhiteBalance failed', error: e, stackTrace: st);
    }
  }

  /// 设置缩放倍率（x0.6 ~ x20）
  Future<void> setZoom(double zoom) async {
    try {
      await _channel.invokeMethod('setZoom', {'zoom': zoom});
    } catch (e, st) {
      AppLogger.w(_tag, 'setZoom failed', error: e, stackTrace: st);
    }
  }

  /// 点击对焦 + 对焦点曝光
  /// [x], [y]: 归一化坐标 [0, 1]，原点在取景框左上角
  Future<void> setFocus(double x, double y) async {
    try {
      await _channel.invokeMethod('setFocus', {'x': x, 'y': y});
    } catch (e, st) {
      AppLogger.w(_tag, 'setFocus failed', error: e, stackTrace: st);
    }
  }

  /// 设置清晰度（锐化强度）
  /// [level] 0.0=低, 0.5=中, 1.0=高
  Future<void> setSharpen(double level) async {
    try {
      await _channel.invokeMethod('setSharpen', {'level': level});
    } catch (e, st) {
      AppLogger.w(_tag, 'setSharpen failed', error: e, stackTrace: st);
    }
  }

  /// 更新镜头参数（切换镜头时将参数传递到原生层渲染管线）
  /// 包含所有 LensDefinition 中的效果字段
  Future<void> updateLensParams({
    required double distortion,
    double vignette = 0.0,
    double zoomFactor = 1.0,
    bool fisheyeMode = false,
    double chromaticAberration = 0.0,
    double bloom = 0.0,
    double softFocus = 0.0,
    double exposure = 0.0,
    double contrast = 0.0,
    double saturation = 0.0,
    double highlightCompression = 0.0,
  }) async {
    try {
      await _channel.invokeMethod('updateLensParams', {
        'distortion': distortion,
        'vignette': vignette,
        'zoomFactor': zoomFactor,
        'fisheyeMode': fisheyeMode,
        'chromaticAberration': chromaticAberration,
        'bloom': bloom,
        'softFocus': softFocus,
        'exposure': exposure,
        'contrast': contrast,
        'saturation': saturation,
        'highlightCompression': highlightCompression,
      });
    } catch (e, st) {
      AppLogger.e(_tag, 'updateLensParams failed', error: e, stackTrace: st);
    }
  }

  /// 将完整渲染参数（滤镜+镜头+defaultLook 组合后的值）发送到原生预览 Shader
  /// 复用 setPreset 通道中 glRenderer.updateParams 的能力
  Future<void> updateRenderParams(Map<String, dynamic> params) async {
    try {
      // 通过 setPreset 通道发送，原生端会读取 defaultLook 子对象并 updateParams
      // 但更直接的方式是新增一个专用 method channel
      // 这里直接复用 setPreset：将 params 作为 defaultLook 传入
      await _channel.invokeMethod('setPreset', {
        'preset': {
          'cameraId': '',  // 空字符串不会触发 setCameraId
          'defaultLook': params,
        },
      });
    } catch (e, st) {
      AppLogger.e(_tag, 'updateRenderParams failed', error: e, stackTrace: st);
    }
  }

  /// 设置前置摄像头镜像开关
  Future<void> setMirrorFrontCamera(bool enabled) async {
    try {
      await _channel.invokeMethod('setMirrorFrontCamera', {'enabled': enabled});
    } catch (e, st) {
      AppLogger.w(_tag, 'setMirrorFrontCamera failed', error: e, stackTrace: st);
    }
  }

  /// 切换前后置摄像头（switchCamera 为 switchLens 的别名）
  Future<void> switchCamera() async => switchLens();

  /// 切换前后置摄像头（调用原生 switchLens）
  Future<void> switchLens() async {
    final newLens = state.currentLens == 'back' ? 'front' : 'back';
    try {
      await _channel.invokeMethod('switchLens', {'lens': newLens});
      state = state.copyWith(currentLens: newLens);
    } catch (e, st) {
      AppLogger.e(_tag, 'switchLens failed', error: e, stackTrace: st);
    }
  }

  /// 仅切换内部 lens 方向状态，不调用原生层。
  /// 配合 stopPreview + initCamera 路径使用，由 initCamera 根据新方向重建相机。
  void toggleLensDirection() {
    final newLens = state.currentLens == 'back' ? 'front' : 'back';
    state = state.copyWith(currentLens: newLens);
  }

  /// 触发拍照，返回 {filePath, captureWidth, captureHeight}
  Future<Map<String, dynamic>?> takePhoto() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('takePhoto', {
        'flashMode': 'auto',
      });
      if (result == null) return null;
      return {
        'filePath': result['filePath'] as String?,
        'captureWidth': (result['captureWidth'] as num?)?.toInt() ?? 0,
        'captureHeight': (result['captureHeight'] as num?)?.toInt() ?? 0,
      };
    } catch (e, st) {
      AppLogger.e(_tag, 'takePhoto failed', error: e, stackTrace: st);
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
    } catch (e, st) {
      AppLogger.e(_tag, 'startRecording failed', error: e, stackTrace: st);
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
    } catch (e, st) {
      AppLogger.e(_tag, 'stopRecording failed', error: e, stackTrace: st);
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
    } catch (e, st) {
      AppLogger.e(_tag, 'saveToGallery failed', error: e, stackTrace: st);
      return null;
    }
  }

  /// 释放所有资源
  Future<void> disposeCamera() async {
    try {
      await _channel.invokeMethod('dispose');
    } catch (e, st) {
      AppLogger.w(_tag, 'disposeCamera failed', error: e, stackTrace: st);
    }
  }

  /// 处理原生回调事件
  void _onNativeEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['type'] as String?;
    final payload = event['payload'] as Map<dynamic, dynamic>?;

    switch (type) {
      case AppConstants.eventCameraReady:
        // payload 包含 Android Camera2 传感器调试信息（cameraId/sensorSize/sensorMp/focalLengths/facing）
        final debugInfo = <String, dynamic>{};
        if (payload != null && payload.isNotEmpty) {
          payload.forEach((k, v) => debugInfo[k.toString()] = v);
        }
        state = state.copyWith(
          isReady: true,
          activeCameraDebugInfo: debugInfo.isNotEmpty ? debugInfo : state.activeCameraDebugInfo,
        );
        break;
      case AppConstants.eventError:
        final message = payload?['message'] as String? ?? 'Unknown error';
        AppLogger.e(_tag, 'Native error event: $message');
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
