import 'package:flutter/services.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/preset.dart';
import '../models/camera_definition.dart';
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
  final String lifecyclePhase; // idle|initializing|running|paused|disposing
  final int runtimeStatsUpdatedAtMs;

  /// Android Camera2 传感器调试信息（onCameraReady 事件携带）
  final Map<String, dynamic> activeCameraDebugInfo;
  final bool supportsLivePhoto;

  const CameraState({
    this.isReady = false,
    this.isLoading = false,
    this.error,
    this.textureId,
    this.currentPreset,
    this.isRecording = false,
    this.currentLens = 'back',
    this.lifecyclePhase = 'idle',
    this.runtimeStatsUpdatedAtMs = 0,
    this.activeCameraDebugInfo = const {},
    this.supportsLivePhoto = false,
  });

  CameraState copyWith({
    bool? isReady,
    bool? isLoading,
    String? error,
    int? textureId,
    Preset? currentPreset,
    bool? isRecording,
    String? currentLens,
    String? lifecyclePhase,
    int? runtimeStatsUpdatedAtMs,
    Map<String, dynamic>? activeCameraDebugInfo,
    bool? supportsLivePhoto,
  }) {
    return CameraState(
      isReady: isReady ?? this.isReady,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      textureId: textureId ?? this.textureId,
      currentPreset: currentPreset ?? this.currentPreset,
      isRecording: isRecording ?? this.isRecording,
      currentLens: currentLens ?? this.currentLens,
      lifecyclePhase: lifecyclePhase ?? this.lifecyclePhase,
      runtimeStatsUpdatedAtMs:
          runtimeStatsUpdatedAtMs ?? this.runtimeStatsUpdatedAtMs,
      activeCameraDebugInfo:
          activeCameraDebugInfo ?? this.activeCameraDebugInfo,
      supportsLivePhoto: supportsLivePhoto ?? this.supportsLivePhoto,
    );
  }
}

/// 封装 MethodChannel 和 EventChannel，管理相机的所有原生交互
class CameraService extends StateNotifier<CameraState> {
  CameraService() : super(const CameraState());

  static const MethodChannel _channel =
      MethodChannel(AppConstants.cameraControlChannel);
  static const EventChannel _eventChannel =
      EventChannel(AppConstants.cameraEventsChannel);

  // 原生事件流订阅（每次 initCamera 先取消旧订阅再重新订阅，防止重复监听）
  StreamSubscription? _eventSubscription;
  // 生命周期操作串行化，避免 init/stop/dispose 并发竞态
  Future<void> _lifecycleChain = Future.value();
  bool _isDisposed = false;
  int _initGeneration = 0;
  Completer<String?>? _pendingVideoRecordedCompleter;

  Future<T> _serializeLifecycle<T>(Future<T> Function() action) async {
    final completer = Completer<T>();
    _lifecycleChain = _lifecycleChain.then((_) async {
      try {
        if (_isDisposed) {
          throw StateError('CameraService already disposed');
        }
        final result = await action();
        completer.complete(result);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// 初始化相机，获取 Texture ID 并开始预览
  Future<void> initCamera() async {
    await _serializeLifecycle(() async {
      state = state.copyWith(
        isReady: false,
        isLoading: true,
        error: null,
        textureId: null,
        lifecyclePhase: 'initializing',
        runtimeStatsUpdatedAtMs: 0,
        activeCameraDebugInfo: const {},
        supportsLivePhoto: false,
      );

      // 相机权限已在 CameraScreen._requestPermissions() 中一次性请求
      // 这里只检查相机权限是否已授予，不再重复弹出权限对话框
      final cameraGranted = await Permission.camera.isGranted;
      if (!cameraGranted) {
        state = state.copyWith(
          isLoading: false,
          error:
              'Camera permission denied. Please grant permission in settings.',
        );
        return;
      }

      final generation = ++_initGeneration;
      try {
        // 取消旧订阅，防止重复监听
        await _eventSubscription?.cancel();
        _eventSubscription =
            _eventChannel.receiveBroadcastStream().listen(_onNativeEvent);

        final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'initCamera',
          {
            'resolution': '1080p',
            'lens': state.currentLens,
          },
        );

        if (generation != _initGeneration) return;
        if (result == null || result['textureId'] == null) {
          throw Exception('initCamera returned null textureId');
        }

        final textureId = result['textureId'] as int;
        state = state.copyWith(
          isLoading: false,
          isReady: true,
          textureId: textureId,
          lifecyclePhase: 'running',
          runtimeStatsUpdatedAtMs: 0,
          supportsLivePhoto: false,
        );
        await _channel.invokeMethod('startPreview');
      } catch (e) {
        state = state.copyWith(
          isReady: false,
          isLoading: false,
          error: 'Failed to init camera: $e',
          textureId: null,
          lifecyclePhase: 'idle',
          runtimeStatsUpdatedAtMs: 0,
          supportsLivePhoto: false,
        );
      }
    });
  }

  Future<void> startPreview() async {
    await _serializeLifecycle(() async {
      try {
        await _channel.invokeMethod('startPreview');
        state = state.copyWith(
          isReady: state.textureId != null,
          lifecyclePhase: 'running',
        );
      } catch (e) {
        print('Error starting preview: $e');
      }
    });
  }

  Future<void> stopPreview() async {
    await _serializeLifecycle(() async {
      try {
        await _channel.invokeMethod('stopPreview');
        state = state.copyWith(
          isReady: false,
          textureId: null,
          lifecyclePhase: 'paused',
          runtimeStatsUpdatedAtMs: 0,
          supportsLivePhoto: false,
        );
      } catch (e) {
        print('Error stopping preview: $e');
        state = state.copyWith(
          isReady: false,
          textureId: null,
          lifecyclePhase: 'paused',
          runtimeStatsUpdatedAtMs: 0,
        );
      }
    });
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
    } catch (e) {
      print('Error setting camera: \$e');
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

  /// 点击对焦 + 对焦点曝光
  /// [x], [y]: 归一化坐标 [0, 1]，原点在取景框左上角
  Future<void> setFocus(double x, double y) async {
    try {
      await _channel.invokeMethod('setFocus', {'x': x, 'y': y});
    } catch (e) {
      print('Error setting focus: $e');
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
    } catch (e) {
      print('Error updating lens params: $e');
    }
  }

  /// 将完整渲染参数（滤镜+镜头+defaultLook 组合后的值）发送到原生预览 Shader
  /// 使用独立通道，避免污染原生 preset 缓存（会导致切机后参数串台）
  Future<int?> updateRenderParams(
    Map<String, dynamic> params, {
    int? version,
  }) async {
    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('updateRenderParams', {
        'params': params,
        if (version != null) 'version': version,
      });
      final raw = result?['appliedVersion'];
      if (raw is num) return raw.toInt();
      return int.tryParse(raw?.toString() ?? '');
    } catch (e) {
      print('Error updating render params: $e');
      return null;
    }
  }

  /// 一次性同步预览运行态参数（镜头 + 渲染 + 缩放），减少多次 MethodChannel 往返和中间态闪动。
  Future<int?> syncRuntimeState({
    required Map<String, dynamic> lensParams,
    required Map<String, dynamic> renderParams,
    required double zoom,
    int? version,
  }) async {
    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('syncRuntimeState', {
        'lensParams': lensParams,
        'renderParams': renderParams,
        'zoom': zoom,
        if (version != null) 'version': version,
      });
      final raw = result?['appliedVersion'];
      if (raw is num) return raw.toInt();
      return int.tryParse(raw?.toString() ?? '');
    } catch (e) {
      print('Error syncing runtime state: $e');
      return null;
    }
  }

  /// 设置前置摄像头镜像开关
  Future<void> setMirrorFrontCamera(bool enabled) async {
    try {
      await _channel.invokeMethod('setMirrorFrontCamera', {'enabled': enabled});
    } catch (e) {
      print('Error setting mirror front camera: \$e');
    }
  }

  /// 设置后置摄像头镜像开关
  Future<void> setMirrorBackCamera(bool enabled) async {
    try {
      await _channel.invokeMethod('setMirrorBackCamera', {'enabled': enabled});
    } catch (e) {
      print('Error setting mirror back camera: $e');
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
    } catch (e) {
      print('Error switching lens: $e');
    }
  }

  /// 仅切换内部 lens 方向状态，不调用原生层。
  /// 配合 stopPreview + initCamera 路径使用，由 initCamera 根据新方向重建相机。
  void toggleLensDirection() {
    final newLens = state.currentLens == 'back' ? 'front' : 'back';
    state = state.copyWith(currentLens: newLens);
  }

  /// 触发拍照，返回 {filePath, captureWidth, captureHeight}
  /// [deviceQuarter] 设备方向：0=竖屏, 1=左横屏, 2=倒竖, 3=右横屏
  Future<Map<String, dynamic>?> takePhoto({int deviceQuarter = 0}) async {
    try {
      final result =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('takePhoto', {
        'flashMode': 'auto',
        'deviceQuarter': deviceQuarter,
      });
      if (result == null) return null;
      return {
        'filePath': result['filePath'] as String?,
        'captureWidth': (result['captureWidth'] as num?)?.toInt() ?? 0,
        'captureHeight': (result['captureHeight'] as num?)?.toInt() ?? 0,
      };
    } catch (e) {
      print('Error taking photo: $e');
      return null;
    }
  }

  /// 开始录制视频
  Future<bool> startRecording() async {
    if (!state.isReady) return false;

    try {
      _pendingVideoRecordedCompleter = null;
      final result =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('startRecording');
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
      final completer = Completer<String?>();
      _pendingVideoRecordedCompleter = completer;
      final result =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('stopRecording');
      state = state.copyWith(isRecording: false);
      final directPath = result?['filePath'] as String?;
      if (directPath != null &&
          directPath.isNotEmpty &&
          !completer.isCompleted) {
        completer.complete(directPath);
      }
      return completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => directPath,
      );
    } catch (e) {
      print('Failed to stop recording: $e');
      state = state.copyWith(isRecording: false);
      _pendingVideoRecordedCompleter = null;
      return null;
    }
  }

  /// 将处理后的图片文件保存到相册（DCIM/DAZZ）
  /// [filePath] 必须是 dart:io File 可读的绝对路径（cache dir）
  /// [cameraId] 相机 ID，用于文件命名，使相册可按相机分类
  Future<String?> saveToGallery(String filePath, {String cameraId = ''}) async {
    try {
      final result =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('saveToGallery', {
        'filePath': filePath,
        if (cameraId.isNotEmpty) 'cameraId': cameraId,
      });
      return result?['uri'] as String?;
    } catch (e) {
      print('Error saving to gallery: $e');
      return null;
    }
  }

  Future<String?> saveMotionPhoto(
    String imagePath,
    String videoPath, {
    String cameraId = '',
  }) async {
    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('saveMotionPhoto', {
        'imagePath': imagePath,
        'videoPath': videoPath,
        if (cameraId.isNotEmpty) 'cameraId': cameraId,
      });
      return result?['uri'] as String?;
    } catch (e) {
      print('Error saving motion photo: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> captureLivePhoto(
      {int deviceQuarter = 0}) async {
    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('captureLivePhoto', {
        'deviceQuarter': deviceQuarter,
      });
      if (result == null) return null;
      return {
        'filePath': result['filePath'] as String?,
        'galleryAssetId': result['galleryAssetId'] as String?,
      };
    } catch (e) {
      print('Error capturing live photo: $e');
      return null;
    }
  }

  /// 用新文件覆盖已保存的相册资产内容（Android content:// URI）。
  Future<bool> replaceGalleryImage(String uri, String filePath) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'replaceGalleryImage',
        {
          'uri': uri,
          'filePath': filePath,
        },
      );
      return result?['success'] == true;
    } catch (e) {
      print('Error replacing gallery image: $e');
      return false;
    }
  }

  /// 释放所有资源
  Future<void> disposeCamera() async {
    await _serializeLifecycle(() async {
      try {
        _initGeneration++;
        state = state.copyWith(lifecyclePhase: 'disposing');
        await _eventSubscription?.cancel();
        _eventSubscription = null;
        await _channel.invokeMethod('dispose');
        state = state.copyWith(
          isReady: false,
          textureId: null,
          isRecording: false,
          lifecyclePhase: 'idle',
          runtimeStatsUpdatedAtMs: 0,
          activeCameraDebugInfo: const {},
          supportsLivePhoto: false,
        );
      } catch (e) {
        print('Error disposing camera: $e');
      }
    });
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
          activeCameraDebugInfo:
              debugInfo.isNotEmpty ? debugInfo : state.activeCameraDebugInfo,
          supportsLivePhoto: payload?['supportsLivePhoto'] as bool? ?? false,
        );
        break;
      case AppConstants.eventError:
        final message = payload?['message'] as String? ?? 'Unknown error';
        state = state.copyWith(error: message);
        break;
      case AppConstants.eventRecordingStateChanged:
        final isRecording = payload?['isRecording'] as bool? ?? false;
        state = state.copyWith(isRecording: isRecording);
        break;
      case 'onVideoRecorded':
        final filePath = payload?['filePath'] as String?;
        final completer = _pendingVideoRecordedCompleter;
        _pendingVideoRecordedCompleter = null;
        if (completer != null && !completer.isCompleted) {
          completer.complete(filePath);
        }
        break;
      case 'onCameraRuntimeStats':
        final runtime = <String, dynamic>{};
        if (payload != null && payload.isNotEmpty) {
          payload.forEach((k, v) => runtime[k.toString()] = v);
        }
        final rtLumaRaw = runtime['rtLuma'];
        final rtLuma = rtLumaRaw is num
            ? rtLumaRaw.toDouble()
            : double.tryParse(rtLumaRaw?.toString() ?? '');
        // Android 侧历史值是 0~255，这里统一归一化到 0~1，跨端口径一致。
        if (rtLuma != null && rtLuma > 1.5) {
          runtime['rtLuma'] = (rtLuma / 255.0).clamp(0.0, 1.0);
        }
        if (runtime.isNotEmpty) {
          state = state.copyWith(
            activeCameraDebugInfo: {
              ...state.activeCameraDebugInfo,
              ...runtime,
            },
            runtimeStatsUpdatedAtMs: DateTime.now().millisecondsSinceEpoch,
          );
        }
        break;
      default:
        break;
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    // Provider 销毁阶段不阻塞等待；尽力释放原生资源。
    unawaited(_channel.invokeMethod('dispose'));
    _eventSubscription?.cancel();
    super.dispose();
  }
}

// Provider 暴露
final cameraServiceProvider =
    StateNotifierProvider<CameraService, CameraState>((ref) {
  return CameraService();
});
