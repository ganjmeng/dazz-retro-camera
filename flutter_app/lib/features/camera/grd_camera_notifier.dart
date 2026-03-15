// grd_camera_notifier.dart
// State management for the GRD R camera screen.
// Loads CameraDefinition from JSON, manages all UI state,
// and coordinates with CameraService for native operations.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/camera_definition.dart';
import '../../services/camera_service.dart';
import 'dart:io';
import 'preview_renderer.dart';
import 'capture_pipeline.dart';

// ─────────────────────────────────────────────────────────────────────────────
// GrdCameraState
// ─────────────────────────────────────────────────────────────────────────────

class GrdCameraState {
  final CameraDefinition? camera;
  final bool isLoading;
  final String? error;

  // Current selections
  final String? activeFilterId;
  final String? activeLensId;
  final String? activeRatioId;
  final String? activeFrameId;
  final String? activeWatermarkId;
  final String? watermarkStyle; // 样式 ID，对应 kWatermarkStyles

  // User adjustments
  final double temperatureOffset; // -100..100
  final double exposureValue;     // -2.0..2.0

  // UI state
  final String? activePanel; // null | 'filter' | 'lens' | 'ratio' | 'frame' | 'watermark'
  final bool gridEnabled;
  final bool showTopMenu;
  final String flashMode; // 'off' | 'on' | 'auto'
  final int timerSeconds; // 0 | 3 | 10
  final bool isFrontCamera;
  final bool isTakingPhoto;
  final bool showCaptureFlash;

  const GrdCameraState({
    this.camera,
    this.isLoading = true,
    this.error,
    this.activeFilterId,
    this.activeLensId,
    this.activeRatioId,
    this.activeFrameId,
    this.activeWatermarkId,
    this.watermarkStyle,
    this.temperatureOffset = 0,
    this.exposureValue = 0,
    this.activePanel,
    this.gridEnabled = false,
    this.showTopMenu = false,
    this.flashMode = 'off',
    this.timerSeconds = 0,
    this.isFrontCamera = false,
    this.isTakingPhoto = false,
    this.showCaptureFlash = false,
  });

  GrdCameraState copyWith({
    CameraDefinition? camera,
    bool? isLoading,
    String? error,
    String? activeFilterId,
    String? activeLensId,
    String? activeRatioId,
    String? activeFrameId,
    String? activeWatermarkId,
    String? watermarkStyle,
    double? temperatureOffset,
    double? exposureValue,
    String? activePanel,
    bool? gridEnabled,
    bool? showTopMenu,
    String? flashMode,
    int? timerSeconds,
    bool? isFrontCamera,
    bool? isTakingPhoto,
    bool? showCaptureFlash,
    bool clearPanel = false,
    bool clearError = false,
  }) {
    return GrdCameraState(
      camera: camera ?? this.camera,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      activeFilterId: activeFilterId ?? this.activeFilterId,
      activeLensId: activeLensId ?? this.activeLensId,
      activeRatioId: activeRatioId ?? this.activeRatioId,
      activeFrameId: activeFrameId ?? this.activeFrameId,
      activeWatermarkId: activeWatermarkId ?? this.activeWatermarkId,
      watermarkStyle: watermarkStyle ?? this.watermarkStyle,
      temperatureOffset: temperatureOffset ?? this.temperatureOffset,
      exposureValue: exposureValue ?? this.exposureValue,
      activePanel: clearPanel ? null : (activePanel ?? this.activePanel),
      gridEnabled: gridEnabled ?? this.gridEnabled,
      showTopMenu: showTopMenu ?? this.showTopMenu,
      flashMode: flashMode ?? this.flashMode,
      timerSeconds: timerSeconds ?? this.timerSeconds,
      isFrontCamera: isFrontCamera ?? this.isFrontCamera,
      isTakingPhoto: isTakingPhoto ?? this.isTakingPhoto,
      showCaptureFlash: showCaptureFlash ?? this.showCaptureFlash,
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
    final lens = activeLens;
    if (lens == null) return 'x1';
    switch (lens.id) {
      case 'wide': return 'x2';
      case 'vintage': return 'x1';
      case 'dream': return 'x1';
      case 'prism': return 'x1';
      default: return 'x1';
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// GrdCameraNotifier
// ─────────────────────────────────────────────────────────────────────────────

class GrdCameraNotifier extends StateNotifier<GrdCameraState> {
  final Ref _ref;

  GrdCameraNotifier(this._ref) : super(const GrdCameraState());

  Future<void> initialize() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final camera = await CameraDefinition.loadFromAsset(
        'assets/cameras/grd_r.json',
      );
      final defaults = camera.defaultSelection;
      state = state.copyWith(
        camera: camera,
        isLoading: false,
        activeFilterId: defaults.filterId,
        activeLensId: defaults.lensId,
        activeRatioId: defaults.ratioId,
        activeFrameId: defaults.frameId,
        activeWatermarkId: defaults.watermarkPresetId,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: 'Failed to load camera: $e');
    }
  }

  // ── Panel management ──

  void togglePanel(String panelId) {
    if (state.activePanel == panelId) {
      state = state.copyWith(clearPanel: true, showTopMenu: false);
    } else {
      state = state.copyWith(activePanel: panelId, showTopMenu: false);
    }
  }

  void closeAllPanels() {
    state = state.copyWith(clearPanel: true, showTopMenu: false);
  }

  void toggleTopMenu() {
    state = state.copyWith(
      showTopMenu: !state.showTopMenu,
      clearPanel: true,
    );
  }

  // ── Selection setters ──

  void selectFilter(String id) {
    state = state.copyWith(activeFilterId: id);
  }

  void selectLens(String id) {
    // 反选：再次点击已激活的镜头时，回到相机默认镜头
    final defaultLensId = state.camera?.defaultSelection.lensId ?? 'std';
    if (state.activeLensId == id && id != defaultLensId) {
      state = state.copyWith(activeLensId: defaultLensId);
    } else {
      state = state.copyWith(activeLensId: id);
    }
    // Notify native layer about lens optical change
    _ref.read(cameraServiceProvider.notifier).setPreset(
      // We pass lens id as part of preset metadata
      // The native layer uses this for zoom hint
      _buildNativePreset(),
    );
  }

  void selectRatio(String id) {
    state = state.copyWith(activeRatioId: id);
  }

  void selectFrame(String id) {
    state = state.copyWith(activeFrameId: id);
  }

  void selectWatermark(String id) {
    state = state.copyWith(activeWatermarkId: id);
  }

  // ── Camera controls ──

  void setTemperature(double value) {
    state = state.copyWith(temperatureOffset: value);
  }

  void setExposure(double value) {
    state = state.copyWith(exposureValue: value);
  }

  void toggleGrid() {
    state = state.copyWith(gridEnabled: !state.gridEnabled);
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

  Future<void> switchCamera() async {
    state = state.copyWith(isFrontCamera: !state.isFrontCamera);
    await _ref.read(cameraServiceProvider.notifier).switchLens();
  }

  // ── Take photo ──

  Future<String?> takePhoto() async {
    if (state.isTakingPhoto) return null;
    state = state.copyWith(isTakingPhoto: true);
    HapticFeedback.mediumImpact();

    try {
      // Handle timer
      if (state.timerSeconds > 0) {
        await Future.delayed(Duration(seconds: state.timerSeconds));
      }

      final _photoResult = await _ref.read(cameraServiceProvider.notifier).takePhoto();
      final path = _photoResult?['filePath'] as String?;

      if (path != null) {
        state = state.copyWith(showCaptureFlash: true);
        await Future.delayed(const Duration(milliseconds: 150));
        state = state.copyWith(showCaptureFlash: false);
        HapticFeedback.lightImpact();

        // Post-process: ratio crop + frame + watermark
        if (state.camera != null) {
          try {
            final pipeline = CapturePipeline(camera: state.camera!);
            final result = await pipeline.process(
              imagePath: path,
              selectedRatioId: state.activeRatioId ?? '',
              selectedFrameId: state.activeFrameId ?? '',
              selectedWatermarkId: state.activeWatermarkId ?? '',
              watermarkStyleOverride: state.watermarkStyle,
            );
            if (result != null) {
              await File(path).writeAsBytes(result.bytes);
            }
          } catch (e) {
            // Post-processing failed, keep original
          }
        }
      }

      return path;
    } finally {
      state = state.copyWith(isTakingPhoto: false);
    }
  }

  // ── Helpers ──

  // Build a minimal Preset object for native layer compatibility
  dynamic _buildNativePreset() {
    // Return a simple object that CameraService.setPreset can handle
    // In the current architecture, setPreset takes a Preset model
    // We'll just use a no-op here since lens selection is visual-only
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider
// ─────────────────────────────────────────────────────────────────────────────

final grdCameraProvider =
    StateNotifierProvider<GrdCameraNotifier, GrdCameraState>((ref) {
  return GrdCameraNotifier(ref);
});
