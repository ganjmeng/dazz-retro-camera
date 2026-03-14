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
    this.activePanel,
    this.gridEnabled = false,
    this.showTopMenu = false,
    this.showCameraManager = false,
    this.flashMode = 'off',
    this.timerSeconds = 0,
    this.isFrontCamera = false,
    this.isTakingPhoto = false,
    this.showCaptureFlash = false,
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
    String? activePanel,
    bool? gridEnabled,
    bool? showTopMenu,
    bool? showCameraManager,
    String? flashMode,
    int? timerSeconds,
    bool? isFrontCamera,
    bool? isTakingPhoto,
    bool? showCaptureFlash,
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
      activePanel: clearPanel ? null : (activePanel ?? this.activePanel),
      gridEnabled: gridEnabled ?? this.gridEnabled,
      showTopMenu: showTopMenu ?? this.showTopMenu,
      showCameraManager: showCameraManager ?? this.showCameraManager,
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

  Future<void> flipCamera() async {
    state = state.copyWith(isFrontCamera: !state.isFrontCamera);
    await _ref.read(cameraServiceProvider.notifier).switchLens();
  }

  // ── Take photo ──

  Future<String?> takePhoto() async {
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
        // path is in app cache dir (absolute file path), readable by dart:io File
        if (state.camera != null) {
          try {
            debugPrint('[CameraNotifier] Starting post-process: ratio=${state.activeRatioId}, frame=${state.activeFrameId}, wm=${state.activeWatermarkId}');
            final pipeline = CapturePipeline(camera: state.camera!);
            final processed = await pipeline.process(
              imagePath: path,
              selectedRatioId: state.activeRatioId ?? '',
              selectedFrameId: state.activeFrameId ?? '',
              selectedWatermarkId: state.activeWatermarkId ?? '',
              renderParams: state.renderParams,
            );
            if (processed != null) {
              // Write processed bytes back to the cache file
              await File(path).writeAsBytes(processed);
              debugPrint('[CameraNotifier] Post-process done, wrote ${processed.length} bytes to $path');
            } else {
              debugPrint('[CameraNotifier] Post-process returned null, keeping original');
            }
          } catch (e, st) {
            // Post-processing failed, keep original
            debugPrint('[CameraNotifier] Post-process error: $e\n$st');
          }
        }
        // Save processed file to gallery (DCIM/DAZZ) via native MediaStore
        try {
          final galleryUri = await _ref.read(cameraServiceProvider.notifier).saveToGallery(path);
          debugPrint('[CameraNotifier] Saved to gallery: $galleryUri');
        } catch (e) {
          debugPrint('[CameraNotifier] saveToGallery error: $e');
        }
      }

      return path;
    } finally {
      state = state.copyWith(isTakingPhoto: false);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider
// ─────────────────────────────────────────────────────────────────────────────

final cameraAppProvider =
    StateNotifierProvider<CameraAppNotifier, CameraAppState>((ref) {
  return CameraAppNotifier(ref);
});
