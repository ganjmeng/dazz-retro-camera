// camera_notifier.dart
// Multi-camera state management.
// Replaces grd_camera_notifier.dart with full multi-camera support.
// Loads any camera from the registry and manages all UI state.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:native_exif/native_exif.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/camera_definition.dart';
import '../../models/camera_registry.dart';
import '../../services/camera_service.dart';
import '../../services/location_service.dart';
import 'preview_renderer.dart';
import 'capture_pipeline.dart';
import '../../services/retain_settings_service.dart';
import '../../services/app_prefs_service.dart';
import '../../services/original_asset_service.dart';
import 'render_style_mode.dart';
import 'preview_performance_mode.dart';

// 默认关闭后台二次增强替换，优先保证预览与成片一致性（WYSIWYG）。
const bool _kEnableBackgroundEnhanceReplace = false;

// ─────────────────────────────────────────────────────────────────────────────
// CameraAppState — full UI state for the camera screen
// ─────────────────────────────────────────────────────────────────────────────

class CameraAppState {
  final String activeCameraId;
  final CameraDefinition? camera;
  final bool isLoading;
  final String? error;

  // Current selections
  final String? activeFilterId;
  final String? activeLensId;
  final String? activeRatioId;
  final String? activeFrameId;
  final String? activeWatermarkId;

  // User adjustments
  final double temperatureOffset; // -100..100
  final double exposureValue; // -2.0..2.0
  final double beautyStrength; // 0.0..1.0
  final bool beautyCustomized;
  // White balance
  final String wbMode; // 'auto' | 'daylight' | 'incandescent'
  final int colorTempK; // 1800..8000
  final String? watermarkColor; // hex color override for watermark
  final String?
      watermarkPosition; // 位置覆盖: 'bottom_right'|'bottom_left'|'top_right'|'top_left'|'bottom_center'|'top_center'
  final String? watermarkSize; // 大小覆盖: 'small'|'medium'|'large'
  final String? watermarkDirection; // 方向覆盖: 'horizontal'|'vertical'
  final String? watermarkStyle; // 样式覆盖: preset id
  final String? frameBackgroundColor; // hex color override for frame background

  // UI state
  final String?
      activePanel; // null | 'filter' | 'lens' | 'ratio' | 'frame' | 'watermark'
  final bool gridEnabled;
  final bool showTopMenu;
  final bool showCameraManager;
  final String flashMode; // 'off' | 'on' | 'auto'
  final int timerSeconds; // 0 | 3 | 10
  final bool isFrontCamera;
  final bool isTakingPhoto;
  final bool showCaptureFlash;
  final bool smallFrameMode;
  final int sharpenLevel; // 0=低, 1=中, 2=高

  // Zoom & Minimap
  final double zoomLevel; // 0.6 ~ 20.0, default 1.0
  final bool showZoomSlider; // 胶囊点击后展开缩放滑动条
  final bool minimapEnabled; // 小窗模式开关
  final bool locationEnabled; // 位置信息开关：开启后拍照将 GPS 坐标写入 EXIF
  final bool showDebugOverlay; // 调试信息浮层：显示实时渲染参数
  final bool shutterSoundEnabled; // 快门声音开关
  final bool mirrorFrontCamera; // 前置摄像头镜像开关
  final bool mirrorBackCamera; // 后置摄像头镜像开关
  final bool shutterVibrationEnabled; // 快门振动开关
  final bool fisheyeMode; // 鱼眼圆圈模式
  final bool livePhotoEnabled; // Live Photo 开关
  final bool saveOriginalEnabled; // 保存底片
  // ── 双重曝光 ──────────────────────────────────────────────────────────────
  final bool doubleExpEnabled; // 双重曝光开关
  final String? doubleExpFirstPath; // 第一张照片本地路径（待合成）
  final double doubleExpBlend; // 混合比例 0.3~0.7，默认 0.5
  // ── 连拍 ──────────────────────────────────────────────────────────────────
  final int burstCount; // 连拍张数：0=关闭, 3=3张, 10=10张
  final int burstProgress; // 当前连拍进度（0=未开始，1~N=第N张完成）
  final bool isBursting; // 是否正在连拍中
  // Debug: 最近一次拍照的分辨率信息
  final String lastCaptureRaw; // e.g. "4032×3024" 原始分辨率
  final String lastCaptureOutput; // e.g. "3024×3024" 输出分辨率
  // Runtime color calibration context
  final String runtimeDeviceBrand;
  final String runtimeDeviceModel;
  final String runtimeCameraId;
  final double runtimeSensorMp;
  final double runtimeRtLightIndex;
  final double runtimeRtIso;
  final double runtimeRtExposureMs;
  final double runtimeRtLuma;
  final RenderStyleMode renderStyleMode;
  final PreviewPerformanceMode previewPerformanceMode;

  const CameraAppState({
    this.activeCameraId = 'grd_r',
    this.camera,
    this.isLoading = true,
    this.error,
    this.activeFilterId,
    this.activeLensId,
    this.activeRatioId,
    this.activeFrameId,
    this.activeWatermarkId,
    this.temperatureOffset = 0,
    this.exposureValue = 0,
    this.beautyStrength = 0,
    this.beautyCustomized = false,
    this.wbMode = 'auto',
    this.colorTempK = 6300,
    this.watermarkColor,
    this.watermarkPosition,
    this.watermarkSize,
    this.watermarkDirection,
    this.watermarkStyle,
    this.frameBackgroundColor,
    this.activePanel,
    this.gridEnabled = false,
    this.showTopMenu = false,
    this.showCameraManager = false,
    this.flashMode = 'off',
    this.timerSeconds = 0,
    this.isFrontCamera = false,
    this.isTakingPhoto = false,
    this.showCaptureFlash = false,
    this.smallFrameMode = false,
    this.sharpenLevel = 1, // 默认中
    this.zoomLevel = 1.0,
    this.showZoomSlider = false,
    this.minimapEnabled = false,
    this.locationEnabled = false,
    this.showDebugOverlay = false,
    this.shutterSoundEnabled = true,
    this.mirrorFrontCamera = true,
    this.mirrorBackCamera = false,
    this.shutterVibrationEnabled = true,
    this.fisheyeMode = false,
    this.livePhotoEnabled = false,
    this.saveOriginalEnabled = false,
    this.doubleExpEnabled = false,
    this.doubleExpFirstPath,
    this.doubleExpBlend = 0.5,
    this.burstCount = 0,
    this.burstProgress = 0,
    this.isBursting = false,
    this.lastCaptureRaw = '',
    this.lastCaptureOutput = '',
    this.runtimeDeviceBrand = '',
    this.runtimeDeviceModel = '',
    this.runtimeCameraId = '',
    this.runtimeSensorMp = 0,
    this.runtimeRtLightIndex = -1.0,
    this.runtimeRtIso = -1.0,
    this.runtimeRtExposureMs = -1.0,
    this.runtimeRtLuma = -1.0,
    this.renderStyleMode = RenderStyleMode.replica,
    this.previewPerformanceMode = PreviewPerformanceMode.lightweight,
  });
  CameraAppState copyWith({
    String? activeCameraId,
    CameraDefinition? camera,
    bool? isLoading,
    String? error,
    String? activeFilterId,
    String? activeLensId,
    String? activeRatioId,
    String? activeFrameId,
    String? activeWatermarkId,
    double? temperatureOffset,
    double? exposureValue,
    double? beautyStrength,
    bool? beautyCustomized,
    String? wbMode,
    int? colorTempK,
    String? watermarkColor,
    String? watermarkPosition,
    String? watermarkSize,
    String? watermarkDirection,
    String? watermarkStyle,
    bool clearWatermarkOverrides = false,
    String? frameBackgroundColor,
    String? activePanel,
    bool? gridEnabled,
    bool? showTopMenu,
    bool? showCameraManager,
    String? flashMode,
    int? timerSeconds,
    bool? isFrontCamera,
    bool? isTakingPhoto,
    bool? showCaptureFlash,
    bool? smallFrameMode,
    int? sharpenLevel,
    double? zoomLevel,
    bool? showZoomSlider,
    bool? minimapEnabled,
    bool? locationEnabled,
    bool? showDebugOverlay,
    bool? shutterSoundEnabled,
    bool? mirrorFrontCamera,
    bool? mirrorBackCamera,
    bool? shutterVibrationEnabled,
    bool? fisheyeMode,
    bool? livePhotoEnabled,
    bool? saveOriginalEnabled,
    bool? doubleExpEnabled,
    String? doubleExpFirstPath,
    bool clearDoubleExpFirst = false,
    double? doubleExpBlend,
    int? burstCount,
    int? burstProgress,
    bool? isBursting,
    String? lastCaptureRaw,
    String? lastCaptureOutput,
    String? runtimeDeviceBrand,
    String? runtimeDeviceModel,
    String? runtimeCameraId,
    double? runtimeSensorMp,
    double? runtimeRtLightIndex,
    double? runtimeRtIso,
    double? runtimeRtExposureMs,
    double? runtimeRtLuma,
    RenderStyleMode? renderStyleMode,
    PreviewPerformanceMode? previewPerformanceMode,
    bool clearPanel = false,
    bool clearError = false,
    bool clearFrameId = false, // 用于将 activeFrameId 清空为 null
  }) {
    return CameraAppState(
      activeCameraId: activeCameraId ?? this.activeCameraId,
      camera: camera ?? this.camera,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      activeFilterId: activeFilterId ?? this.activeFilterId,
      activeLensId: activeLensId ?? this.activeLensId,
      activeRatioId: activeRatioId ?? this.activeRatioId,
      activeFrameId:
          clearFrameId ? null : (activeFrameId ?? this.activeFrameId),
      activeWatermarkId: activeWatermarkId ?? this.activeWatermarkId,
      temperatureOffset: temperatureOffset ?? this.temperatureOffset,
      exposureValue: exposureValue ?? this.exposureValue,
      beautyStrength: beautyStrength ?? this.beautyStrength,
      beautyCustomized: beautyCustomized ?? this.beautyCustomized,
      wbMode: wbMode ?? this.wbMode,
      colorTempK: colorTempK ?? this.colorTempK,
      watermarkColor: watermarkColor ?? this.watermarkColor,
      watermarkPosition: clearWatermarkOverrides
          ? null
          : (watermarkPosition ?? this.watermarkPosition),
      watermarkSize: clearWatermarkOverrides
          ? null
          : (watermarkSize ?? this.watermarkSize),
      watermarkDirection: clearWatermarkOverrides
          ? null
          : (watermarkDirection ?? this.watermarkDirection),
      watermarkStyle: clearWatermarkOverrides
          ? null
          : (watermarkStyle ?? this.watermarkStyle),
      frameBackgroundColor: frameBackgroundColor ?? this.frameBackgroundColor,
      activePanel: clearPanel ? null : (activePanel ?? this.activePanel),
      gridEnabled: gridEnabled ?? this.gridEnabled,
      showTopMenu: showTopMenu ?? this.showTopMenu,
      showCameraManager: showCameraManager ?? this.showCameraManager,
      flashMode: flashMode ?? this.flashMode,
      timerSeconds: timerSeconds ?? this.timerSeconds,
      isFrontCamera: isFrontCamera ?? this.isFrontCamera,
      isTakingPhoto: isTakingPhoto ?? this.isTakingPhoto,
      showCaptureFlash: showCaptureFlash ?? this.showCaptureFlash,
      smallFrameMode: smallFrameMode ?? this.smallFrameMode,
      sharpenLevel: sharpenLevel ?? this.sharpenLevel,
      zoomLevel: zoomLevel ?? this.zoomLevel,
      showZoomSlider: showZoomSlider ?? this.showZoomSlider,
      minimapEnabled: minimapEnabled ?? this.minimapEnabled,
      locationEnabled: locationEnabled ?? this.locationEnabled,
      showDebugOverlay: showDebugOverlay ?? this.showDebugOverlay,
      shutterSoundEnabled: shutterSoundEnabled ?? this.shutterSoundEnabled,
      mirrorFrontCamera: mirrorFrontCamera ?? this.mirrorFrontCamera,
      mirrorBackCamera: mirrorBackCamera ?? this.mirrorBackCamera,
      shutterVibrationEnabled:
          shutterVibrationEnabled ?? this.shutterVibrationEnabled,
      fisheyeMode: fisheyeMode ?? this.fisheyeMode,
      livePhotoEnabled: livePhotoEnabled ?? this.livePhotoEnabled,
      saveOriginalEnabled: saveOriginalEnabled ?? this.saveOriginalEnabled,
      doubleExpEnabled: doubleExpEnabled ?? this.doubleExpEnabled,
      doubleExpFirstPath: clearDoubleExpFirst
          ? null
          : (doubleExpFirstPath ?? this.doubleExpFirstPath),
      doubleExpBlend: doubleExpBlend ?? this.doubleExpBlend,
      burstCount: burstCount ?? this.burstCount,
      burstProgress: burstProgress ?? this.burstProgress,
      isBursting: isBursting ?? this.isBursting,
      lastCaptureRaw: lastCaptureRaw ?? this.lastCaptureRaw,
      lastCaptureOutput: lastCaptureOutput ?? this.lastCaptureOutput,
      runtimeDeviceBrand: runtimeDeviceBrand ?? this.runtimeDeviceBrand,
      runtimeDeviceModel: runtimeDeviceModel ?? this.runtimeDeviceModel,
      runtimeCameraId: runtimeCameraId ?? this.runtimeCameraId,
      runtimeSensorMp: runtimeSensorMp ?? this.runtimeSensorMp,
      runtimeRtLightIndex: runtimeRtLightIndex ?? this.runtimeRtLightIndex,
      runtimeRtIso: runtimeRtIso ?? this.runtimeRtIso,
      runtimeRtExposureMs: runtimeRtExposureMs ?? this.runtimeRtExposureMs,
      runtimeRtLuma: runtimeRtLuma ?? this.runtimeRtLuma,
      renderStyleMode: renderStyleMode ?? this.renderStyleMode,
      previewPerformanceMode:
          previewPerformanceMode ?? this.previewPerformanceMode,
    );
  }

  // ── Convenience getters ──

  FilterDefinition? get activeFilter => camera?.filterById(activeFilterId);
  LensDefinition? get activeLens => camera?.lensById(activeLensId);
  RatioDefinition? get activeRatio => camera?.ratioById(activeRatioId);
  FrameDefinition? get activeFrame => camera?.frameById(activeFrameId);
  WatermarkPreset? get activeWatermark =>
      camera?.watermarkById(activeWatermarkId);

  PreviewRenderParams? get renderParams {
    if (camera == null) return null;
    return PreviewRenderParams(
      defaultLook: camera!.defaultLook,
      activeFilter: activeFilter,
      activeLens: activeLens,
      temperatureOffset: temperatureOffset,
      exposureOffset: exposureValue,
      beautyStrength: beautyStrength,
      policy: camera!.previewPolicy,
      cameraId: camera!.id,
      wbMode: wbMode,
      colorTempK: colorTempK,
      isFrontCamera: isFrontCamera,
      runtimeDeviceBrand: runtimeDeviceBrand,
      runtimeDeviceModel: runtimeDeviceModel,
      runtimeCameraId: runtimeCameraId,
      runtimeSensorMp: runtimeSensorMp,
      rtLightIndex: runtimeRtLightIndex,
      rtIso: runtimeRtIso,
      rtExposureMs: runtimeRtExposureMs,
      rtLuma: runtimeRtLuma,
      renderStyleMode: renderStyleMode,
    );
  }

  double get previewAspectRatio {
    final ratio = activeRatio;
    if (ratio == null) return 3 / 4;
    return ratio.width / ratio.height;
  }

  String get previewResolutionTag {
    return sharpenLevel == 0 ? '720p' : '1080p';
  }

  String get lensLabel {
    // Use the camera's focalLengthLabel (e.g. "28mm"), falling back to lens nameEn
    final fll = camera?.focalLengthLabel;
    if (fll != null && fll.isNotEmpty) return fll;
    final lens = activeLens;
    if (lens == null) return '35mm';
    return lens.nameEn;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CameraAppNotifier
// ─────────────────────────────────────────────────────────────────────────────

class CameraAppNotifier extends StateNotifier<CameraAppState> {
  final Ref _ref;
  static const Duration _kRenderParamsPushInterval = Duration(milliseconds: 33);
  static const Duration _kZoomPushInterval = Duration(milliseconds: 16);
  static const Duration _kViewportRatioPushInterval =
      Duration(milliseconds: 80);
  Timer? _renderParamsPushTimer;
  Timer? _zoomPushTimer;
  Timer? _viewportRatioPushTimer;
  double? _pendingZoomToNative;
  int _renderParamsVersion = 0;
  int _lastAckedRenderParamsVersion = 0;
  Future<void>? _cameraSwitchTask;
  String? _queuedCameraId;
  bool _viewportRatioSyncQueued = false;
  bool _isViewportRatioSyncInFlight = false;

  CameraAppNotifier(this._ref) : super(const CameraAppState());

  bool get _supportsLivePhotoForCurrentSelection {
    final deviceSupports = _ref.read(cameraServiceProvider).supportsLivePhoto;
    if (!deviceSupports) return false;
    final camera = state.camera;
    if (camera == null || !camera.supportsLivePhoto) return false;
    final lens = camera.lensById(state.activeLensId);
    return !(lens?.fisheyeMode ?? false);
  }

  double _toDouble(dynamic raw, [double fallback = -1.0]) {
    if (raw is num) return raw.toDouble();
    if (raw == null) return fallback;
    return double.tryParse(raw.toString()) ?? fallback;
  }

  void syncRuntimeColorContext([Map<String, dynamic>? debugInfoOverride]) {
    final info = debugInfoOverride ??
        _ref.read(cameraServiceProvider).activeCameraDebugInfo;
    final sensorMp = _toDouble(info['sensorMp'], state.runtimeSensorMp);
    final brand = (info['brand']?.toString() ?? '').trim().toLowerCase();
    final model = (info['model']?.toString() ?? '').trim();
    final cameraId = (info['cameraId']?.toString() ?? '').trim();
    final rtLightIndex =
        _toDouble(info['rtLightIndex'], state.runtimeRtLightIndex);
    final rtIso = _toDouble(info['rtIso'], state.runtimeRtIso);
    final rtExposureMs =
        _toDouble(info['rtExposureMs'], state.runtimeRtExposureMs);
    final rtLuma = _toDouble(info['rtLuma'], state.runtimeRtLuma);
    final fallbackBrand = Platform.isIOS ? 'apple' : '';
    final fallbackModel = Platform.isIOS ? 'iphone' : '';

    final nextBrand = brand.isNotEmpty ? brand : fallbackBrand;
    final nextModel = model.isNotEmpty ? model : fallbackModel;
    if (nextBrand == state.runtimeDeviceBrand &&
        nextModel == state.runtimeDeviceModel &&
        cameraId == state.runtimeCameraId &&
        (sensorMp - state.runtimeSensorMp).abs() < 0.001 &&
        (rtLightIndex - state.runtimeRtLightIndex).abs() < 0.001 &&
        (rtIso - state.runtimeRtIso).abs() < 0.001 &&
        (rtExposureMs - state.runtimeRtExposureMs).abs() < 0.001 &&
        (rtLuma - state.runtimeRtLuma).abs() < 0.001) {
      return;
    }
    state = state.copyWith(
      runtimeDeviceBrand: nextBrand,
      runtimeDeviceModel: nextModel,
      runtimeCameraId: cameraId,
      runtimeSensorMp: sensorMp,
      runtimeRtLightIndex: rtLightIndex,
      runtimeRtIso: rtIso,
      runtimeRtExposureMs: rtExposureMs,
      runtimeRtLuma: rtLuma,
    );
    _applyCurrentRenderParamsToNative(throttled: true);
  }

  /// Initialize: 从持久化读取上次选择的相机和全局设置
  Future<void> initialize({String? initialCameraId}) async {
    final prefs = await AppPrefsService.instance.load();
    final requestedCameraId = (initialCameraId ?? '').trim();
    final launchCameraId = kAllCameras.any((e) => e.id == requestedCameraId)
        ? requestedCameraId
        : prefs.lastCameraId;
    // 先将持久化的全局设置写入 state（在 _loadCamera 之前，避免被覆盖）
    state = state.copyWith(
      sharpenLevel: prefs.sharpenLevel,
      gridEnabled: prefs.gridEnabled,
      minimapEnabled: prefs.minimapEnabled,
      shutterSoundEnabled: prefs.shutterSoundEnabled,
      shutterVibrationEnabled: prefs.shutterVibrationEnabled,
      locationEnabled: prefs.locationEnabled,
      mirrorFrontCamera: prefs.mirrorFrontCamera,
      mirrorBackCamera: prefs.mirrorBackCamera,
      renderStyleMode: prefs.renderStyleMode,
      previewPerformanceMode: prefs.previewPerformanceMode,
      beautyStrength: prefs.beautyStrength,
      beautyCustomized: prefs.beautyCustomized,
      saveOriginalEnabled: prefs.saveOriginalEnabled,
    );
    await _ref
        .read(cameraServiceProvider.notifier)
        .setMirrorFrontCamera(prefs.mirrorFrontCamera);
    await _ref
        .read(cameraServiceProvider.notifier)
        .setMirrorBackCamera(prefs.mirrorBackCamera);
    syncRuntimeColorContext();
    if (launchCameraId != prefs.lastCameraId) {
      await AppPrefsService.instance.setLastCameraId(launchCameraId);
    }
    await _loadCamera(launchCameraId);
  }

  /// Switch to a different camera by id
  Future<void> switchToCamera(String cameraId) async {
    // 持久化最后选择的相机
    await AppPrefsService.instance.setLastCameraId(cameraId);
    // 只有当 camera 对象已加载且 id 匹配时才 early return
    // 不能用 activeCameraId 判断，因为 _loadCamera 第一行就设置了 activeCameraId
    // 导致 camera 还是旧相机时就误判为「已加载」
    if (state.camera != null && state.camera!.id == cameraId) {
      // Already loaded, just close manager
      state = state.copyWith(showCameraManager: false, clearPanel: true);
      return;
    }
    _queuedCameraId = cameraId;
    while (true) {
      var task = _cameraSwitchTask;
      if (task == null) {
        task = _drainCameraSwitchQueue();
        _cameraSwitchTask = task;
      }
      await task;
      if (_cameraSwitchTask == null && _queuedCameraId == null) {
        break;
      }
    }
    state = state.copyWith(showCameraManager: false);
  }

  Future<void> _drainCameraSwitchQueue() async {
    try {
      while (true) {
        final nextCameraId = _queuedCameraId;
        _queuedCameraId = null;
        if (nextCameraId == null) {
          break;
        }
        if (state.camera != null && state.camera!.id == nextCameraId) {
          continue;
        }
        // 切换前：保存当前相机的设定快照（供下次切回时恢复）
        await _saveCurrentSnapshot();
        await _loadCamera(nextCameraId);
      }
    } finally {
      _cameraSwitchTask = null;
    }
  }

  /// 保存当前相机设定快照到 RetainSettingsService
  Future<void> _saveCurrentSnapshot() async {
    final retainNotifier = _ref.read(retainSettingsProvider.notifier);
    await retainNotifier.saveSnapshot(
      state.activeCameraId,
      CameraSnapshot(
        temperatureOffset: state.temperatureOffset,
        colorTempK: state.colorTempK,
        wbMode: state.wbMode,
        exposureValue: state.exposureValue,
        zoomLevel: state.zoomLevel,
        frameId: state.activeFrameId,
      ),
    );
  }

  Future<void> _loadCamera(String cameraId) async {
    state = state.copyWith(
        isLoading: true, clearError: true, activeCameraId: cameraId);
    try {
      final camera = await loadCamera(cameraId);
      final defaults = camera.defaultSelection;

      // 读取保留设定开关和该相机的快照
      final retainState = _ref.read(retainSettingsProvider);
      final retainNotifier = _ref.read(retainSettingsProvider.notifier);
      final snapshot = await retainNotifier.loadSnapshot(cameraId);

      // 根据各开关决定是否恢复设定，无快照则使用默认值
      final double tempOffset =
          (retainState.retainTemperature && snapshot != null)
              ? snapshot.temperatureOffset
              : 0;
      final int colorK = (retainState.retainTemperature && snapshot != null)
          ? snapshot.colorTempK
          : 6300;
      final String wbMode = (retainState.retainTemperature && snapshot != null)
          ? snapshot.wbMode
          : 'auto';
      final double exposure = (retainState.retainExposure && snapshot != null)
          ? snapshot.exposureValue
          : 0;
      final double zoom = (retainState.retainZoom && snapshot != null)
          ? snapshot.zoomLevel
          : 1.0;
      // retainFrame 开启时：有快照则恢复快照值（含 null=关闭相框）；无快照则用默认值
      // retainFrame 关闭时：始终使用 defaults.frameId
      // FIX: 恢复 frameId 时必须检查当前相机是否支持该 frame，以及当前 ratio 是否兼容
      String? frameId;
      if (retainState.retainFrame && snapshot != null) {
        frameId = snapshot.frameId;
      } else {
        frameId = defaults.frameId;
      }
      // 验证 frameId 在当前相机中存在（非拍立得相机的 frames 为空，frameId 会被清空）
      if (frameId != null && camera.frameById(frameId) == null) {
        frameId = null;
      }
      // 验证 frame 支持当前 ratio（如 2:3 比例下拍立得相框不可用）
      if (frameId != null) {
        final frame = camera.frameById(frameId);
        if (frame != null &&
            frame.supportedRatios.isNotEmpty &&
            !frame.supportedRatios.contains(defaults.ratioId)) {
          frameId = null;
        }
      }

      final defaultLens = camera.lensById(defaults.lensId);
      final nextFisheyeMode = defaultLens?.fisheyeMode ?? false;
      state = state.copyWith(
        camera: camera,
        isLoading: false,
        activeCameraId: cameraId,
        activeFilterId: defaults.filterId,
        activeLensId: defaults.lensId,
        activeRatioId: defaults.ratioId,
        activeFrameId: frameId,
        // copyWith 的 nullable 语义会在传入 null 时保留旧值，
        // 切机到默认关闭相框的相机时必须显式清空，避免沿用上一台相机的 frameId。
        clearFrameId: frameId == null,
        activeWatermarkId: defaults.watermarkPresetId,
        temperatureOffset: tempOffset,
        exposureValue: exposure,
        zoomLevel: zoom,
        colorTempK: colorK,
        wbMode: wbMode,
        fisheyeMode: nextFisheyeMode,
        // 切换相机后统一关闭 live photo，避免沿用上一台相机的开启状态。
        livePhotoEnabled: false,
        clearPanel: true,
      );
      // 关键修复：加载相机后立即将 defaultLook 色彩参数同步到原生 GPU shader
      // 修复 FQS 紫色偏色问题：确保 colorBiasR/G/B、grainSize、sharpness 等专用字段正确传递
      await _syncCameraStateToNative(camera: camera);
    } catch (e) {
      state =
          state.copyWith(isLoading: false, error: 'Failed to load camera: $e');
    }
  }

  // ── Panel management ──

  void togglePanel(String panelId) {
    if (state.activePanel == panelId) {
      state = state.copyWith(
          clearPanel: true, showTopMenu: false, showCameraManager: false);
    } else {
      state = state.copyWith(
          activePanel: panelId, showTopMenu: false, showCameraManager: false);
    }
  }

  void closeAllPanels() {
    state = state.copyWith(
        clearPanel: true, showTopMenu: false, showCameraManager: false);
  }

  void toggleTopMenu() {
    state = state.copyWith(
      showTopMenu: !state.showTopMenu,
      clearPanel: true,
      showCameraManager: false,
    );
  }

  void toggleCameraManager() {
    state = state.copyWith(
      showCameraManager: !state.showCameraManager,
      clearPanel: true,
      showTopMenu: false,
    );
  }

  // ── Selection setters ──

  void selectFilter(String id) {
    state = state.copyWith(activeFilterId: id);
    // ── FIX: 滤镜切换后必须将更新后的渲染参数发送到原生预览 Shader ──
    // 之前只更新了 Dart state，原生 Shader 完全不知道滤镜变了。
    // 滤镜影响 contrast、saturation、grain、grainSize、vignette、sharpness、halation，
    // 这些参数通过 renderParams 组合后需要重新发送。
    _applyCurrentRenderParamsToNative();
  }

  void selectLens(String id) {
    // 反选：再次点击已激活的镜头时，回到相机默认镜头
    final defaultLensId = state.camera?.defaultSelection.lensId ?? 'std';
    final String newLensId;
    if (state.activeLensId == id && id != defaultLensId) {
      newLensId = defaultLensId;
    } else {
      newLensId = id;
    }
    final newLens = state.camera?.lensById(newLensId);
    final fisheyeMode = newLens?.fisheyeMode ?? false;
    state = state.copyWith(
      activeLensId: newLensId,
      fisheyeMode: fisheyeMode,
      livePhotoEnabled: fisheyeMode ? false : state.livePhotoEnabled,
    );
    // ── FIX: 将所有镜头参数发送到原生层（之前只发了 fisheyeMode 和 vignette）──
    _ref.read(cameraServiceProvider.notifier).updateLensParams(
          distortion: newLens?.distortion ?? 0.0,
          vignette: newLens?.vignette ?? 0.0,
          zoomFactor: newLens?.zoomFactor ?? 1.0,
          fisheyeMode: fisheyeMode,
          circularFisheye: newLens?.circularFisheyeCrop ?? fisheyeMode,
          chromaticAberration: newLens?.chromaticAberration ?? 0.0,
          bloom: newLens?.bloom ?? 0.0,
          softFocus: newLens?.softFocus ?? 0.0,
          exposure: newLens?.exposure ?? 0.0,
          contrast: newLens?.contrast ?? 0.0,
          saturation: newLens?.saturation ?? 0.0,
          highlightCompression: newLens?.highlightCompression ?? 0.0,
        );
    // ── FIX: 镜头切换后也重发完整渲染参数（镜头影响 contrast、saturation、vignette 等组合值）──
    _applyCurrentRenderParamsToNative();
  }

  bool _applyRatioSelection(String id) {
    if (state.activeRatioId == id) return false;
    // 如果切换到不支持相框的比例，自动清除当前相框选择
    final camera = state.camera;
    if (camera != null && state.activeFrameId != null) {
      final ratio = camera.modules.ratios.where((r) => r.id == id).firstOrNull;
      if (ratio != null && !ratio.supportsFrame) {
        state = state.copyWith(activeRatioId: id, clearFrameId: true);
        return true;
      }
      // 当前相框不支持新比例时也自动清除
      final frameOpt = camera.modules.frames
          .where((f) => f.id == state.activeFrameId)
          .firstOrNull;
      if (frameOpt != null &&
          frameOpt.supportedRatios.isNotEmpty &&
          !frameOpt.supportedRatios.contains(id)) {
        state = state.copyWith(activeRatioId: id, clearFrameId: true);
        return true;
      }
    }
    state = state.copyWith(activeRatioId: id);
    return true;
  }

  void selectRatio(String id) {
    if (!_applyRatioSelection(id)) return;
    _scheduleViewportRatioSync();
  }

  Future<void> selectRatioAndSync(String id) async {
    if (!_applyRatioSelection(id)) return;
    await _syncViewportRatioToNativeImmediately();
  }

  void selectFrame(String id) {
    if (state.livePhotoEnabled && id != 'frame_none' && id != 'none') {
      return;
    }
    // 'none' 和 'frame_none' 都表示无边框，用 clearFrameId=true 真正清空 activeFrameId
    if (id == 'frame_none' || id == 'none') {
      state = state.copyWith(clearFrameId: true);
    } else {
      state = state.copyWith(activeFrameId: id);
    }
  }

  void selectWatermark(String id) {
    if (state.livePhotoEnabled && id != 'none') {
      return;
    }
    // 切换预设时清空用户覆盖（使新预设的默认配置生效）
    state =
        state.copyWith(activeWatermarkId: id, clearWatermarkOverrides: true);
  }

  void selectWatermarkColor(String hexColor) {
    state = state.copyWith(watermarkColor: hexColor);
  }

  void setWatermarkPosition(String position) {
    state = state.copyWith(watermarkPosition: position);
  }

  void setWatermarkSize(String size) {
    state = state.copyWith(watermarkSize: size);
  }

  void setWatermarkDirection(String direction) {
    state = state.copyWith(watermarkDirection: direction);
  }

  void setWatermarkStyle(String styleId) {
    state = state.copyWith(watermarkStyle: styleId);
  }

  void setShutterSoundEnabled(bool enabled) {
    state = state.copyWith(shutterSoundEnabled: enabled);
    AppPrefsService.instance.setShutterSoundEnabled(enabled);
  }

  void setMirrorFrontCamera(bool enabled) {
    state = state.copyWith(mirrorFrontCamera: enabled);
    AppPrefsService.instance.setMirrorFrontCamera(enabled);
    _ref.read(cameraServiceProvider.notifier).setMirrorFrontCamera(enabled);
  }

  void setMirrorBackCamera(bool enabled) {
    state = state.copyWith(mirrorBackCamera: enabled);
    AppPrefsService.instance.setMirrorBackCamera(enabled);
    _ref.read(cameraServiceProvider.notifier).setMirrorBackCamera(enabled);
  }

  void setShutterVibrationEnabled(bool enabled) {
    state = state.copyWith(shutterVibrationEnabled: enabled);
    AppPrefsService.instance.setShutterVibrationEnabled(enabled);
  }

  void setLocationEnabled(bool enabled) {
    state = state.copyWith(locationEnabled: enabled);
    AppPrefsService.instance.setLocationEnabled(enabled);
  }

  bool setSaveOriginalEnabled(bool enabled) {
    if (enabled && state.livePhotoEnabled) {
      return false;
    }
    state = state.copyWith(saveOriginalEnabled: enabled);
    AppPrefsService.instance.setSaveOriginalEnabled(enabled);
    return true;
  }

  int beautyLevelForStrength(double value) {
    if (value <= 0.0) return 0;
    if (value < 0.5) return 1;
    if (value < 0.85) return 2;
    return 3;
  }

  void cycleBeautyLevel() {
    const levels = [0.0, 0.35, 0.65, 1.0];
    final current = beautyLevelForStrength(state.beautyStrength);
    final next = (current + 1) % levels.length;
    setBeautyStrength(levels[next]);
  }

  void setRenderStyleMode(RenderStyleMode mode) {
    if (state.renderStyleMode == mode) return;
    state = state.copyWith(renderStyleMode: mode);
    AppPrefsService.instance.setRenderStyleMode(mode);
    _applyCurrentRenderParamsToNative();
  }

  void setPreviewPerformanceMode(PreviewPerformanceMode mode) {
    if (state.previewPerformanceMode == mode) return;
    state = state.copyWith(previewPerformanceMode: mode);
    AppPrefsService.instance.setPreviewPerformanceMode(mode);
    _applyCurrentRenderParamsToNative();
  }

  void selectFrameBackground(String hexColor) {
    state = state.copyWith(frameBackgroundColor: hexColor);
  }

  /// Alias for switchToCamera (used by CameraConfigSheet)
  Future<void> switchCamera(String cameraId) => switchToCamera(cameraId);

  /// 供外部（如 AppLifecycle 监听）调用，保存当前相机快照
  Future<void> saveCurrentSnapshot() => _saveCurrentSnapshot();

  @override
  void dispose() {
    _renderParamsPushTimer?.cancel();
    _zoomPushTimer?.cancel();
    _viewportRatioPushTimer?.cancel();
    // Notifier 销毁时尝试保存快照（App 退出 / Provider 被释放时触发）
    // 注意：dispose 被调用时 ProviderContainer 可能已在销毁过程中，
    // _ref.read 会抛出 "Bad state: Tried to read a provider from a ProviderContainer that was already disposed"
    // 因此不能调用 _saveCurrentSnapshot()（内部使用 _ref.read），
    // 改为直接用 SharedPreferences 保存，完全绕过 _ref
    _saveSnapshotDirect().catchError((_) {
      // 忽略任何保存失败（如 SharedPreferences 未初始化）
    });
    super.dispose();
  }

  /// 直接通过 SharedPreferences 保存当前相机快照，不依赖 _ref（供 dispose 调用）
  Future<void> _saveSnapshotDirect() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'camera_snapshot_${state.activeCameraId}',
        jsonEncode(CameraSnapshot(
          temperatureOffset: state.temperatureOffset,
          colorTempK: state.colorTempK,
          wbMode: state.wbMode,
          exposureValue: state.exposureValue,
          zoomLevel: state.zoomLevel,
          frameId: state.activeFrameId,
        ).toJson()),
      );
    } catch (_) {
      // 忽略保存失败
    }
  }

  // ── Camera controls ──

  void setTemperature(double value) {
    state = state.copyWith(temperatureOffset: value);
  }

  void setExposure(double value) {
    state = state.copyWith(exposureValue: value);
    // FIX: 通知原生 GPU shader 更新曝光（预览由原生渲染，必须同步）
    _applyCurrentRenderParamsToNative(throttled: true);
  }

  void setBeautyStrength(double value) {
    final clamped = value.clamp(0.0, 1.0);
    state = state.copyWith(beautyStrength: clamped, beautyCustomized: true);
    AppPrefsService.instance.setBeautyStrength(clamped);
    AppPrefsService.instance.setBeautyCustomized(true);
    _applyCurrentRenderParamsToNative(throttled: true);
  }

  void _applyAutoBeautyForLens(bool isFrontCamera) {
    if (state.beautyCustomized) return;
    final autoBeauty = isFrontCamera ? 0.2 : 0.0;
    state = state.copyWith(beautyStrength: autoBeauty);
    AppPrefsService.instance.setBeautyStrength(autoBeauty);
  }

  // 设置白平衡预设模式
  // mode: 'auto' | 'daylight' | 'incandescent'
  void setWhiteBalance(String mode) {
    int tempK;
    switch (mode) {
      case 'daylight':
        tempK = 4800;
        break;
      case 'incandescent':
        tempK = 1800;
        break;
      default:
        tempK = 6300;
        break; // auto
    }
    // FIX: 同步更新 temperatureOffset，使成片后处理的颜色矩阵也能读取到白平衡变化
    // temperatureOffset 范围 -100..100，映射规则与 setColorTempK 一致
    final offset =
        mode == 'auto' ? 0.0 : ((tempK - 4800) / 32.0).clamp(-100.0, 100.0);
    state = state.copyWith(
        wbMode: mode, colorTempK: tempK, temperatureOffset: offset);
    // 通知原生层设置白平衡（影响预览）
    _ref.read(cameraServiceProvider.notifier).setWhiteBalance(mode);
    // FIX: 同步更新原生 GPU shader 参数（确保成片与预览一致）
    _applyCurrentRenderParamsToNative();
  }

  // 手动设置色温（滑动条拖动时调用）
  void setColorTempK(int kelvin) {
    state =
        state.copyWith(wbMode: 'manual', colorTempK: kelvin.clamp(1800, 8000));
    // 将 K 值映射到 temperatureOffset（-100..100）供原生层使用
    final offset = ((kelvin - 4800) / 32.0).clamp(-100.0, 100.0);
    state = state.copyWith(temperatureOffset: offset);
  }

  void toggleGrid() {
    final next = !state.gridEnabled;
    state = state.copyWith(gridEnabled: next);
    AppPrefsService.instance.setGridEnabled(next);
  }

  void toggleSmallFrame() {
    state = state.copyWith(smallFrameMode: !state.smallFrameMode);
  }

  // ── Zoom & Minimap ──

  /// 设置缩放倍率（x0.6 ~ x20）并通知原生层
  void setZoom(double zoom) {
    final clamped = zoom.clamp(0.6, 20.0);
    if ((clamped - state.zoomLevel).abs() < 0.001) return;
    state = state.copyWith(zoomLevel: clamped);
    _pushZoomToNative(clamped);
  }

  /// 切换缩放滑动条显示/隐藏
  void toggleZoomSlider() {
    state = state.copyWith(showZoomSlider: !state.showZoomSlider);
  }

  /// 关闭缩放滑动条
  void hideZoomSlider() {
    state = state.copyWith(showZoomSlider: false);
  }

  /// 切换小窗模式（开关时同步将缩放重置为 x1.0）
  void toggleMinimap() {
    final next = !state.minimapEnabled;
    state = state.copyWith(
      minimapEnabled: next,
      zoomLevel: 1.0,
      showZoomSlider: false,
    );
    AppPrefsService.instance.setMinimapEnabled(next);
    _pushZoomToNative(1.0, immediate: true);
  }

  /// 切换位置信息开关
  /// 返回切换后的状态和权限结果
  /// 切换调试信息浮层
  void toggleDebugOverlay() {
    state = state.copyWith(showDebugOverlay: !state.showDebugOverlay);
  }

  // ── 双重曝光 ──────────────────────────────────────────────────────────────

  /// 开关双重曝光模式，开启时清除第一张照片缓存
  void toggleDoubleExp() {
    final next = !state.doubleExpEnabled;
    state = state.copyWith(
      doubleExpEnabled: next,
      livePhotoEnabled: next ? false : state.livePhotoEnabled,
      clearDoubleExpFirst: true, // 切换时清空第一张照片
    );
  }

  void toggleLivePhoto() {
    setLivePhotoEnabled(!state.livePhotoEnabled);
  }

  void setLivePhotoEnabled(
    bool enabled, {
    bool bypassSupportCheck = false,
  }) {
    if (!bypassSupportCheck &&
        enabled &&
        !_supportsLivePhotoForCurrentSelection) {
      state = state.copyWith(livePhotoEnabled: false);
      return;
    }
    final next = enabled;
    if (next && state.saveOriginalEnabled) {
      AppPrefsService.instance.setSaveOriginalEnabled(false);
    }
    state = state.copyWith(
      livePhotoEnabled: next,
      saveOriginalEnabled: next ? false : state.saveOriginalEnabled,
      burstCount: next ? 0 : state.burstCount,
      doubleExpEnabled: next ? false : state.doubleExpEnabled,
      clearDoubleExpFirst: next,
      clearFrameId: next,
      activeWatermarkId: next ? 'none' : state.activeWatermarkId,
    );
    final camera = state.camera;
    if (camera != null) {
      unawaited(_syncCameraStateToNative(camera: camera));
    }
  }

  /// 设置双重曝光第一张照片路径
  void setDoubleExpFirstPath(String path) {
    state = state.copyWith(doubleExpFirstPath: path);
  }

  /// 清除双重曝光第一张照片（重新拍摄）
  void clearDoubleExpFirst() {
    state = state.copyWith(clearDoubleExpFirst: true);
  }

  /// 设置双重曝光混合比例
  void setDoubleExpBlend(double blend) {
    state = state.copyWith(doubleExpBlend: blend.clamp(0.1, 0.9));
  }

  Future<LocationToggleResult> toggleLocation() async {
    if (state.locationEnabled) {
      // 当前开启 → 直接关闭
      state = state.copyWith(locationEnabled: false);
      return LocationToggleResult.disabled;
    }
    // 当前关闭 → 请求权限后开启
    final status = await LocationService.instance.checkStatus();
    if (status == LocationPermissionStatus.deniedForever) {
      return LocationToggleResult.permissionDeniedForever;
    }
    final granted = await LocationService.instance.requestPermission();
    if (!granted) {
      return LocationToggleResult.permissionDenied;
    }
    state = state.copyWith(locationEnabled: true);
    return LocationToggleResult.enabled;
  }

  /// 循环切换清晰度档位（低/中/高）。
  ///
  /// setSharpen 在原生层会重新配置相机分辨率（重建 CameraGLRenderer），
  /// 导致之前设置的所有 GPU shader 参数丢失。
  /// 参考 flipCamera 的处理方式：setSharpen 完成后重新同步完整渲染参数。
  Future<void> cycleSharpen() async {
    final next = (state.sharpenLevel + 1) % 3;
    // 显示加载遇罩（切换分辨率会重建 renderer）
    state = state.copyWith(sharpenLevel: next, isLoading: true);
    AppPrefsService.instance.setSharpenLevel(next);
    // 0=低(0.0), 1=中(0.5), 2=高(1.0)
    const levels = [0.0, 0.5, 1.0];
    final svc = _ref.read(cameraServiceProvider.notifier);

    try {
      // 1. 重新初始化相机（重新获取 textureId，重建 renderer）
      await svc.initCamera(
        resolution: state.previewResolutionTag,
      );

      // 2. 同步相机 shader 参数
      final camera = state.camera;
      if (camera != null) {
        await svc.setCamera(camera);
        // 3. 同步镜头参数
        final lens = camera.lensById(state.activeLensId);
        await svc.updateLensParams(
          distortion: lens?.distortion ?? 0.0,
          vignette: lens?.vignette ?? 0.0,
          zoomFactor: lens?.zoomFactor ?? 1.0,
          fisheyeMode: lens?.fisheyeMode ?? false,
          circularFisheye:
              lens?.circularFisheyeCrop ?? (lens?.fisheyeMode ?? false),
          chromaticAberration: lens?.chromaticAberration ?? 0.0,
          bloom: lens?.bloom ?? 0.0,
          softFocus: lens?.softFocus ?? 0.0,
          exposure: lens?.exposure ?? 0.0,
          contrast: lens?.contrast ?? 0.0,
          saturation: lens?.saturation ?? 0.0,
          highlightCompression: lens?.highlightCompression ?? 0.0,
        );
      }

      // 4. 设置目标分辨率（initCamera 默认用中档，这里覆盖为用户选择的档位）
      await svc.setSharpen(levels[next]);

      // 5. 同步完整渲染参数（滤镜 + defaultLook）
      _applyCurrentRenderParamsToNative();
    } finally {
      // 隐藏加载遇罩（无论成功还是失败）
      state = state.copyWith(isLoading: false);
    }
  }

  void cycleFlash() {
    final modes = ['off', 'on', 'auto'];
    final idx = modes.indexOf(state.flashMode);
    final next = modes[(idx + 1) % modes.length];
    state = state.copyWith(flashMode: next);
    _ref.read(cameraServiceProvider.notifier).setFlash(next);
  }

  void cycleTimer() {
    final options = [0, 3, 10];
    final idx = options.indexOf(state.timerSeconds);
    state = state.copyWith(timerSeconds: options[(idx + 1) % options.length]);
  }

  /// 切换前后置摄像头。
  /// 复用与设置页返回相同的 stopPreview → initCamera → setCamera 路径，
  /// 彻底避免 switchLens 路径下 SurfaceProvider 回调不触发导致 renderer 丢失的问题。
  Future<void> flipCamera() async {
    final svc = _ref.read(cameraServiceProvider.notifier);
    final nextIsFrontCamera = !state.isFrontCamera;

    // 1. 切换前后置标记
    state = state.copyWith(isFrontCamera: nextIsFrontCamera);
    _applyAutoBeautyForLens(nextIsFrontCamera);

    // 2. 停止当前预览（释放旧 renderer + Surface）
    await svc.stopPreview();

    // 3. 切换 lens 方向（仅更新 CameraService 内部状态，不触发原生 switchLens）
    svc.toggleLensDirection();

    // 4. 重新初始化相机（重建 SurfaceTexture + CameraGLRenderer，等待 renderer 就绪）
    await svc.initCamera(
      resolution: state.previewResolutionTag,
    );

    // 5. 重新发送当前相机参数到新 renderer
    final camera = state.camera;
    if (camera != null) {
      await svc.setCamera(camera);
      // 同步镜头参数
      final lens = camera.lensById(state.activeLensId);
      await svc.updateLensParams(
        distortion: lens?.distortion ?? 0.0,
        vignette: lens?.vignette ?? 0.0,
        zoomFactor: lens?.zoomFactor ?? 1.0,
        fisheyeMode: lens?.fisheyeMode ?? false,
        chromaticAberration: lens?.chromaticAberration ?? 0.0,
        bloom: lens?.bloom ?? 0.0,
        softFocus: lens?.softFocus ?? 0.0,
        exposure: lens?.exposure ?? 0.0,
        contrast: lens?.contrast ?? 0.0,
        saturation: lens?.saturation ?? 0.0,
        highlightCompression: lens?.highlightCompression ?? 0.0,
      );
    }

    // 6. 同步清晰度档位
    const sharpenLevels = [0.0, 0.5, 1.0];
    await svc.setSharpen(sharpenLevels[state.sharpenLevel]);

    // 7. 同步完整渲染参数（滤镜+镜头+defaultLook 组合值）
    _applyCurrentRenderParamsToNative();
  }

  // ── Take photo ──

  /// 拍照并保存到相册。
  /// 返回 [TakePhotoResult]，包含缓存文件路径和 MediaStore 资产 ID。
  /// galleryAssetId 可直接用于 AssetEntity.fromId()，完全绕开相册查询逻辑。
  /// [minimapNormalizedRect] 小窗归一化裁剪区域（在取景框内的相对坐标 0.0~1.0）
  Future<TakePhotoResult?> takePhoto(
      {Rect? minimapNormalizedRect, int deviceQuarter = 0}) async {
    if (state.isTakingPhoto) return null;
    syncRuntimeColorContext();
    state = state.copyWith(isTakingPhoto: true);
    HapticFeedback.mediumImpact();
    final totalSw = Stopwatch()..start();
    int captureMs = 0;
    int postMs = 0;
    int exifMs = 0;
    int galleryMs = 0;
    bool postApplied = false;
    bool livePhotoRecordingStarted = false;
    Future<String?>? liveVideoStopFuture;
    String? enhanceSourcePath;
    CameraDefinition? enhanceCamera;
    String enhanceRatioId = '';
    String enhanceFrameId = '';
    String enhanceWatermarkId = '';
    String? enhanceFrameBackgroundColor;
    String? enhanceWatermarkColorOverride;
    String? enhanceWatermarkPositionOverride;
    String? enhanceWatermarkSizeOverride;
    String? enhanceWatermarkDirectionOverride;
    String? enhanceWatermarkStyleOverride;
    PreviewRenderParams? enhanceRenderParams;
    final captureRenderParams = state.renderParams;
    final activeLens = state.camera?.lensById(state.activeLensId ?? '');
    final circularFisheye =
        activeLens?.circularFisheyeCrop ?? state.fisheyeMode;
    final livePhotoActive = state.livePhotoEnabled &&
        _supportsLivePhotoForCurrentSelection &&
        !state.doubleExpEnabled &&
        state.burstCount == 0;
    bool enhanceFisheyeMode = false;
    bool enhanceCircularFisheye = false;
    int enhanceDeviceQuarter = 0;
    Rect? enhanceMinimapRect;
    Position? capturedLocation;
    String? livePhotoVideoPath;
    String? originalCopyPath;

    try {
      if (livePhotoActive && Platform.isAndroid) {
        livePhotoRecordingStarted =
            await _ref.read(cameraServiceProvider.notifier).startRecording();
        if (livePhotoRecordingStarted) {
          await Future.delayed(const Duration(milliseconds: 180));
        }
      }

      String? path;
      int captureW = 0;
      int captureH = 0;
      if (livePhotoActive && Platform.isIOS) {
        if (state.locationEnabled) {
          capturedLocation =
              await LocationService.instance.getCurrentPosition();
        }
        final liveResult =
            await _ref.read(cameraServiceProvider.notifier).captureLivePhoto(
                  deviceQuarter: deviceQuarter,
                  latitude: capturedLocation?.latitude,
                  longitude: capturedLocation?.longitude,
                );
        path = liveResult?['filePath'] as String?;
        livePhotoVideoPath = liveResult?['videoPath'] as String?;
        final liveVideoPath = livePhotoVideoPath;
        if (path == null ||
            path.isEmpty ||
            liveVideoPath == null ||
            liveVideoPath.isEmpty) {
          debugPrint(
              '[CameraNotifier] Live Photo capture missing temp assets: image=$path video=$livePhotoVideoPath');
          return null;
        }
      } else {
        final captureSw = Stopwatch()..start();
        final photoResult = await _ref
            .read(cameraServiceProvider.notifier)
            .takePhoto(deviceQuarter: deviceQuarter);
        captureSw.stop();
        captureMs = captureSw.elapsedMilliseconds;
        path = photoResult?['filePath'] as String?;
        captureW = photoResult?['captureWidth'] as int? ?? 0;
        captureH = photoResult?['captureHeight'] as int? ?? 0;
      }
      debugPrint(
          '[Perf][takePhoto] capture=$captureMs ms raw=${captureW}x$captureH path=${path ?? "null"}');
      if (captureW > 0 && captureH > 0) {
        state = state.copyWith(lastCaptureRaw: '${captureW}×${captureH}');
      }

      if (path != null) {
        if (state.saveOriginalEnabled && !livePhotoActive) {
          try {
            originalCopyPath =
                await OriginalAssetService.instance.saveOriginalCopy(
              path,
              cameraId: state.activeCameraId,
            );
          } catch (e) {
            debugPrint('[CameraNotifier] save original copy failed: $e');
          }
        }
        state = state.copyWith(showCaptureFlash: true);
        // 视觉闪光异步关闭，避免固定 150ms 阻塞拍照主链路。
        unawaited(Future<void>.delayed(const Duration(milliseconds: 150), () {
          if (!mounted) return;
          state = state.copyWith(showCaptureFlash: false);
        }));
        HapticFeedback.lightImpact();

        // 如果开启位置，并行获取 GPS 坐标（与后处理并行，不阻塞流程）
        Future<Position?>? locationFuture;
        if (state.locationEnabled && capturedLocation == null) {
          locationFuture = LocationService.instance.getCurrentPosition();
        }

        // PR2: 中画质先快拍，再后台增强替换同一相册资产（仅 Android 普通单拍）。
        final enableBgEnhance = _kEnableBackgroundEnhanceReplace &&
            Platform.isAndroid &&
            !livePhotoActive &&
            !state.doubleExpEnabled &&
            state.sharpenLevel == 1 &&
            minimapNormalizedRect == null &&
            state.camera != null;
        if (enableBgEnhance) {
          try {
            final tmpDir = Directory.systemTemp;
            final sourcePath =
                '${tmpDir.path}/dazz_bg_enh_src_${DateTime.now().millisecondsSinceEpoch}.jpg';
            await File(path).copy(sourcePath);
            enhanceSourcePath = sourcePath;
            enhanceCamera = state.camera;
            enhanceRatioId = state.activeRatioId ?? '';
            enhanceFrameId = state.activeFrameId ?? '';
            enhanceWatermarkId = state.activeWatermarkId ?? '';
            enhanceFrameBackgroundColor = state.frameBackgroundColor;
            enhanceWatermarkColorOverride = state.watermarkColor;
            enhanceWatermarkPositionOverride = state.watermarkPosition;
            enhanceWatermarkSizeOverride = state.watermarkSize;
            enhanceWatermarkDirectionOverride = state.watermarkDirection;
            enhanceWatermarkStyleOverride = state.watermarkStyle;
            enhanceRenderParams = captureRenderParams;
            enhanceFisheyeMode = state.fisheyeMode;
            enhanceCircularFisheye = circularFisheye;
            enhanceDeviceQuarter = deviceQuarter;
            enhanceMinimapRect = minimapNormalizedRect;
            debugPrint(
                '[CameraNotifier] BG enhance source prepared: $sourcePath');
          } catch (e) {
            debugPrint('[CameraNotifier] BG enhance source copy failed: $e');
          }
        }

        if (livePhotoRecordingStarted) {
          liveVideoStopFuture = Future<String?>.delayed(
            const Duration(milliseconds: 1170),
            () => _ref.read(cameraServiceProvider.notifier).stopRecording(),
          );
        }

        // Post-process: color effects + ratio crop + frame + watermark
        if (state.camera != null) {
          final postSw = Stopwatch()..start();
          try {
            debugPrint(
                '[CameraNotifier] Starting post-process: ratio=${state.activeRatioId}, frame=${state.activeFrameId}, wm=${state.activeWatermarkId}');
            final pipeline = CapturePipeline(camera: state.camera!);
            // 按清晰度档位选择输出尺寸和 JPEG 质量，并做超高像素机型自适应。
            int maxDim = switch (state.sharpenLevel) {
              0 => CapturePipeline.kMaxDimLow,
              2 => CapturePipeline.kMaxDimHigh,
              _ => CapturePipeline.kMaxDimMid,
            };
            int jpegQ = switch (state.sharpenLevel) {
              0 => CapturePipeline.kJpegQualityLow,
              2 => CapturePipeline.kJpegQualityHigh,
              _ => CapturePipeline.kJpegQualityMid,
            };
            final hasOverlay = (state.activeFrameId?.isNotEmpty == true &&
                    state.activeFrameId != 'frame_none' &&
                    state.activeFrameId != 'none') ||
                (state.activeWatermarkId?.isNotEmpty == true &&
                    state.activeWatermarkId != 'none');
            final rawPixels = captureW * captureH;
            // 自适应策略：当原始输入非常大且有相框/水印时，适度下调输出档位以提升稳定速度。
            if (hasOverlay &&
                rawPixels >= 24 * 1000 * 1000 &&
                state.sharpenLevel >= 1) {
              maxDim = maxDim.clamp(0, 3072).toInt();
              jpegQ = (jpegQ - 2).clamp(70, 95).toInt();
              debugPrint(
                  '[CameraNotifier] adaptive quality applied: raw=${captureW}x$captureH maxDim=$maxDim jpegQ=$jpegQ');
            }

            // ── 双重曝光处理逻辑 ──────────────────────────────────────────────────────────────
            if (state.doubleExpEnabled) {
              final firstPath = state.doubleExpFirstPath;
              if (firstPath == null) {
                // 第一张：仅做单张后处理，不合成，保存到临时目录
                final processed = await pipeline.process(
                  imagePath: path,
                  selectedRatioId: state.activeRatioId ?? '',
                  selectedFrameId: 'frame_none', // 第一张不加相框
                  selectedWatermarkId: 'none', // 第一张不加水印
                  renderParams: captureRenderParams,
                  minimapNormalizedRect: minimapNormalizedRect,
                  deviceQuarter: deviceQuarter,
                  maxDimension: maxDim,
                  jpegQuality: jpegQ,
                  fisheyeMode: state.fisheyeMode,
                  circularFisheye: circularFisheye,
                );
                if (processed != null) {
                  // 将处理后的第一张写入临时文件
                  final tmpDir = Directory.systemTemp;
                  final firstSavePath =
                      '${tmpDir.path}/dazz_double_exp_first_${DateTime.now().millisecondsSinceEpoch}.jpg';
                  await File(firstSavePath).writeAsBytes(processed.bytes);
                  state = state.copyWith(doubleExpFirstPath: firstSavePath);
                  debugPrint('[DoubleExp] First photo saved: $firstSavePath');
                }
                // 第一张不保存到相册，直接返回 null
                state = state.copyWith(isTakingPhoto: false);
                return null;
              } else {
                // 第二张：合成两张照片
                String? tmpBlendPath;
                try {
                  final processed2 = await pipeline.process(
                    imagePath: path,
                    selectedRatioId: state.activeRatioId ?? '',
                    selectedFrameId: 'frame_none',
                    selectedWatermarkId: 'none',
                    renderParams: captureRenderParams,
                    minimapNormalizedRect: minimapNormalizedRect,
                    deviceQuarter: deviceQuarter,
                    maxDimension: maxDim,
                    jpegQuality: jpegQ,
                    fisheyeMode: state.fisheyeMode,
                    circularFisheye: circularFisheye,
                  );
                  if (processed2 != null) {
                    // 合成两张照片
                    final blended = await CapturePipeline.blendDoubleExposure(
                      firstImagePath: firstPath,
                      secondImageBytes: processed2.bytes,
                      blend: state.doubleExpBlend,
                    );
                    if (blended != null) {
                      // 将合成结果再过一遍完整的 pipeline（加相框、水印等）
                      tmpBlendPath =
                          '${Directory.systemTemp.path}/dazz_blend_${DateTime.now().millisecondsSinceEpoch}.jpg';
                      await File(tmpBlendPath).writeAsBytes(blended);
                      final finalProcessed = await pipeline.process(
                        imagePath: tmpBlendPath,
                        selectedRatioId: state.activeRatioId ?? '',
                        selectedFrameId: state.activeFrameId ?? '',
                        selectedWatermarkId: state.activeWatermarkId ?? '',
                        frameBackgroundColor: state.frameBackgroundColor,
                        watermarkColorOverride: state.watermarkColor,
                        watermarkPositionOverride: state.watermarkPosition,
                        watermarkSizeOverride: state.watermarkSize,
                        watermarkDirectionOverride: state.watermarkDirection,
                        watermarkStyleOverride: state.watermarkStyle,
                        renderParams: null, // 已经应用过滞色矩阵，不重复
                        deviceQuarter: 0, // 已经旋转过
                        maxDimension: maxDim,
                        jpegQuality: jpegQ,
                        fisheyeMode: state.fisheyeMode,
                        circularFisheye: circularFisheye,
                      );
                      if (finalProcessed != null) {
                        await File(path).writeAsBytes(finalProcessed.bytes);
                        state = state.copyWith(
                          lastCaptureOutput:
                              '${finalProcessed.outputWidth}×${finalProcessed.outputHeight}',
                        );
                      } else {
                        await File(path).writeAsBytes(blended);
                      }
                    }
                  }
                } finally {
                  if (tmpBlendPath != null) {
                    try {
                      File(tmpBlendPath).deleteSync();
                    } catch (_) {}
                  }
                  // 无论成功与否都清理第一张临时文件，避免残留
                  try {
                    File(firstPath).deleteSync();
                  } catch (_) {}
                }
                // 合成完成，关闭双重曝光模式
                state = state.copyWith(
                  doubleExpEnabled: false,
                  clearDoubleExpFirst: true,
                );
                debugPrint(
                    '[DoubleExp] Blend complete, double exp mode closed');
              }
            } else {
              // 普通拍照流程
              final processed = await pipeline.process(
                imagePath: path,
                selectedRatioId: state.activeRatioId ?? '',
                selectedFrameId: state.activeFrameId ?? '',
                selectedWatermarkId: state.activeWatermarkId ?? '',
                frameBackgroundColor: state.frameBackgroundColor,
                watermarkColorOverride: state.watermarkColor,
                watermarkPositionOverride: state.watermarkPosition,
                watermarkSizeOverride: state.watermarkSize,
                watermarkDirectionOverride: state.watermarkDirection,
                watermarkStyleOverride: state.watermarkStyle,
                renderParams: captureRenderParams,
                minimapNormalizedRect: minimapNormalizedRect,
                deviceQuarter: deviceQuarter,
                maxDimension: maxDim,
                jpegQuality: jpegQ,
                fisheyeMode: state.fisheyeMode,
                circularFisheye: circularFisheye,
              );
              if (processed != null) {
                await File(path).writeAsBytes(processed.bytes);
                state = state.copyWith(
                  lastCaptureOutput:
                      '${processed.outputWidth}×${processed.outputHeight}',
                );
                debugPrint(
                    '[CameraNotifier] Post-process done, wrote ${processed.bytes.length} bytes to $path (${processed.outputWidth}x${processed.outputHeight})');
                postApplied = true;
              } else {
                debugPrint(
                    '[CameraNotifier] Post-process returned null, keeping original');
              }
            }
          } catch (e, st) {
            debugPrint('[CameraNotifier] Post-process error: $e\n$st');
          } finally {
            postSw.stop();
            postMs = postSw.elapsedMilliseconds;
            debugPrint(
                '[Perf][takePhoto] post_process=$postMs ms applied=$postApplied');
          }
        }

        // 写入 GPS EXIF（在后处理完成后、保存到相册之前）
        if (locationFuture != null) {
          final exifSw = Stopwatch()..start();
          try {
            capturedLocation = await locationFuture;
            if (capturedLocation != null) {
              await _writeGpsExif(path, capturedLocation);
            }
          } catch (e) {
            debugPrint('[CameraNotifier] GPS EXIF write error: $e');
          } finally {
            exifSw.stop();
            exifMs = exifSw.elapsedMilliseconds;
            debugPrint('[Perf][takePhoto] gps_exif=$exifMs ms');
          }
        }

        // 保存到相册（快速返回策略）：
        // 最多等待短时间拿 galleryAssetId；超时则后台继续，不阻塞本次拍照返回。
        // Android: content://media/external/images/media/{_id} → 提取末段数字
        // iOS:    PHAsset.localIdentifier（直接使用，无需解析 URI）
        String? galleryAssetId;
        final gallerySw = Stopwatch()..start();
        Future<String?> saveFuture;
        final liveVideoPath = livePhotoVideoPath;
        if (livePhotoActive && Platform.isIOS && liveVideoPath != null) {
          final liveVideoRenderParams = captureRenderParams?.toPreviewJson(
                mode: PreviewPerformanceMode.lightweight,
              ) ??
              <String, dynamic>{};
          saveFuture = Future<String?>.value(
            await _ref.read(cameraServiceProvider.notifier).saveLivePhoto(
                  path,
                  liveVideoPath,
                  latitude: capturedLocation?.latitude,
                  longitude: capturedLocation?.longitude,
                  renderParams: liveVideoRenderParams,
                ),
          );
        } else if (livePhotoActive && liveVideoStopFuture != null) {
          final videoPath = await liveVideoStopFuture;
          if (videoPath != null && videoPath.isNotEmpty) {
            final liveVideoRenderParams = captureRenderParams?.toPreviewJson(
                  mode: PreviewPerformanceMode.lightweight,
                ) ??
                <String, dynamic>{};
            saveFuture = Future<String?>.value(
              await _ref.read(cameraServiceProvider.notifier).saveMotionPhoto(
                    path,
                    videoPath,
                    cameraId: state.activeCameraId,
                    latitude: capturedLocation?.latitude,
                    longitude: capturedLocation?.longitude,
                    renderParams: liveVideoRenderParams,
                  ),
            );
          } else {
            saveFuture =
                _ref.read(cameraServiceProvider.notifier).saveToGallery(
                      path,
                      cameraId: state.activeCameraId,
                      latitude: capturedLocation?.latitude,
                      longitude: capturedLocation?.longitude,
                    );
          }
        } else {
          saveFuture = _ref.read(cameraServiceProvider.notifier).saveToGallery(
                path,
                cameraId: state.activeCameraId,
                latitude: capturedLocation?.latitude,
                longitude: capturedLocation?.longitude,
              );
        }
        if (enhanceSourcePath != null && enhanceCamera != null) {
          unawaited(_runBackgroundEnhanceAndReplace(
            sourcePath: enhanceSourcePath,
            galleryUriFuture: saveFuture,
            camera: enhanceCamera,
            selectedRatioId: enhanceRatioId,
            selectedFrameId: enhanceFrameId,
            selectedWatermarkId: enhanceWatermarkId,
            frameBackgroundColor: enhanceFrameBackgroundColor,
            watermarkColorOverride: enhanceWatermarkColorOverride,
            watermarkPositionOverride: enhanceWatermarkPositionOverride,
            watermarkSizeOverride: enhanceWatermarkSizeOverride,
            watermarkDirectionOverride: enhanceWatermarkDirectionOverride,
            watermarkStyleOverride: enhanceWatermarkStyleOverride,
            renderParams: enhanceRenderParams,
            minimapNormalizedRect: enhanceMinimapRect,
            deviceQuarter: enhanceDeviceQuarter,
            fisheyeMode: enhanceFisheyeMode,
            circularFisheye: enhanceCircularFisheye,
            capturedLocation: capturedLocation,
          ));
        }
        try {
          const fastReturnBudget = Duration(milliseconds: 120);
          final galleryUri = await saveFuture.timeout(fastReturnBudget);
          debugPrint('[CameraNotifier] Saved to gallery: $galleryUri');
          if (galleryUri != null && galleryUri.isNotEmpty) {
            if (galleryUri.startsWith('content://')) {
              final uri = Uri.tryParse(galleryUri);
              galleryAssetId = uri?.pathSegments.lastOrNull;
            } else {
              galleryAssetId = galleryUri;
            }
            debugPrint('[CameraNotifier] galleryAssetId=$galleryAssetId');
            if (originalCopyPath != null &&
                galleryAssetId != null &&
                galleryAssetId.isNotEmpty) {
              await OriginalAssetService.instance.linkOriginal(
                assetId: galleryAssetId,
                originalPath: originalCopyPath,
              );
              originalCopyPath = null;
            }
          }
        } on TimeoutException {
          debugPrint(
              '[CameraNotifier] saveToGallery pending in background (>120ms), returning early');
          unawaited(saveFuture.then((galleryUri) {
            debugPrint(
                '[CameraNotifier] saveToGallery completed in background: $galleryUri');
            if (originalCopyPath == null ||
                galleryUri == null ||
                galleryUri.isEmpty) {
              return;
            }
            final assetId = galleryUri.startsWith('content://')
                ? Uri.tryParse(galleryUri)?.pathSegments.lastOrNull
                : galleryUri;
            if (assetId == null || assetId.isEmpty) return;
            unawaited(OriginalAssetService.instance.linkOriginal(
              assetId: assetId,
              originalPath: originalCopyPath!,
            ));
            originalCopyPath = null;
          }).catchError((Object e) {
            debugPrint('[CameraNotifier] saveToGallery background error: $e');
          }));
        } catch (e) {
          debugPrint('[CameraNotifier] saveToGallery error: $e');
        } finally {
          gallerySw.stop();
          galleryMs = gallerySw.elapsedMilliseconds;
          debugPrint('[Perf][takePhoto] save_gallery_waited=$galleryMs ms');
        }

        totalSw.stop();
        debugPrint(
          '[Perf][takePhoto] total=${totalSw.elapsedMilliseconds} ms '
          '(capture=$captureMs, post=$postMs, exif=$exifMs, gallery=$galleryMs)',
        );

        return TakePhotoResult(
          path: path,
          galleryAssetId: galleryAssetId,
          isLivePhoto: livePhotoActive,
        );
      }
      totalSw.stop();
      debugPrint(
          '[Perf][takePhoto] total=${totalSw.elapsedMilliseconds} ms (path=null)');
      return null;
    } finally {
      if (totalSw.isRunning) {
        totalSw.stop();
        debugPrint(
            '[Perf][takePhoto] total=${totalSw.elapsedMilliseconds} ms (finally)');
      }
      if (originalCopyPath != null) {
        unawaited(
          OriginalAssetService.instance.deleteUnlinkedPath(originalCopyPath),
        );
      }
      state = state.copyWith(isTakingPhoto: false);
      if (livePhotoRecordingStarted && liveVideoStopFuture == null) {
        unawaited(_ref.read(cameraServiceProvider.notifier).stopRecording());
      }
      unawaited(_syncCurrentPreviewStateToNative());
    }
  }

  Future<void> _runBackgroundEnhanceAndReplace({
    required String sourcePath,
    required Future<String?> galleryUriFuture,
    required CameraDefinition camera,
    required String selectedRatioId,
    required String selectedFrameId,
    required String selectedWatermarkId,
    required String? frameBackgroundColor,
    required String? watermarkColorOverride,
    required String? watermarkPositionOverride,
    required String? watermarkSizeOverride,
    required String? watermarkDirectionOverride,
    required String? watermarkStyleOverride,
    required PreviewRenderParams? renderParams,
    required Rect? minimapNormalizedRect,
    required int deviceQuarter,
    required bool fisheyeMode,
    required bool circularFisheye,
    required Position? capturedLocation,
  }) async {
    String? enhancedPath;
    try {
      final galleryUri = await galleryUriFuture;
      if (galleryUri == null || !galleryUri.startsWith('content://')) {
        debugPrint(
            '[CameraNotifier] BG enhance skipped: gallery uri unavailable ($galleryUri)');
        return;
      }

      final pipeline = CapturePipeline(camera: camera);
      // 后台增强档位：比中画质更高，但仍控制在可接受耗时。
      const enhanceMaxDim = 3072;
      const enhanceJpegQ = 88;
      final processed = await pipeline.process(
        imagePath: sourcePath,
        selectedRatioId: selectedRatioId,
        selectedFrameId: selectedFrameId,
        selectedWatermarkId: selectedWatermarkId,
        frameBackgroundColor: frameBackgroundColor,
        watermarkColorOverride: watermarkColorOverride,
        watermarkPositionOverride: watermarkPositionOverride,
        watermarkSizeOverride: watermarkSizeOverride,
        watermarkDirectionOverride: watermarkDirectionOverride,
        watermarkStyleOverride: watermarkStyleOverride,
        renderParams: renderParams,
        minimapNormalizedRect: minimapNormalizedRect,
        deviceQuarter: deviceQuarter,
        maxDimension: enhanceMaxDim,
        jpegQuality: enhanceJpegQ,
        fisheyeMode: fisheyeMode,
        circularFisheye: circularFisheye,
      );
      if (processed == null) {
        debugPrint('[CameraNotifier] BG enhance returned null');
        return;
      }

      enhancedPath =
          '${Directory.systemTemp.path}/dazz_bg_enh_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(enhancedPath).writeAsBytes(processed.bytes);
      if (capturedLocation != null) {
        await _writeGpsExif(enhancedPath, capturedLocation);
      }
      final replaced = await _ref
          .read(cameraServiceProvider.notifier)
          .replaceGalleryImage(galleryUri, enhancedPath);
      debugPrint(
          '[CameraNotifier] BG enhance replace ${replaced ? "ok" : "failed"} uri=$galleryUri size=${processed.outputWidth}x${processed.outputHeight}');
    } catch (e, st) {
      debugPrint('[CameraNotifier] BG enhance error: $e\n$st');
    } finally {
      try {
        if (File(sourcePath).existsSync()) File(sourcePath).deleteSync();
      } catch (_) {}
      try {
        if (enhancedPath != null && File(enhancedPath).existsSync()) {
          File(enhancedPath).deleteSync();
        }
      } catch (_) {}
    }
  }

  // ── 连拍 ──────────────────────────────────────────────────────────────────

  /// 循环切换连拍张数：0→3→3→10→0
  void cycleBurst() {
    final options = [0, 3, 10];
    final idx = options.indexOf(state.burstCount);
    final next = options[(idx + 1) % options.length];
    state = state.copyWith(burstCount: next);
  }

  /// 连拍模式下拍照入口。
  /// 不修改单张流程：内部依次调用 takePhoto，每张间隔 150ms。
  /// 返回所有成功张照的 [TakePhotoResult] 列表。
  Future<List<TakePhotoResult>> takeBurstPhotos({
    Rect? minimapNormalizedRect,
    int deviceQuarter = 0,
  }) async {
    final count = state.burstCount;
    if (count <= 0 || state.isBursting) return [];

    state = state.copyWith(isBursting: true, burstProgress: 0);
    final results = <TakePhotoResult>[];

    try {
      for (int i = 1; i <= count; i++) {
        // 如果用户在连拍过程中关闭了 App，安全退出
        if (!state.isBursting) break;

        final result = await takePhoto(
          minimapNormalizedRect: minimapNormalizedRect,
          deviceQuarter: deviceQuarter,
        );
        if (result != null) {
          results.add(result);
        }
        // 更新进度
        state = state.copyWith(burstProgress: i);

        // 每张间隔 150ms（防止硬件过热，同时给原生层准备时间）
        if (i < count) {
          await Future.delayed(const Duration(milliseconds: 150));
        }
      }
    } finally {
      state = state.copyWith(isBursting: false, burstProgress: 0);
    }

    return results;
  }

  /// 将 GPS 坐标写入图片文件的 EXIF
  Future<void> _writeGpsExif(String imagePath, Position position) async {
    try {
      final exif = await Exif.fromPath(imagePath);
      await exif.writeAttributes({
        'GPSLatitude': position.latitude.abs().toString(),
        'GPSLatitudeRef': position.latitude >= 0 ? 'N' : 'S',
        'GPSLongitude': position.longitude.abs().toString(),
        'GPSLongitudeRef': position.longitude >= 0 ? 'E' : 'W',
        'GPSAltitude': position.altitude.toString(),
        'GPSAltitudeRef': position.altitude >= 0 ? '0' : '1',
      });
      await exif.close();
      debugPrint(
          '[CameraNotifier] GPS EXIF written: ${position.latitude}, ${position.longitude}');
    } catch (e) {
      debugPrint('[CameraNotifier] Failed to write GPS EXIF: $e');
    }
  }

  // ── FIX: 将当前完整渲染参数（滤镜+镜头+defaultLook 组合后）发送到原生预览 Shader ──
  /// 切换滤镜或镜头后调用，确保原生层实时预览与 Dart 状态同步。
  void _applyCurrentRenderParamsToNative({bool throttled = false}) {
    if (!throttled) {
      _renderParamsPushTimer?.cancel();
      _sendRenderParamsNow();
      return;
    }
    if (_renderParamsPushTimer != null) return;
    _renderParamsPushTimer = Timer(_kRenderParamsPushInterval, () {
      _renderParamsPushTimer = null;
      _sendRenderParamsNow();
    });
  }

  void _sendRenderParamsNow() {
    syncRuntimeColorContext();
    final params = state.renderParams;
    if (params == null) return;
    final json = params.toPreviewJson(mode: state.previewPerformanceMode);
    final version = ++_renderParamsVersion;
    debugPrint(
        '[CameraNotifier] _applyCurrentRenderParamsToNative: sending ${json.length} params to native (v=$version)');
    _ref
        .read(cameraServiceProvider.notifier)
        .updateRenderParams(json, version: version)
        .then((ackVersion) {
      if (ackVersion != null &&
          ackVersion >= version &&
          ackVersion > _lastAckedRenderParamsVersion) {
        _lastAckedRenderParamsVersion = ackVersion;
      }
    });
  }

  Future<void> _syncCurrentPreviewStateToNative() async {
    syncRuntimeColorContext();
    final camera = state.camera;
    if (camera == null) return;
    final lensParams = _buildActiveLensParams(camera);
    final renderParams = _buildActiveRenderParamsJson();
    final zoom = state.zoomLevel;
    final svc = _ref.read(cameraServiceProvider.notifier);

    if (renderParams != null) {
      final version = ++_renderParamsVersion;
      final ackVersion = await svc.syncRuntimeState(
        lensParams: lensParams,
        renderParams: renderParams,
        zoom: zoom,
        version: version,
      );
      if (ackVersion != null &&
          ackVersion >= version &&
          ackVersion > _lastAckedRenderParamsVersion) {
        _lastAckedRenderParamsVersion = ackVersion;
      }
      return;
    }

    await svc.updateLensParams(
      distortion: (lensParams['distortion'] as num?)?.toDouble() ?? 0.0,
      vignette: (lensParams['vignette'] as num?)?.toDouble() ?? 0.0,
      zoomFactor: (lensParams['zoomFactor'] as num?)?.toDouble() ?? 1.0,
      fisheyeMode: lensParams['fisheyeMode'] as bool? ?? false,
      circularFisheye: lensParams['circularFisheye'] as bool? ?? false,
      chromaticAberration:
          (lensParams['chromaticAberration'] as num?)?.toDouble() ?? 0.0,
      bloom: (lensParams['bloom'] as num?)?.toDouble() ?? 0.0,
      softFocus: (lensParams['softFocus'] as num?)?.toDouble() ?? 0.0,
      exposure: (lensParams['exposure'] as num?)?.toDouble() ?? 0.0,
      contrast: (lensParams['contrast'] as num?)?.toDouble() ?? 0.0,
      saturation: (lensParams['saturation'] as num?)?.toDouble() ?? 0.0,
      highlightCompression:
          (lensParams['highlightCompression'] as num?)?.toDouble() ?? 0.0,
    );
    if (zoom != 1.0) {
      await svc.setZoom(zoom);
    }
  }

  Future<void> _syncViewportRatioToNative() async {
    final camera = state.camera;
    if (camera == null) return;
    final ratio = camera.ratioById(state.activeRatioId) ??
        camera.ratioById(camera.defaultSelection.ratioId);
    if (ratio == null || ratio.width <= 0 || ratio.height <= 0) return;
    await _ref.read(cameraServiceProvider.notifier).updateViewportRatio(
          width: ratio.width,
          height: ratio.height,
        );
  }

  Map<String, dynamic> _buildActiveLensParams(CameraDefinition camera) {
    final lens = camera.lensById(state.activeLensId);
    return {
      'distortion': lens?.distortion ?? 0.0,
      'vignette': lens?.vignette ?? 0.0,
      'zoomFactor': lens?.zoomFactor ?? 1.0,
      'fisheyeMode': lens?.fisheyeMode ?? false,
      'circularFisheye':
          lens?.circularFisheyeCrop ?? (lens?.fisheyeMode ?? false),
      'chromaticAberration': lens?.chromaticAberration ?? 0.0,
      'bloom': lens?.bloom ?? 0.0,
      'softFocus': lens?.softFocus ?? 0.0,
      'exposure': lens?.exposure ?? 0.0,
      'contrast': lens?.contrast ?? 0.0,
      'saturation': lens?.saturation ?? 0.0,
      'highlightCompression': lens?.highlightCompression ?? 0.0,
    };
  }

  Map<String, dynamic>? _buildActiveRenderParamsJson() {
    final renderParams = state.renderParams;
    if (renderParams == null) return null;
    return renderParams.toPreviewJson(mode: state.previewPerformanceMode);
  }

  ({int width, int height})? _currentViewportDimensionsFor(
      CameraDefinition camera) {
    final ratio = camera.ratioById(state.activeRatioId) ??
        camera.ratioById(camera.defaultSelection.ratioId);
    if (ratio == null || ratio.width <= 0 || ratio.height <= 0) return null;
    return (width: ratio.width, height: ratio.height);
  }

  Future<void> _syncCameraStateToNative({
    required CameraDefinition camera,
  }) async {
    syncRuntimeColorContext();
    final viewport = _currentViewportDimensionsFor(camera);
    final renderParams = _buildActiveRenderParamsJson();
    if (viewport == null || renderParams == null) {
      await _ref.read(cameraServiceProvider.notifier).setCamera(camera);
      await _syncViewportRatioToNativeImmediately();
      await _syncCurrentPreviewStateToNative();
      return;
    }
    final version = ++_renderParamsVersion;
    final ackVersion =
        await _ref.read(cameraServiceProvider.notifier).syncCameraState(
              camera: camera,
              lensParams: _buildActiveLensParams(camera),
              renderParams: renderParams,
              zoom: state.zoomLevel,
              viewportWidth: viewport.width,
              viewportHeight: viewport.height,
              livePhotoEnabled: state.livePhotoEnabled &&
                  _supportsLivePhotoForCurrentSelection,
              version: version,
            );
    if (ackVersion != null &&
        ackVersion >= version &&
        ackVersion > _lastAckedRenderParamsVersion) {
      _lastAckedRenderParamsVersion = ackVersion;
    }
  }

  void _scheduleViewportRatioSync({bool immediate = false}) {
    _viewportRatioSyncQueued = true;
    if (immediate) {
      _viewportRatioPushTimer?.cancel();
      _viewportRatioPushTimer = null;
      unawaited(_flushViewportRatioSync());
      return;
    }
    if (_viewportRatioPushTimer != null) return;
    _viewportRatioPushTimer = Timer(_kViewportRatioPushInterval, () {
      _viewportRatioPushTimer = null;
      unawaited(_flushViewportRatioSync());
    });
  }

  Future<void> _flushViewportRatioSync() async {
    if (_isViewportRatioSyncInFlight) {
      _viewportRatioSyncQueued = true;
      return;
    }
    _isViewportRatioSyncInFlight = true;
    try {
      while (_viewportRatioSyncQueued) {
        _viewportRatioSyncQueued = false;
        await _syncViewportRatioToNative();
      }
    } finally {
      _isViewportRatioSyncInFlight = false;
    }
  }

  Future<void> _syncViewportRatioToNativeImmediately() async {
    _viewportRatioPushTimer?.cancel();
    _viewportRatioPushTimer = null;
    _viewportRatioSyncQueued = true;
    await _flushViewportRatioSync();
  }

  Future<void> replayCurrentPreviewStateToNative({
    bool replayPreset = true,
  }) async {
    syncRuntimeColorContext();
    final camera = state.camera;
    if (camera == null) return;
    if (replayPreset) {
      await _syncCameraStateToNative(camera: camera);
      return;
    }
    await _syncViewportRatioToNativeImmediately();
    await _syncCurrentPreviewStateToNative();
  }

  void _pushZoomToNative(double zoom, {bool immediate = false}) {
    _pendingZoomToNative = zoom;
    if (immediate) {
      _zoomPushTimer?.cancel();
      _zoomPushTimer = null;
      final target = _pendingZoomToNative;
      if (target != null) {
        _pendingZoomToNative = null;
        _ref.read(cameraServiceProvider.notifier).setZoom(target);
      }
      return;
    }
    if (_zoomPushTimer != null) return;
    _zoomPushTimer = Timer(_kZoomPushInterval, () {
      _zoomPushTimer = null;
      final target = _pendingZoomToNative;
      if (target != null) {
        _pendingZoomToNative = null;
        _ref.read(cameraServiceProvider.notifier).setZoom(target);
      }
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
/// 拍照结果数据类
/// path: 缓存文件路径（处理后）
/// galleryAssetId: MediaStore _id，可直接用于 AssetEntity.fromId()查询
// ─────────────────────────────────────────────────────────────────────────────
class TakePhotoResult {
  final String path;
  final String? galleryAssetId;
  final bool isLivePhoto;
  const TakePhotoResult({
    required this.path,
    this.galleryAssetId,
    this.isLivePhoto = false,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider
// ─────────────────────────────────────────────────────────────────────────────

final cameraAppProvider =
    StateNotifierProvider<CameraAppNotifier, CameraAppState>((ref) {
  return CameraAppNotifier(ref);
});

// ─────────────────────────────────────────────────────────────────────────────
// 细粒度 Select Providers — 避免 CameraScreen 全量 rebuild
// 只有对应字段变化时，依赖该 provider 的 Widget 才会 rebuild
// 使用方式：将 ref.watch(cameraAppProvider).someField
//           替换为   ref.watch(somePropProvider)
// ─────────────────────────────────────────────────────────────────────────────

/// 当前激活的相机 ID（相机切换时 rebuild）
final activeCameraIdProvider = Provider<String>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.activeCameraId)),
);

/// 相机是否正在加载（切换相机时 rebuild）
final cameraLoadingProvider = Provider<bool>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.isLoading)),
);

/// 当前 CameraDefinition 对象（切换相机时 rebuild）
final cameraDefinitionProvider = Provider<CameraDefinition?>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.camera)),
);

/// 当前激活的比例 ID（切换比例时 rebuild）
final activeRatioIdProvider = Provider<String?>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.activeRatioId)),
);

/// 当前激活的相框 ID（切换相框时 rebuild）
final activeFrameIdProvider = Provider<String?>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.activeFrameId)),
);

/// 当前激活的水印 ID（切换水印时 rebuild）
final activeWatermarkIdProvider = Provider<String?>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.activeWatermarkId)),
);

/// 当前激活的镜头 ID（切换镜头时 rebuild）
final activeLensIdProvider = Provider<String?>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.activeLensId)),
);

/// 曝光值（拖动曝光条时 rebuild）
final exposureValueProvider = Provider<double>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.exposureValue)),
);

/// 缩放级别（双指缩放时 rebuild）
final zoomLevelProvider = Provider<double>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.zoomLevel)),
);

/// 是否显示缩放滑块（点击胶囊时 rebuild）
final showZoomSliderProvider = Provider<bool>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.showZoomSlider)),
);

/// 闪光灯模式（切换闪光灯时 rebuild）
final flashModeProvider = Provider<String>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.flashMode)),
);

/// 定时器秒数（切换定时器时 rebuild）
final timerSecondsProvider = Provider<int>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.timerSeconds)),
);

/// 是否正在拍照（按快门时 rebuild）
final isTakingPhotoProvider = Provider<bool>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.isTakingPhoto)),
);

/// 是否显示拍照闪光（拍照瞬间 rebuild）
final showCaptureFlashProvider = Provider<bool>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.showCaptureFlash)),
);

/// 当前激活的面板 ID（展开/收起面板时 rebuild）
final activePanelProvider = Provider<String?>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.activePanel)),
);

/// 是否前置摄像头（翻转摄像头时 rebuild）
final isFrontCameraProvider = Provider<bool>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.isFrontCamera)),
);

/// 网格开关（切换网格时 rebuild）
final gridEnabledProvider = Provider<bool>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.gridEnabled)),
);

/// 小窗模式（切换小窗时 rebuild）
final smallFrameModeProvider = Provider<bool>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.smallFrameMode)),
);

/// 鱼眼模式（切换鱼眼时 rebuild）
final fisheyeModeProvider = Provider<bool>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.fisheyeMode)),
);

final livePhotoEnabledProvider = Provider<bool>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.livePhotoEnabled)),
);

/// 双重曝光开关（切换双曝时 rebuild）
final doubleExpEnabledProvider = Provider<bool>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.doubleExpEnabled)),
);

/// 双重曝光第一张路径（拍第一张时 rebuild）
final doubleExpFirstPathProvider = Provider<String?>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.doubleExpFirstPath)),
);

/// 连拍进度（连拍时 rebuild）
final burstProgressProvider = Provider<int>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.burstProgress)),
);

/// 是否正在连拍（连拍时 rebuild）
final isBurstingProvider = Provider<bool>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.isBursting)),
);

/// 连拍张数（设置连拍时 rebuild）
final burstCountProvider = Provider<int>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.burstCount)),
);

/// 调试浮层开关（切换调试时 rebuild）
final showDebugOverlayProvider = Provider<bool>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.showDebugOverlay)),
);

/// 顶部菜单显示状态（展开/收起顶部菜单时 rebuild）
final showTopMenuProvider = Provider<bool>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.showTopMenu)),
);

/// 色温 K 值（调整色温时 rebuild）
final colorTempKProvider = Provider<int>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.colorTempK)),
);

/// 白平衡模式（切换白平衡时 rebuild）
final wbModeProvider = Provider<String>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.wbMode)),
);

/// 温度偏移（调整温度时 rebuild）
final temperatureOffsetProvider = Provider<double>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.temperatureOffset)),
);

/// 锐化级别（切换锐化时 rebuild）
final sharpenLevelProvider = Provider<int>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.sharpenLevel)),
);

/// 小地图开关（切换小地图时 rebuild）
final minimapEnabledProvider = Provider<bool>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.minimapEnabled)),
);

/// 位置信息开关（切换位置时 rebuild）
final locationEnabledProvider = Provider<bool>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.locationEnabled)),
);

/// 快门声音开关（切换快门声时 rebuild）
final shutterSoundEnabledProvider = Provider<bool>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.shutterSoundEnabled)),
);

/// 快门振动开关（切换振动时 rebuild）
final shutterVibrationEnabledProvider = Provider<bool>(
  (ref) =>
      ref.watch(cameraAppProvider.select((s) => s.shutterVibrationEnabled)),
);

/// 前置镜像开关（切换镜像时 rebuild）
final mirrorFrontCameraProvider = Provider<bool>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.mirrorFrontCamera)),
);

final mirrorBackCameraProvider = Provider<bool>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.mirrorBackCamera)),
);

/// 相框背景色（切换相框背景时 rebuild）
final frameBackgroundColorProvider = Provider<String?>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.frameBackgroundColor)),
);

/// 水印颜色（调整水印颜色时 rebuild）
final watermarkColorProvider = Provider<String?>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.watermarkColor)),
);

/// 水印位置（调整水印位置时 rebuild）
final watermarkPositionProvider = Provider<String?>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.watermarkPosition)),
);

/// 水印大小（调整水印大小时 rebuild）
final watermarkSizeProvider = Provider<String?>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.watermarkSize)),
);

/// 水印方向（调整水印方向时 rebuild）
final watermarkDirectionProvider = Provider<String?>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.watermarkDirection)),
);

/// 水印样式（调整水印样式时 rebuild）
final watermarkStyleProvider = Provider<String?>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.watermarkStyle)),
);

/// 双重曝光混合比例（调整混合时 rebuild）
final doubleExpBlendProvider = Provider<double>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.doubleExpBlend)),
);

/// 最近一次拍照分辨率（调试用，拍照后 rebuild）
final lastCaptureRawProvider = Provider<String>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.lastCaptureRaw)),
);

/// 最近一次输出分辨率（调试用，拍照后 rebuild）
final lastCaptureOutputProvider = Provider<String>(
  (ref) => ref.watch(cameraAppProvider.select((s) => s.lastCaptureOutput)),
);
