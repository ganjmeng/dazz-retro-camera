// camera_notifier.dart
// Multi-camera state management.
// Replaces grd_camera_notifier.dart with full multi-camera support.
// Loads any camera from the registry and manages all UI state.

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:native_exif/native_exif.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/camera_definition.dart';
import '../../models/camera_registry.dart';
import '../../services/camera_service.dart';
import '../../services/location_service.dart';
import 'preview_renderer.dart';
import 'capture_pipeline.dart';
import '../../services/retain_settings_service.dart';
import '../../services/app_prefs_service.dart';

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
  final double exposureValue;     // -2.0..2.0
  // White balance
  final String wbMode;   // 'auto' | 'daylight' | 'incandescent'
  final int colorTempK;  // 1800..8000
  final String? watermarkColor;       // hex color override for watermark
  final String? watermarkPosition;    // 位置覆盖: 'bottom_right'|'bottom_left'|'top_right'|'top_left'|'bottom_center'|'top_center'
  final String? watermarkSize;        // 大小覆盖: 'small'|'medium'|'large'
  final String? watermarkDirection;   // 方向覆盖: 'horizontal'|'vertical'
  final String? watermarkStyle;       // 样式覆盖: preset id
  final String? frameBackgroundColor; // hex color override for frame background

  // UI state
  final String? activePanel; // null | 'filter' | 'lens' | 'ratio' | 'frame' | 'watermark'
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
  final double zoomLevel;      // 0.6 ~ 20.0, default 1.0
  final bool showZoomSlider;   // 胶囊点击后展开缩放滑动条
  final bool minimapEnabled;   // 小窗模式开关
  final bool locationEnabled;  // 位置信息开关：开启后拍照将 GPS 坐标写入 EXIF
  final bool showDebugOverlay; // 调试信息浮层：显示实时渲染参数
  final bool shutterSoundEnabled; // 快门声音开关
  final bool mirrorFrontCamera;   // 前置摄像头镜像开关
  final bool shutterVibrationEnabled; // 快门振动开关
  final bool fisheyeMode;              // 鱼眼圆圈模式
  // ── 双重曝光 ──────────────────────────────────────────────────────────────
  final bool doubleExpEnabled;       // 双重曝光开关
  final String? doubleExpFirstPath;  // 第一张照片本地路径（待合成）
  final double doubleExpBlend;       // 混合比例 0.3~0.7，默认 0.5
  // ── 连拍 ──────────────────────────────────────────────────────────────────
  final int burstCount;       // 连拍张数：0=关闭, 3=3张, 10=10张
  final int burstProgress;    // 当前连拍进度（0=未开始，1~N=第N张完成）
  final bool isBursting;      // 是否正在连拍中
  // Debug: 最近一次拍照的分辨率信息
  final String lastCaptureRaw;    // e.g. "4032×3024" 原始分辨率
  final String lastCaptureOutput; // e.g. "3024×3024" 输出分辨率

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
     this.shutterVibrationEnabled = true,
    this.fisheyeMode = false,
    this.doubleExpEnabled = false,
    this.doubleExpFirstPath,
    this.doubleExpBlend = 0.5,
    this.burstCount = 0,
    this.burstProgress = 0,
    this.isBursting = false,
    this.lastCaptureRaw = '',
    this.lastCaptureOutput = '',
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
    bool? shutterVibrationEnabled,
    bool? fisheyeMode,
    bool? doubleExpEnabled,
    String? doubleExpFirstPath,
    bool clearDoubleExpFirst = false,
    double? doubleExpBlend,
    int? burstCount,
    int? burstProgress,
    bool? isBursting,
    String? lastCaptureRaw,
    String? lastCaptureOutput,
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
      activeFrameId: clearFrameId ? null : (activeFrameId ?? this.activeFrameId),
      activeWatermarkId: activeWatermarkId ?? this.activeWatermarkId,
      temperatureOffset: temperatureOffset ?? this.temperatureOffset,
      exposureValue: exposureValue ?? this.exposureValue,
      wbMode: wbMode ?? this.wbMode,
      colorTempK: colorTempK ?? this.colorTempK,
      watermarkColor: watermarkColor ?? this.watermarkColor,
      watermarkPosition: clearWatermarkOverrides ? null : (watermarkPosition ?? this.watermarkPosition),
      watermarkSize: clearWatermarkOverrides ? null : (watermarkSize ?? this.watermarkSize),
      watermarkDirection: clearWatermarkOverrides ? null : (watermarkDirection ?? this.watermarkDirection),
      watermarkStyle: clearWatermarkOverrides ? null : (watermarkStyle ?? this.watermarkStyle),
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
      shutterVibrationEnabled: shutterVibrationEnabled ?? this.shutterVibrationEnabled,
      fisheyeMode: fisheyeMode ?? this.fisheyeMode,
      doubleExpEnabled: doubleExpEnabled ?? this.doubleExpEnabled,
      doubleExpFirstPath: clearDoubleExpFirst ? null : (doubleExpFirstPath ?? this.doubleExpFirstPath),
      doubleExpBlend: doubleExpBlend ?? this.doubleExpBlend,
      burstCount: burstCount ?? this.burstCount,
      burstProgress: burstProgress ?? this.burstProgress,
      isBursting: isBursting ?? this.isBursting,
      lastCaptureRaw: lastCaptureRaw ?? this.lastCaptureRaw,
      lastCaptureOutput: lastCaptureOutput ?? this.lastCaptureOutput,
    );
  }

  // ── Convenience getters ──

  FilterDefinition? get activeFilter => camera?.filterById(activeFilterId);
  LensDefinition? get activeLens => camera?.lensById(activeLensId);
  RatioDefinition? get activeRatio => camera?.ratioById(activeRatioId);
  FrameDefinition? get activeFrame => camera?.frameById(activeFrameId);
  WatermarkPreset? get activeWatermark => camera?.watermarkById(activeWatermarkId);

  PreviewRenderParams? get renderParams {
    if (camera == null) return null;
    return PreviewRenderParams(
      defaultLook: camera!.defaultLook,
      activeFilter: activeFilter,
      activeLens: activeLens,
      temperatureOffset: temperatureOffset,
      exposureOffset: exposureValue,
      policy: camera!.previewPolicy,
    );
  }

  double get previewAspectRatio {
    final ratio = activeRatio;
    if (ratio == null) return 3 / 4;
    return ratio.width / ratio.height;
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

  CameraAppNotifier(this._ref) : super(const CameraAppState());

  /// Initialize: 从持久化读取上次选择的相机和全局设置
  Future<void> initialize() async {
    final prefs = await AppPrefsService.instance.load();
    // 先将持久化的全局设置写入 state（在 _loadCamera 之前，避免被覆盖）
    state = state.copyWith(
      sharpenLevel:            prefs.sharpenLevel,
      gridEnabled:             prefs.gridEnabled,
      minimapEnabled:          prefs.minimapEnabled,
      shutterSoundEnabled:     prefs.shutterSoundEnabled,
      shutterVibrationEnabled: prefs.shutterVibrationEnabled,
      locationEnabled:         prefs.locationEnabled,
      mirrorFrontCamera:       prefs.mirrorFrontCamera,
    );
    await _loadCamera(prefs.lastCameraId);
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
    // 切换前：保存当前相机的设定快照（供下次切回时恢复）
    await _saveCurrentSnapshot();
    await _loadCamera(cameraId);
    state = state.copyWith(showCameraManager: false);
  }

  /// 保存当前相机设定快照到 RetainSettingsService
  Future<void> _saveCurrentSnapshot() async {
    final retainNotifier = _ref.read(retainSettingsProvider.notifier);
    await retainNotifier.saveSnapshot(
      state.activeCameraId,
      CameraSnapshot(
        temperatureOffset: state.temperatureOffset,
        colorTempK:        state.colorTempK,
        wbMode:            state.wbMode,
        exposureValue:     state.exposureValue,
        zoomLevel:         state.zoomLevel,
        frameId:           state.activeFrameId,
      ),
    );
  }

  Future<void> _loadCamera(String cameraId) async {
    state = state.copyWith(isLoading: true, clearError: true, activeCameraId: cameraId);
    try {
      final camera = await loadCamera(cameraId);
      final defaults = camera.defaultSelection;

      // 读取保留设定开关和该相机的快照
      final retainState    = _ref.read(retainSettingsProvider);
      final retainNotifier = _ref.read(retainSettingsProvider.notifier);
      final snapshot       = await retainNotifier.loadSnapshot(cameraId);

      // 根据各开关决定是否恢复设定，无快照则使用默认值
      final double tempOffset = (retainState.retainTemperature && snapshot != null)
          ? snapshot.temperatureOffset : 0;
      final int    colorK     = (retainState.retainTemperature && snapshot != null)
          ? snapshot.colorTempK : 6300;
      final String wbMode     = (retainState.retainTemperature && snapshot != null)
          ? snapshot.wbMode : 'auto';
      final double exposure   = (retainState.retainExposure && snapshot != null)
          ? snapshot.exposureValue : 0;
      final double zoom       = (retainState.retainZoom && snapshot != null)
          ? snapshot.zoomLevel : 1.0;
      final String? frameId   = (retainState.retainFrame && snapshot != null && snapshot.frameId != null)
          ? snapshot.frameId : defaults.frameId;

      state = state.copyWith(
        camera: camera,
        isLoading: false,
        activeCameraId: cameraId,
        activeFilterId: defaults.filterId,
        activeLensId: defaults.lensId,
        activeRatioId: defaults.ratioId,
        activeFrameId: frameId,
        activeWatermarkId: defaults.watermarkPresetId,
        temperatureOffset: tempOffset,
        exposureValue: exposure,
        zoomLevel: zoom,
        colorTempK: colorK,
        wbMode: wbMode,
        fisheyeMode: camera.lensById(defaults.lensId)?.fisheyeMode ?? false,
        clearPanel: true,
      );
      // 关键修复：加载相机后立即将默认镜头参数同步到原生 GPU shader
      // 不调用此就会导致切换相机后默认镜头效果不生效，必须手动点击一次才触发
      final defaultLens = camera.lensById(defaults.lensId);
      _ref.read(cameraServiceProvider.notifier).updateLensParams(
        distortion: defaultLens?.distortion ?? 0.0,
        vignette: defaultLens?.vignette ?? 0.0,
        zoomFactor: defaultLens?.zoomFactor ?? 1.0,
        fisheyeMode: defaultLens?.fisheyeMode ?? false,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: 'Failed to load camera: $e');
    }
  }

  // ── Panel management ──

  void togglePanel(String panelId) {
    if (state.activePanel == panelId) {
      state = state.copyWith(clearPanel: true, showTopMenu: false, showCameraManager: false);
    } else {
      state = state.copyWith(activePanel: panelId, showTopMenu: false, showCameraManager: false);
    }
  }

  void closeAllPanels() {
    state = state.copyWith(clearPanel: true, showTopMenu: false, showCameraManager: false);
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
    // 通知原生层更新镜头参数（在 GPU shader 中实现，零 CPU 开销）
    final newLens = state.camera?.lensById(newLensId);
    final distortion = newLens?.distortion ?? 0.0;
    final vignette = newLens?.vignette ?? 0.0;
    final zoomFactor = newLens?.zoomFactor ?? 1.0;
    final fisheyeMode = newLens?.fisheyeMode ?? false;
    state = state.copyWith(activeLensId: newLensId, fisheyeMode: fisheyeMode);
    _ref.read(cameraServiceProvider.notifier).updateLensParams(
      distortion: distortion,
      vignette: vignette,
      zoomFactor: zoomFactor,
      fisheyeMode: fisheyeMode,
    );
  }

  void selectRatio(String id) {
    // 如果切换到不支持相框的比例，自动清除当前相框选择
    final camera = state.camera;
    if (camera != null && state.activeFrameId != null) {
      final ratio = camera.modules.ratios.where((r) => r.id == id).firstOrNull;
      if (ratio != null && !ratio.supportsFrame) {
        state = state.copyWith(activeRatioId: id, clearFrameId: true);
        return;
      }
      // 当前相框不支持新比例时也自动清除
      final frameOpt = camera.modules.frames
          .where((f) => f.id == state.activeFrameId)
          .firstOrNull;
      if (frameOpt != null &&
          frameOpt.supportedRatios.isNotEmpty &&
          !frameOpt.supportedRatios.contains(id)) {
        state = state.copyWith(activeRatioId: id, clearFrameId: true);
        return;
      }
    }
    state = state.copyWith(activeRatioId: id);
  }

  void selectFrame(String id) {
    // 'none' 和 'frame_none' 都表示无边框，用 clearFrameId=true 真正清空 activeFrameId
    if (id == 'frame_none' || id == 'none') {
      state = state.copyWith(clearFrameId: true);
    } else {
      state = state.copyWith(activeFrameId: id);
    }
  }

  void selectWatermark(String id) {
    // 切换预设时清空用户覆盖（使新预设的默认配置生效）
    state = state.copyWith(activeWatermarkId: id, clearWatermarkOverrides: true);
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
    // 通知原生层镜像设置
    _ref.read(cameraServiceProvider.notifier).setMirrorFrontCamera(enabled);
  }

  void setShutterVibrationEnabled(bool enabled) {
    state = state.copyWith(shutterVibrationEnabled: enabled);
    AppPrefsService.instance.setShutterVibrationEnabled(enabled);
  }

  void setLocationEnabled(bool enabled) {
    state = state.copyWith(locationEnabled: enabled);
    AppPrefsService.instance.setLocationEnabled(enabled);
  }

  void selectFrameBackground(String hexColor) {
    state = state.copyWith(frameBackgroundColor: hexColor);
  }

  /// Alias for switchToCamera (used by CameraConfigSheet)
  Future<void> switchCamera(String cameraId) => switchToCamera(cameraId);

  // ── Camera controls ──

  void setTemperature(double value) {
    state = state.copyWith(temperatureOffset: value);
  }

  void setExposure(double value) {
    state = state.copyWith(exposureValue: value);
  }

  // 设置白平衡预设模式
  // mode: 'auto' | 'daylight' | 'incandescent'
  void setWhiteBalance(String mode) {
    int tempK;
    switch (mode) {
      case 'daylight':      tempK = 4800; break;
      case 'incandescent':  tempK = 1800; break;
      default:              tempK = 6300; break; // auto
    }
    state = state.copyWith(wbMode: mode, colorTempK: tempK);
    // 通知原生层设置白平衡
    _ref.read(cameraServiceProvider.notifier).setWhiteBalance(mode);
  }

  // 手动设置色温（滑动条拖动时调用）
  void setColorTempK(int kelvin) {
    state = state.copyWith(wbMode: 'manual', colorTempK: kelvin.clamp(1800, 8000));
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
    state = state.copyWith(zoomLevel: clamped);
    _ref.read(cameraServiceProvider.notifier).setZoom(clamped);
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
    _ref.read(cameraServiceProvider.notifier).setZoom(1.0);
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
      clearDoubleExpFirst: true, // 切换时清空第一张照片
    );
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

  void cycleSharpen() {
    final next = (state.sharpenLevel + 1) % 3;
    state = state.copyWith(sharpenLevel: next);
    AppPrefsService.instance.setSharpenLevel(next);
    // 0=低(0.0), 1=中(0.5), 2=高(1.0)
    const levels = [0.0, 0.5, 1.0];
    _ref.read(cameraServiceProvider.notifier).setSharpen(levels[next]);
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

  Future<void> flipCamera() async {
    state = state.copyWith(isFrontCamera: !state.isFrontCamera);
    await _ref.read(cameraServiceProvider.notifier).switchLens();
  }

  // ── Take photo ──

  /// 拍照并保存到相册。
  /// 返回 [TakePhotoResult]，包含缓存文件路径和 MediaStore 资产 ID。
  /// galleryAssetId 可直接用于 AssetEntity.fromId()，完全绕开相册查询逻辑。
  /// [minimapNormalizedRect] 小窗归一化裁剪区域（在取景框内的相对坐标 0.0~1.0）
  Future<TakePhotoResult?> takePhoto({Rect? minimapNormalizedRect, int deviceQuarter = 0}) async {
    if (state.isTakingPhoto) return null;
    state = state.copyWith(isTakingPhoto: true);
    HapticFeedback.mediumImpact();

    try {
      final photoResult = await _ref.read(cameraServiceProvider.notifier).takePhoto();
      final path = photoResult?['filePath'] as String?;
      final captureW = photoResult?['captureWidth'] as int? ?? 0;
      final captureH = photoResult?['captureHeight'] as int? ?? 0;
      if (captureW > 0 && captureH > 0) {
        state = state.copyWith(lastCaptureRaw: '${captureW}×${captureH}');
      }

      if (path != null) {
        state = state.copyWith(showCaptureFlash: true);
        await Future.delayed(const Duration(milliseconds: 150));
        state = state.copyWith(showCaptureFlash: false);
        HapticFeedback.lightImpact();

        // 如果开启位置，并行获取 GPS 坐标（与后处理并行，不阻塞流程）
        Future<Position?>? locationFuture;
        if (state.locationEnabled) {
          locationFuture = LocationService.instance.getCurrentPosition();
        }

        // Post-process: color effects + ratio crop + frame + watermark
        if (state.camera != null) {
          try {
            debugPrint('[CameraNotifier] Starting post-process: ratio=${state.activeRatioId}, frame=${state.activeFrameId}, wm=${state.activeWatermarkId}');
            final pipeline = CapturePipeline(camera: state.camera!);
            // 按清晰度档位选择输出尺寸和 JPEG 质量
            // sharpenLevel: 0=低(1080px/q82), 1=中(1440px/q82), 2=高(4096px/q90)
            final maxDim = switch (state.sharpenLevel) {
              0 => CapturePipeline.kMaxDimLow,
              2 => CapturePipeline.kMaxDimHigh,
              _ => CapturePipeline.kMaxDimMid,
            };
            final jpegQ = switch (state.sharpenLevel) {
              0 => CapturePipeline.kJpegQualityLow,
              2 => CapturePipeline.kJpegQualityHigh,
              _ => CapturePipeline.kJpegQualityMid,
            };

            // ── 双重曝光处理逻辑 ──────────────────────────────────────────────────────────────
            if (state.doubleExpEnabled) {
              final firstPath = state.doubleExpFirstPath;
              if (firstPath == null) {
                // 第一张：仅做单张后处理，不合成，保存到临时目录
                final processed = await pipeline.process(
                  imagePath: path,
                  selectedRatioId: state.activeRatioId ?? '',
                  selectedFrameId: 'frame_none',  // 第一张不加相框
                  selectedWatermarkId: 'none',     // 第一张不加水印
                  renderParams: state.renderParams,
                  minimapNormalizedRect: minimapNormalizedRect,
                  deviceQuarter: deviceQuarter,
                  maxDimension: maxDim,
                  jpegQuality: jpegQ,
                  fisheyeMode: state.fisheyeMode,
                );
                if (processed != null) {
                  // 将处理后的第一张写入临时文件
                  final tmpDir = Directory.systemTemp;
                  final firstSavePath = '${tmpDir.path}/dazz_double_exp_first_${DateTime.now().millisecondsSinceEpoch}.jpg';
                  await File(firstSavePath).writeAsBytes(processed.bytes);
                  state = state.copyWith(doubleExpFirstPath: firstSavePath);
                  debugPrint('[DoubleExp] First photo saved: $firstSavePath');
                }
                // 第一张不保存到相册，直接返回 null
                state = state.copyWith(isTakingPhoto: false);
                return null;
              } else {
                // 第二张：合成两张照片
                final processed2 = await pipeline.process(
                  imagePath: path,
                  selectedRatioId: state.activeRatioId ?? '',
                  selectedFrameId: 'frame_none',
                  selectedWatermarkId: 'none',
                  renderParams: state.renderParams,
                  minimapNormalizedRect: minimapNormalizedRect,
                  deviceQuarter: deviceQuarter,
                  maxDimension: maxDim,
                  jpegQuality: jpegQ,
                  fisheyeMode: state.fisheyeMode,
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
                    final tmpBlendPath = '${Directory.systemTemp.path}/dazz_blend_${DateTime.now().millisecondsSinceEpoch}.jpg';
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
                      deviceQuarter: 0,   // 已经旋转过
                      maxDimension: maxDim,
                      jpegQuality: jpegQ,
                      fisheyeMode: state.fisheyeMode,
                    );
                    if (finalProcessed != null) {
                      await File(path).writeAsBytes(finalProcessed.bytes);
                      state = state.copyWith(
                        lastCaptureOutput: '${finalProcessed.outputWidth}×${finalProcessed.outputHeight}',
                      );
                    } else {
                      await File(path).writeAsBytes(blended);
                    }
                    // 清理临时文件
                    try { File(tmpBlendPath).deleteSync(); } catch (_) {}
                  }
                  // 清理第一张临时文件
                  try { File(firstPath).deleteSync(); } catch (_) {}
                }
                // 合成完成，关闭双重曝光模式
                state = state.copyWith(
                  doubleExpEnabled: false,
                  clearDoubleExpFirst: true,
                );
                debugPrint('[DoubleExp] Blend complete, double exp mode closed');
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
                renderParams: state.renderParams,
                minimapNormalizedRect: minimapNormalizedRect,
                deviceQuarter: deviceQuarter,
                maxDimension: maxDim,
                jpegQuality: jpegQ,
                fisheyeMode: state.fisheyeMode,
              );
              if (processed != null) {
                await File(path).writeAsBytes(processed.bytes);
                state = state.copyWith(
                  lastCaptureOutput: '${processed.outputWidth}×${processed.outputHeight}',
                );
                debugPrint('[CameraNotifier] Post-process done, wrote ${processed.bytes.length} bytes to $path (${processed.outputWidth}x${processed.outputHeight})');
              } else {
                debugPrint('[CameraNotifier] Post-process returned null, keeping original');
              }
            }
          } catch (e, st) {
            debugPrint('[CameraNotifier] Post-process error: $e\n$st');
          }
        }

        // 写入 GPS EXIF（在后处理完成后、保存到相册之前）
        if (locationFuture != null) {
          try {
            final position = await locationFuture;
            if (position != null) {
              await _writeGpsExif(path, position);
            }
          } catch (e) {
            debugPrint('[CameraNotifier] GPS EXIF write error: $e');
          }
        }

        // 保存到相册，获取资产 ID
        // Android: content://media/external/images/media/{_id} → 提取末段数字
        // iOS:    PHAsset.localIdentifier（直接使用，无需解析 URI）
        String? galleryAssetId;
        try {
          final galleryUri = await _ref.read(cameraServiceProvider.notifier).saveToGallery(
            path,
            cameraId: state.activeCameraId,
          );
          debugPrint('[CameraNotifier] Saved to gallery: $galleryUri');
          if (galleryUri != null && galleryUri.isNotEmpty) {
            if (galleryUri.startsWith('content://')) {
              // Android: content://media/external/images/media/{_id}
              final uri = Uri.tryParse(galleryUri);
              galleryAssetId = uri?.pathSegments.lastOrNull;
            } else {
              // iOS: PHAsset.localIdentifier 直接使用
              galleryAssetId = galleryUri;
            }
            debugPrint('[CameraNotifier] galleryAssetId=$galleryAssetId');
          }
        } catch (e) {
          debugPrint('[CameraNotifier] saveToGallery error: $e');
        }

        return TakePhotoResult(path: path, galleryAssetId: galleryAssetId);
      }
      return null;
    } finally {
      state = state.copyWith(isTakingPhoto: false);
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
      debugPrint('[CameraNotifier] GPS EXIF written: ${position.latitude}, ${position.longitude}');
    } catch (e) {
      debugPrint('[CameraNotifier] Failed to write GPS EXIF: $e');
    }
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
  const TakePhotoResult({required this.path, this.galleryAssetId});
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider
// ─────────────────────────────────────────────────────────────────────────────

final cameraAppProvider =
    StateNotifierProvider<CameraAppNotifier, CameraAppState>((ref) {
  return CameraAppNotifier(ref);
});
