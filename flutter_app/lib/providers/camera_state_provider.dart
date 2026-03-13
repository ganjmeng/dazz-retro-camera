import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/camera_definition.dart';
import '../services/image_processor.dart';

// ─── 相机应用全局状态 ─────────────────────────────────────────────────────────
class CameraAppState {
  // 相机列表
  final List<CameraDefinition> cameras;
  final bool camerasLoaded;

  // 当前激活的相机选中状态
  final CameraSelectionState? selection;

  // 硬件相机状态
  final bool isInitialized;
  final bool isFrontCamera;
  final String flashMode; // 'off' | 'on' | 'auto'
  final int timerSeconds; // 0 / 3 / 10
  final double exposureValue;
  final bool gridEnabled;
  final bool isTakingPhoto;

  // 活跃面板
  final String? activePanel; // null | 'film' | 'lens' | 'paper' | 'ratio' | 'watermark'

  const CameraAppState({
    this.cameras = const [],
    this.camerasLoaded = false,
    this.selection,
    this.isInitialized = false,
    this.isFrontCamera = false,
    this.flashMode = 'off',
    this.timerSeconds = 0,
    this.exposureValue = 0.0,
    this.gridEnabled = false,
    this.isTakingPhoto = false,
    this.activePanel,
  });

  CameraAppState copyWith({
    List<CameraDefinition>? cameras,
    bool? camerasLoaded,
    CameraSelectionState? selection,
    bool? isInitialized,
    bool? isFrontCamera,
    String? flashMode,
    int? timerSeconds,
    double? exposureValue,
    bool? gridEnabled,
    bool? isTakingPhoto,
    String? activePanel,
    bool clearActivePanel = false,
    bool clearSelection = false,
  }) {
    return CameraAppState(
      cameras: cameras ?? this.cameras,
      camerasLoaded: camerasLoaded ?? this.camerasLoaded,
      selection: clearSelection ? null : (selection ?? this.selection),
      isInitialized: isInitialized ?? this.isInitialized,
      isFrontCamera: isFrontCamera ?? this.isFrontCamera,
      flashMode: flashMode ?? this.flashMode,
      timerSeconds: timerSeconds ?? this.timerSeconds,
      exposureValue: exposureValue ?? this.exposureValue,
      gridEnabled: gridEnabled ?? this.gridEnabled,
      isTakingPhoto: isTakingPhoto ?? this.isTakingPhoto,
      activePanel: clearActivePanel ? null : (activePanel ?? this.activePanel),
    );
  }

  /// 当前激活相机
  CameraDefinition? get activeCamera => selection?.camera;

  /// 当前选中的 Film
  FilmOption? get selectedFilm => selection?.selectedFilm;

  /// 当前选中的 Lens
  LensOption? get selectedLens => selection?.selectedLens;

  /// 当前选中的 Paper
  PaperOption? get selectedPaper => selection?.selectedPaper;

  /// 当前选中的 Ratio
  RatioOption? get selectedRatio => selection?.selectedRatio;

  /// 当前选中的 Watermark
  WatermarkOption? get selectedWatermark => selection?.selectedWatermark;

  /// 当前宽高比
  double get aspectRatio => selection?.aspectRatio ?? (4 / 3);

  /// 当前比例字符串
  String get ratioValue => selection?.ratioValue ?? '4:3';
}

// ─── 相机状态 Notifier ────────────────────────────────────────────────────────
class CameraStateNotifier extends StateNotifier<CameraAppState> {
  static const _methodChannel = MethodChannel('com.retrocam.app/camera_control');
  static const _eventChannel = EventChannel('com.retrocam.app/camera_events');

  CameraStateNotifier() : super(const CameraAppState()) {
    _listenToEvents();
  }

  void _listenToEvents() {
    _eventChannel.receiveBroadcastStream().listen((event) {
      if (event is Map) {
        final type = event['type'] as String?;
        if (type == 'onCameraReady') {
          state = state.copyWith(isInitialized: true);
        }
      }
    }, onError: (_) {});
  }

  // ── 加载相机列表 ────────────────────────────────────────────────────────────
  static const _cameraAssets = [
    'assets/presets/ccd_2005.json',
    'assets/presets/polaroid_classic.json',
    'assets/presets/fuji_superia.json',
    'assets/presets/kodak_gold.json',
    'assets/presets/disposable_flash.json',
    'assets/presets/vhs_camcorder.json',
    'assets/presets/film_scan.json',
    'assets/presets/dv2003.json',
    'assets/presets/portrait_soft.json',
    'assets/presets/ccd_night.json',
    'assets/presets/lomo_lca.json',
  ];

  Future<void> loadCameras() async {
    if (state.camerasLoaded) return;
    final cameras = <CameraDefinition>[];
    for (final path in _cameraAssets) {
      try {
        final jsonStr = await rootBundle.loadString(path);
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;
        cameras.add(CameraDefinition.fromJson(json));
      } catch (e) {
        // ignore missing files
      }
    }
    if (cameras.isEmpty) return;

    final firstCamera = cameras.first;
    final selection = CameraSelectionState.fromCamera(firstCamera);

    state = state.copyWith(
      cameras: cameras,
      camerasLoaded: true,
      selection: selection,
    );

    // 通知原生层当前相机配置
    await _syncPresetToNative(selection);
  }

  // ── 切换相机 ────────────────────────────────────────────────────────────────
  Future<void> selectCamera(CameraDefinition camera) async {
    final selection = CameraSelectionState.fromCamera(camera);
    state = state.copyWith(selection: selection, clearActivePanel: true);
    await _syncPresetToNative(selection);
  }

  // ── 选择 Film ───────────────────────────────────────────────────────────────
  Future<void> selectFilm(FilmOption film) async {
    final sel = state.selection;
    if (sel == null) return;
    final newSel = sel.copyWith(selectedFilm: film);
    state = state.copyWith(selection: newSel);
    await _syncPresetToNative(newSel);
  }

  // ── 选择 Lens ───────────────────────────────────────────────────────────────
  Future<void> selectLens(LensOption lens) async {
    final sel = state.selection;
    if (sel == null) return;
    final newSel = sel.copyWith(selectedLens: lens);
    state = state.copyWith(selection: newSel);
    await _syncPresetToNative(newSel);
  }

  // ── 选择 Paper ──────────────────────────────────────────────────────────────
  void selectPaper(PaperOption paper) {
    final sel = state.selection;
    if (sel == null) return;
    state = state.copyWith(selection: sel.copyWith(selectedPaper: paper));
  }

  // ── 选择 Ratio ──────────────────────────────────────────────────────────────
  Future<void> selectRatio(RatioOption ratio) async {
    final sel = state.selection;
    if (sel == null) return;
    final newSel = sel.copyWith(selectedRatio: ratio);
    state = state.copyWith(selection: newSel);
    try {
      await _methodChannel.invokeMethod('setRatio', {'value': ratio.value});
    } catch (_) {}
  }

  // ── 选择 Watermark ──────────────────────────────────────────────────────────
  void selectWatermark(WatermarkOption watermark) {
    final sel = state.selection;
    if (sel == null) return;
    state = state.copyWith(selection: sel.copyWith(selectedWatermark: watermark));
  }

  // ── 切换面板 ────────────────────────────────────────────────────────────────
  void togglePanel(String panel) {
    if (state.activePanel == panel) {
      state = state.copyWith(clearActivePanel: true);
    } else {
      state = state.copyWith(activePanel: panel);
    }
  }

  void closePanel() {
    state = state.copyWith(clearActivePanel: true);
  }

  // ── 初始化相机 ──────────────────────────────────────────────────────────────
  Future<void> initCamera() async {
    try {
      final result = await _methodChannel.invokeMethod<Map>('initCamera', {
        'lens': state.isFrontCamera ? 'front' : 'back',
      });
      if (result != null) {
        state = state.copyWith(isInitialized: true);
      }
    } catch (e) {
      // ignore
    }
  }

  // ── 切换前后摄 ──────────────────────────────────────────────────────────────
  Future<void> switchLens() async {
    final isFront = !state.isFrontCamera;
    state = state.copyWith(isFrontCamera: isFront);
    try {
      await _methodChannel.invokeMethod('switchLens', {
        'lens': isFront ? 'front' : 'back',
      });
    } catch (_) {}
  }

  // ── 切换闪光灯 ──────────────────────────────────────────────────────────────
  Future<void> cycleFlash() async {
    final modes = ['off', 'on', 'auto'];
    final idx = modes.indexOf(state.flashMode);
    final next = modes[(idx + 1) % modes.length];
    state = state.copyWith(flashMode: next);
    try {
      await _methodChannel.invokeMethod('setFlash', {'mode': next});
    } catch (_) {}
  }

  // ── 切换计时器 ──────────────────────────────────────────────────────────────
  void cycleTimer() {
    final timers = [0, 3, 10];
    final idx = timers.indexOf(state.timerSeconds);
    state = state.copyWith(timerSeconds: timers[(idx + 1) % timers.length]);
  }

  // ── 切换网格 ────────────────────────────────────────────────────────────────
  void toggleGrid() {
    state = state.copyWith(gridEnabled: !state.gridEnabled);
  }

  // ── 调整曝光 ────────────────────────────────────────────────────────────────
  Future<void> setExposure(double ev) async {
    state = state.copyWith(exposureValue: ev);
    try {
      await _methodChannel.invokeMethod('setExposure', {'ev': ev});
    } catch (_) {}
  }

  // ── 拍照 ────────────────────────────────────────────────────────────────────
  Future<String?> takePhoto() async {
    if (state.isTakingPhoto) return null;
    state = state.copyWith(isTakingPhoto: true);
    try {
      // 构建当前选中参数传给原生层
      final sel = state.selection;
      final Map<String, dynamic> params = {};
      if (sel != null) {
        params['cameraId'] = sel.camera.id;
        params['filmId'] = sel.selectedFilm?.id;
        params['lensId'] = sel.selectedLens?.id;
        params['paperId'] = sel.selectedPaper?.id;
        params['ratioValue'] = sel.ratioValue;
        params['watermarkId'] = sel.selectedWatermark?.id;
        params['watermarkType'] = sel.selectedWatermark?.type;
        params['watermarkColor'] = sel.selectedWatermark?.rendering.color;
        params['watermarkPosition'] = sel.selectedWatermark?.rendering.position;
        params['watermarkOpacity'] = sel.selectedWatermark?.rendering.opacity;
        params['watermarkFontSize'] = sel.selectedWatermark?.rendering.fontSize;
        params['watermarkText'] = sel.selectedWatermark?.rendering.textFormat;
        params['paperFrameAsset'] = sel.selectedPaper?.rendering.frameAsset;
        params['paperBgColor'] = sel.selectedPaper?.rendering.backgroundColor;
        params['paperMarginTop'] = sel.selectedPaper?.rendering.marginTop;
        params['paperMarginBottom'] = sel.selectedPaper?.rendering.marginBottom;
        params['paperMarginLeft'] = sel.selectedPaper?.rendering.marginLeft;
        params['paperMarginRight'] = sel.selectedPaper?.rendering.marginRight;
        // Film rendering params
        final film = sel.selectedFilm;
        if (film != null) {
          params['grainIntensity'] = film.rendering.grainIntensity;
          params['chromaticAberration'] = film.rendering.chromaticAberration;
          params['vignetteAmount'] = film.rendering.vignetteAmount;
          params['jpegArtifacts'] = film.rendering.jpegArtifacts;
          params['temperatureShift'] = film.rendering.temperatureShift;
          params['fadeAmount'] = film.rendering.fadeAmount;
        }
        // Lens rendering params
        final lens = sel.selectedLens;
        if (lens != null) {
          params['lensVignette'] = lens.rendering.vignette;
          params['lensBloom'] = lens.rendering.bloom;
          params['lensDistortion'] = lens.rendering.distortion;
          params['lensBlurRadius'] = lens.rendering.blurRadius;
        }
        // Base model params
        final bm = sel.camera.baseModel;
        params['baseContrast'] = bm.color.contrast;
        params['baseSaturation'] = bm.color.saturation;
        params['baseTemperature'] = bm.color.temperature;
        params['baseBrightness'] = bm.color.brightness;
        params['halation'] = bm.highlight.halation;
        params['exportJpegQuality'] = sel.camera.exportPolicy.jpegQuality;
        params['applyPaperComposite'] = sel.camera.exportPolicy.applyPaperComposite;
        params['applyWatermark'] = sel.camera.exportPolicy.applyWatermark;
        params['applyRatioCrop'] = sel.camera.exportPolicy.applyRatioCrop;
      }

      final result = await _methodChannel.invokeMethod<Map>('takePhoto', params);
      final rawPath = result?['filePath'] as String?;
      if (rawPath == null) return null;

      // ── Flutter 层图像处理管线 ──────────────────────────────────────────────
      // 读取原始图片字节（支持 content:// URI 和 file:// 路径）
      Uint8List? rawBytes;
      try {
        if (rawPath.startsWith('content://')) {
          // Android 10+ MediaStore URI — 通过原生读取
          final readResult = await _methodChannel.invokeMethod<Map>('readImageBytes', {'uri': rawPath});
          final byteList = readResult?['bytes'];
          if (byteList is List) {
            rawBytes = Uint8List.fromList(byteList.cast<int>());
          }
        } else {
          final file = File(rawPath.replaceFirst('file://', ''));
          if (await file.exists()) {
            rawBytes = await file.readAsBytes();
          }
        }
      } catch (_) {}

      if (rawBytes != null && sel != null) {
        // 应用捕获管线（比例裁剪 → 相纸 → 水印）
        final processed = await ImageProcessor.processCapture(
          rawImageBytes: rawBytes,
          selection: sel,
        );
        if (processed != null) {
          // 将处理后的图片写回（覆盖原文件或创建新文件）
          try {
            if (rawPath.startsWith('content://')) {
              // 通过原生层写回 MediaStore
              await _methodChannel.invokeMethod('writeImageBytes', {
                'uri': rawPath,
                'bytes': processed,
              });
            } else {
              final file = File(rawPath.replaceFirst('file://', ''));
              await file.writeAsBytes(processed);
            }
          } catch (_) {}
        }
      }

      return rawPath;
    } catch (e) {
      return null;
    } finally {
      state = state.copyWith(isTakingPhoto: false);
    }
  }

  // ── 同步 Preset 到原生层 ────────────────────────────────────────────────────
  Future<void> _syncPresetToNative(CameraSelectionState sel) async {
    try {
      final film = sel.selectedFilm;
      final lens = sel.selectedLens;
      final bm = sel.camera.baseModel;

      await _methodChannel.invokeMethod('setPreset', {
        'id': sel.camera.id,
        'name': sel.camera.name,
        // Film params
        'filmId': film?.id,
        'grainIntensity': film?.rendering.grainIntensity ?? 0.0,
        'chromaticAberration': film?.rendering.chromaticAberration ?? 0.0,
        'vignetteAmount': film?.rendering.vignetteAmount ?? 0.0,
        'jpegArtifacts': film?.rendering.jpegArtifacts ?? 0.0,
        'temperatureShift': film?.rendering.temperatureShift ?? 0.0,
        'fadeAmount': film?.rendering.fadeAmount ?? 0.0,
        // Lens params
        'lensId': lens?.id,
        'lensVignette': lens?.rendering.vignette ?? 0.0,
        'lensBloom': lens?.rendering.bloom ?? 0.0,
        'lensDistortion': lens?.rendering.distortion ?? 0.0,
        'lensBlurRadius': lens?.rendering.blurRadius ?? 0.0,
        // Base model
        'baseContrast': bm.color.contrast,
        'baseSaturation': bm.color.saturation,
        'baseTemperature': bm.color.temperature,
        'baseBrightness': bm.color.brightness,
        'halation': bm.highlight.halation,
      });
    } catch (_) {}
  }

  // ── 获取相机预览 textureId ──────────────────────────────────────────────────
  Future<int?> getTextureId() async {
    try {
      final result = await _methodChannel.invokeMethod<Map>('getTextureId');
      return result?['textureId'] as int?;
    } catch (_) {
      return null;
    }
  }
}

// ─── Providers ────────────────────────────────────────────────────────────────
final cameraStateProvider =
    StateNotifierProvider<CameraStateNotifier, CameraAppState>(
  (ref) => CameraStateNotifier(),
);
