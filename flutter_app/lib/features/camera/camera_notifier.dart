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
    // 反选：再次点击已激活的镜头时，回到相机默认镜头
    final defaultLensId = state.camera?.defaultSelection.lensId ?? 'std';
    final String newLensId;
    if (state.activeLensId == id && id != defaultLensId) {
      newLensId = defaultLensId;
    } else {
      newLensId = id;
    }
    state = state.copyWith(activeLensId: newLensId);
    // 通知原生层更新镜头参数（在 GPU shader 中实现，零 CPU 开销）
    final newLens = state.camera?.lensById(newLensId);
    final distortion = newLens?.distortion ?? 0.0;
    final vignette = newLens?.vignette ?? 0.0;
    final zoomFactor = newLens?.zoomFactor ?? 1.0;
    final fisheyeMode = newLens?.fisheyeMode ?? false;
    _ref.read(cameraServiceProvider.notifier).updateLensParams(
      distortion: distortion,
      vignette: vignette,
      zoomFactor: zoomFactor,
      fisheyeMode: fisheyeMode,
    );
  }

  void selectRatio(String id) {
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
    state = state.copyWith(
      minimapEnabled: !state.minimapEnabled,
      zoomLevel: 1.0,
      showZoomSlider: false,
    );
    _ref.read(cameraServiceProvider.notifier).setZoom(1.0);
  }

  /// 切换位置信息开关
  /// 返回切换后的状态和权限结果
  /// 切换调试信息浮层
  void toggleDebugOverlay() {
    state = state.copyWith(showDebugOverlay: !state.showDebugOverlay);
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
      final path = await _ref.read(cameraServiceProvider.notifier).takePhoto();

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
