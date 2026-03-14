// camera_notifier.dart
// Multi-camera state management.
// Replaces grd_camera_notifier.dart with full multi-camera support.
// Loads any camera from the registry and manages all UI state.

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/camera_definition.dart';
import '../../models/camera_registry.dart';
import '../../services/camera_service.dart';
import 'preview_renderer.dart';
import 'capture_pipeline.dart';

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
    bool clearPanel = false,
    bool clearError = false,
  }) {
    return CameraAppState(
      activeCameraId: activeCameraId ?? this.activeCameraId,
      camera: camera ?? this.camera,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      activeFilterId: activeFilterId ?? this.activeFilterId,
      activeLensId: activeLensId ?? this.activeLensId,
      activeRatioId: activeRatioId ?? this.activeRatioId,
      activeFrameId: activeFrameId ?? this.activeFrameId,
      activeWatermarkId: activeWatermarkId ?? this.activeWatermarkId,
      temperatureOffset: temperatureOffset ?? this.temperatureOffset,
      exposureValue: exposureValue ?? this.exposureValue,
      wbMode: wbMode ?? this.wbMode,
      colorTempK: colorTempK ?? this.colorTempK,
      watermarkColor: watermarkColor ?? this.watermarkColor,
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

  /// Initialize with default camera (grd_r)
  Future<void> initialize() async {
    await _loadCamera('grd_r');
  }

  /// Switch to a different camera by id
  Future<void> switchToCamera(String cameraId) async {
    if (state.activeCameraId == cameraId && state.camera != null) {
      // Already loaded, just close manager
      state = state.copyWith(showCameraManager: false, clearPanel: true);
      return;
    }
    await _loadCamera(cameraId);
    state = state.copyWith(showCameraManager: false);
  }

  Future<void> _loadCamera(String cameraId) async {
    state = state.copyWith(isLoading: true, clearError: true, activeCameraId: cameraId);
    try {
      final camera = await loadCamera(cameraId);
      final defaults = camera.defaultSelection;
      state = state.copyWith(
        camera: camera,
        isLoading: false,
        activeCameraId: cameraId,
        activeFilterId: defaults.filterId,
        activeLensId: defaults.lensId,
        activeRatioId: defaults.ratioId,
        activeFrameId: defaults.frameId,
        activeWatermarkId: defaults.watermarkPresetId,
        temperatureOffset: 0,
        exposureValue: 0,
        clearPanel: true,
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
    state = state.copyWith(activeLensId: id);
  }

  void selectRatio(String id) {
    state = state.copyWith(activeRatioId: id);
  }

  void selectFrame(String id) {
    if (id == 'frame_none') {
      state = state.copyWith(activeFrameId: null, clearPanel: false);
    } else {
      state = state.copyWith(activeFrameId: id);
    }
  }

  void selectWatermark(String id) {
    state = state.copyWith(activeWatermarkId: id);
  }

  void selectWatermarkColor(String hexColor) {
    state = state.copyWith(watermarkColor: hexColor);
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
    state = state.copyWith(gridEnabled: !state.gridEnabled);
  }

  void toggleSmallFrame() {
    state = state.copyWith(smallFrameMode: !state.smallFrameMode);
  }

  void cycleSharpen() {
    final next = (state.sharpenLevel + 1) % 3;
    state = state.copyWith(sharpenLevel: next);
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
  Future<TakePhotoResult?> takePhoto() async {
    if (state.isTakingPhoto) return null;
    state = state.copyWith(isTakingPhoto: true);
    HapticFeedback.mediumImpact();

    try {
      final path = await _ref.read(cameraServiceProvider.notifier).takePhoto();

      if (path != null) {
        state = state.copyWith(showCaptureFlash: true);
        await Future.delayed(const Duration(milliseconds: 150));
        state = state.copyWith(showCaptureFlash: false);
        HapticFeedback.lightImpact();

        // Post-process: color effects + ratio crop + frame + watermark
        if (state.camera != null) {
          try {
            debugPrint('[CameraNotifier] Starting post-process: ratio=${state.activeRatioId}, frame=${state.activeFrameId}, wm=${state.activeWatermarkId}');
            final pipeline = CapturePipeline(camera: state.camera!);
            final processed = await pipeline.process(
              imagePath: path,
              selectedRatioId: state.activeRatioId ?? '',
              selectedFrameId: state.activeFrameId ?? '',
              selectedWatermarkId: state.activeWatermarkId ?? '',
              frameBackgroundColor: state.frameBackgroundColor, // 用户选择的背景色
              renderParams: state.renderParams,
            );
            if (processed != null) {
              await File(path).writeAsBytes(processed);
              debugPrint('[CameraNotifier] Post-process done, wrote ${processed.length} bytes to $path');
            } else {
              debugPrint('[CameraNotifier] Post-process returned null, keeping original');
            }
          } catch (e, st) {
            debugPrint('[CameraNotifier] Post-process error: $e\n$st');
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
