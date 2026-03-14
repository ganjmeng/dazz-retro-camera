// camera_definition.dart
// Final CameraDefinition model matching the Final Consolidated Spec.
// All cameras are loaded from JSON assets — no code changes needed to add new cameras.

import 'dart:convert';
import 'package:flutter/services.dart';

// ─────────────────────────────────────────────
// Top-level model
// ─────────────────────────────────────────────

class CameraDefinition {
  final String id;
  final String name;
  final String category;
  final String mode;
  final bool supportsPhoto;
  final bool supportsVideo;
  final String? focalLengthLabel;

  final SensorConfig sensor;
  final DefaultLook defaultLook;
  final CameraModules modules;
  final DefaultSelection defaultSelection;
  final UiCapabilities uiCapabilities;
  final PreviewCapabilities previewCapabilities;
  final PreviewPolicy previewPolicy;
  final ExportPolicy exportPolicy;
  final VideoConfig videoConfig;
  final CameraAssets assets;
  final CameraMeta meta;

  const CameraDefinition({
    required this.id,
    required this.name,
    required this.category,
    required this.mode,
    required this.supportsPhoto,
    required this.supportsVideo,
    this.focalLengthLabel,
    required this.sensor,
    required this.defaultLook,
    required this.modules,
    required this.defaultSelection,
    required this.uiCapabilities,
    required this.previewCapabilities,
    required this.previewPolicy,
    required this.exportPolicy,
    required this.videoConfig,
    required this.assets,
    required this.meta,
  });

  factory CameraDefinition.fromJson(Map<String, dynamic> json) {
    return CameraDefinition(
      id: json['id'] as String,
      name: json['name'] as String,
      category: json['category'] as String,
      mode: json['mode'] as String,
      supportsPhoto: json['supportsPhoto'] as bool? ?? true,
      supportsVideo: json['supportsVideo'] as bool? ?? false,
      focalLengthLabel: json['focalLengthLabel'] as String?,
      sensor: SensorConfig.fromJson(json['sensor'] as Map<String, dynamic>),
      defaultLook: DefaultLook.fromJson(json['defaultLook'] as Map<String, dynamic>),
      modules: CameraModules.fromJson(json['modules'] as Map<String, dynamic>),
      defaultSelection: DefaultSelection.fromJson(json['defaultSelection'] as Map<String, dynamic>),
      uiCapabilities: UiCapabilities.fromJson(json['uiCapabilities'] as Map<String, dynamic>),
      previewCapabilities: PreviewCapabilities.fromJson(json['previewCapabilities'] as Map<String, dynamic>),
      previewPolicy: PreviewPolicy.fromJson(json['previewPolicy'] as Map<String, dynamic>),
      exportPolicy: ExportPolicy.fromJson(json['exportPolicy'] as Map<String, dynamic>),
      videoConfig: VideoConfig.fromJson(json['videoConfig'] as Map<String, dynamic>),
      assets: CameraAssets.fromJson(json['assets'] as Map<String, dynamic>),
      meta: CameraMeta.fromJson(json['meta'] as Map<String, dynamic>),
    );
  }

  static Future<CameraDefinition> loadFromAsset(String assetPath) async {
    final jsonStr = await rootBundle.loadString(assetPath);
    final json = jsonDecode(jsonStr) as Map<String, dynamic>;
    return CameraDefinition.fromJson(json);
  }

  static CameraDefinition fromJsonString(String jsonStr) {
    final json = jsonDecode(jsonStr) as Map<String, dynamic>;
    return CameraDefinition.fromJson(json);
  }

  FilterDefinition? filterById(String? id) {
    if (id == null) return null;
    try { return modules.filters.firstWhere((f) => f.id == id); } catch (_) { return null; }
  }

  LensDefinition? lensById(String? id) {
    if (id == null) return null;
    try { return modules.lenses.firstWhere((l) => l.id == id); } catch (_) { return null; }
  }

  RatioDefinition? ratioById(String? id) {
    if (id == null) return null;
    try { return modules.ratios.firstWhere((r) => r.id == id); } catch (_) { return null; }
  }

  FrameDefinition? frameById(String? id) {
    if (id == null) return null;
    try { return modules.frames.firstWhere((f) => f.id == id); } catch (_) { return null; }
  }

  WatermarkPreset? watermarkById(String? id) {
    if (id == null) return null;
    try { return modules.watermarks.presets.firstWhere((w) => w.id == id); } catch (_) { return null; }
  }

  bool isFrameEnabled(String? ratioId) {
    if (!uiCapabilities.enableFrame) return false;
    return ratioById(ratioId)?.supportsFrame ?? false;
  }
}

// ─────────────────────────────────────────────
// Sensor
// ─────────────────────────────────────────────

class SensorConfig {
  final String type;
  final int dynamicRange;
  final double baseNoise;
  final int colorDepth;

  const SensorConfig({required this.type, required this.dynamicRange, required this.baseNoise, required this.colorDepth});

  factory SensorConfig.fromJson(Map<String, dynamic> json) => SensorConfig(
    type: json['type'] as String,
    dynamicRange: (json['dynamicRange'] as num).toInt(),
    baseNoise: (json['baseNoise'] as num).toDouble(),
    colorDepth: (json['colorDepth'] as num).toInt(),
  );
}

// ─────────────────────────────────────────────
// DefaultLook
// ─────────────────────────────────────────────

class DefaultLook {
  final String? baseLut;
  final double temperature;
  final double contrast;
  final double saturation;
  final double vignette;
  final double distortion;
  final double chromaticAberration;
  final double bloom;
  final double flare;

  const DefaultLook({
    this.baseLut,
    required this.temperature,
    required this.contrast,
    required this.saturation,
    required this.vignette,
    required this.distortion,
    required this.chromaticAberration,
    required this.bloom,
    required this.flare,
  });

  /// 占位默认値（相机 JSON 未加载时使用）
  factory DefaultLook.empty() => const DefaultLook(
    temperature: 0,
    contrast: 0,
    saturation: 0,
    vignette: 0,
    distortion: 0,
    chromaticAberration: 0,
    bloom: 0,
    flare: 0,
  );

  factory DefaultLook.fromJson(Map<String, dynamic> json) => DefaultLook(
    baseLut: json['baseLut'] as String?,
    temperature: (json['temperature'] as num).toDouble(),
    contrast: (json['contrast'] as num).toDouble(),
    saturation: (json['saturation'] as num).toDouble(),
    vignette: (json['vignette'] as num).toDouble(),
    distortion: (json['distortion'] as num).toDouble(),
    chromaticAberration: (json['chromaticAberration'] as num).toDouble(),
    bloom: (json['bloom'] as num).toDouble(),
    flare: (json['flare'] as num).toDouble(),
  );
}

// ─────────────────────────────────────────────
// Modules
// ─────────────────────────────────────────────

class CameraModules {
  final List<FilterDefinition> filters;
  final List<LensDefinition> lenses;
  final List<RatioDefinition> ratios;
  final List<FrameDefinition> frames;
  final WatermarkModule watermarks;
  final List<dynamic> extras;

  const CameraModules({required this.filters, required this.lenses, required this.ratios, required this.frames, required this.watermarks, required this.extras});

  factory CameraModules.fromJson(Map<String, dynamic> json) => CameraModules(
    filters: (json['filters'] as List<dynamic>).map((e) => FilterDefinition.fromJson(e as Map<String, dynamic>)).toList(),
    lenses: (json['lenses'] as List<dynamic>).map((e) => LensDefinition.fromJson(e as Map<String, dynamic>)).toList(),
    ratios: (json['ratios'] as List<dynamic>).map((e) => RatioDefinition.fromJson(e as Map<String, dynamic>)).toList(),
    frames: (json['frames'] as List<dynamic>).map((e) => FrameDefinition.fromJson(e as Map<String, dynamic>)).toList(),
    watermarks: WatermarkModule.fromJson(json['watermarks'] as Map<String, dynamic>),
    extras: json['extras'] as List<dynamic>? ?? [],
  );
}

// ─────────────────────────────────────────────
// Filter
// ─────────────────────────────────────────────

class FilterDefinition {
  final String id;
  final String name;
  final String nameEn;
  final String? lut;
  final double contrast;
  final double saturation;
  final String grain;
  final String? thumbnail;

  const FilterDefinition({required this.id, required this.name, required this.nameEn, this.lut, required this.contrast, required this.saturation, required this.grain, this.thumbnail});

  factory FilterDefinition.fromJson(Map<String, dynamic> json) => FilterDefinition(
    id: json['id'] as String,
    name: json['name'] as String,
    nameEn: json['nameEn'] as String? ?? json['name'] as String,
    lut: json['lut'] as String?,
    contrast: (json['contrast'] as num?)?.toDouble() ?? 1.0,
    saturation: (json['saturation'] as num?)?.toDouble() ?? 1.0,
    grain: json['grain'] as String? ?? 'none',
    thumbnail: json['thumbnail'] as String?,
  );
}

// ─────────────────────────────────────────────
// Lens
// ─────────────────────────────────────────────

class LensDefinition {
  final String id;
  final String name;
  final String nameEn;
  final double zoomFactor; // 光学倍率，例如 1.0=x1, 2.0=x2
  final double vignette;
  final double distortion;
  final double chromaticAberration;
  final double bloom;
  final double flare;
  final double softFocus;
  final double refraction;
  final String? thumbnail;

  const LensDefinition({required this.id, required this.name, required this.nameEn, this.zoomFactor = 1.0, required this.vignette, required this.distortion, required this.chromaticAberration, required this.bloom, required this.flare, required this.softFocus, required this.refraction, this.thumbnail});

  factory LensDefinition.fromJson(Map<String, dynamic> json) => LensDefinition(
    id: json['id'] as String,
    name: json['name'] as String,
    nameEn: json['nameEn'] as String? ?? json['name'] as String,
    zoomFactor: (json['zoomFactor'] as num?)?.toDouble() ?? 1.0,
    vignette: (json['vignette'] as num?)?.toDouble() ?? 0.0,
    distortion: (json['distortion'] as num?)?.toDouble() ?? 0.0,
    chromaticAberration: (json['chromaticAberration'] as num?)?.toDouble() ?? 0.0,
    bloom: (json['bloom'] as num?)?.toDouble() ?? 0.0,
    flare: (json['flare'] as num?)?.toDouble() ?? 0.0,
    softFocus: (json['softFocus'] as num?)?.toDouble() ?? 0.0,
    refraction: (json['refraction'] as num?)?.toDouble() ?? 0.0,
    thumbnail: json['thumbnail'] as String?,
  );
}

// ─────────────────────────────────────────────
// Ratio
// ─────────────────────────────────────────────

class RatioDefinition {
  final String id;
  final String label;
  final int width;
  final int height;
  final bool supportsFrame;

  const RatioDefinition({required this.id, required this.label, required this.width, required this.height, required this.supportsFrame});

  double get aspectRatio => width / height;

  factory RatioDefinition.fromJson(Map<String, dynamic> json) => RatioDefinition(
    id: json['id'] as String,
    label: json['label'] as String,
    width: (json['width'] as num).toInt(),
    height: (json['height'] as num).toInt(),
    supportsFrame: json['supportsFrame'] as bool? ?? false,
  );
}

// ─────────────────────────────────────────────
// Frame
// ─────────────────────────────────────────────

class FrameDefinition {
  final String id;
  final String name;
  final String nameEn;
  final String? asset;
  final String backgroundColor;
  final FrameInset inset;
  final List<String> supportedRatios;
  final String? thumbnail;

  const FrameDefinition({required this.id, required this.name, required this.nameEn, this.asset, required this.backgroundColor, required this.inset, required this.supportedRatios, this.thumbnail});

  factory FrameDefinition.fromJson(Map<String, dynamic> json) => FrameDefinition(
    id: json['id'] as String,
    name: json['name'] as String,
    nameEn: json['nameEn'] as String? ?? json['name'] as String,
    asset: json['asset'] as String?,
    backgroundColor: json['backgroundColor'] as String? ?? '#FFFFFF',
    inset: FrameInset.fromJson(json['inset'] as Map<String, dynamic>? ?? {}),
    supportedRatios: (json['supportedRatios'] as List<dynamic>?)?.map((e) => e as String).toList() ?? [],
    thumbnail: json['thumbnail'] as String?,
  );
}

class FrameInset {
  final double top;
  final double right;
  final double bottom;
  final double left;

  const FrameInset({required this.top, required this.right, required this.bottom, required this.left});

  factory FrameInset.fromJson(Map<String, dynamic> json) => FrameInset(
    top: (json['top'] as num?)?.toDouble() ?? 0,
    right: (json['right'] as num?)?.toDouble() ?? 0,
    bottom: (json['bottom'] as num?)?.toDouble() ?? 0,
    left: (json['left'] as num?)?.toDouble() ?? 0,
  );
}

// ─────────────────────────────────────────────
// Watermark
// ─────────────────────────────────────────────

class WatermarkModule {
  final List<WatermarkPreset> presets;
  final WatermarkEditor editor;

  const WatermarkModule({required this.presets, required this.editor});

  factory WatermarkModule.fromJson(Map<String, dynamic> json) => WatermarkModule(
    presets: (json['presets'] as List<dynamic>).map((e) => WatermarkPreset.fromJson(e as Map<String, dynamic>)).toList(),
    editor: WatermarkEditor.fromJson(json['editor'] as Map<String, dynamic>? ?? {}),
  );
}

class WatermarkPreset {
  final String id;
  final String name;
  final String? color;
  final String? position;
  final double? fontSize;
  final String? fontFamily;

  const WatermarkPreset({required this.id, required this.name, this.color, this.position, this.fontSize, this.fontFamily});

  bool get isNone => id == 'none';

  factory WatermarkPreset.fromJson(Map<String, dynamic> json) => WatermarkPreset(
    id: json['id'] as String,
    name: json['name'] as String,
    color: json['color'] as String?,
    position: json['position'] as String?,
    fontSize: (json['fontSize'] as num?)?.toDouble(),
    fontFamily: json['fontFamily'] as String?,
  );
}

class WatermarkEditor {
  final bool allowColorChange;
  final bool allowPositionChange;
  final bool allowSizeChange;
  final bool allowOrientationChange;

  const WatermarkEditor({required this.allowColorChange, required this.allowPositionChange, required this.allowSizeChange, required this.allowOrientationChange});

  factory WatermarkEditor.fromJson(Map<String, dynamic> json) => WatermarkEditor(
    allowColorChange: json['allowColorChange'] as bool? ?? false,
    allowPositionChange: json['allowPositionChange'] as bool? ?? false,
    allowSizeChange: json['allowSizeChange'] as bool? ?? false,
    allowOrientationChange: json['allowOrientationChange'] as bool? ?? false,
  );
}

// ─────────────────────────────────────────────
// DefaultSelection
// ─────────────────────────────────────────────

class DefaultSelection {
  final String? filterId;
  final String? lensId;
  final String? ratioId;
  final String? frameId;
  final String? watermarkPresetId;
  final String? extraId;

  const DefaultSelection({this.filterId, this.lensId, this.ratioId, this.frameId, this.watermarkPresetId, this.extraId});

  factory DefaultSelection.fromJson(Map<String, dynamic> json) => DefaultSelection(
    filterId: json['filterId'] as String?,
    lensId: json['lensId'] as String?,
    ratioId: json['ratioId'] as String?,
    frameId: json['frameId'] as String?,
    watermarkPresetId: json['watermarkPresetId'] as String?,
    extraId: json['extraId'] as String?,
  );
}

// ─────────────────────────────────────────────
// Capabilities & Policies
// ─────────────────────────────────────────────

class UiCapabilities {
  final bool enableFilter;
  final bool enableLens;
  final bool enableRatio;
  final bool enableFrame;
  final bool enableWatermark;
  final bool enableExtra;

  const UiCapabilities({required this.enableFilter, required this.enableLens, required this.enableRatio, required this.enableFrame, required this.enableWatermark, required this.enableExtra});

  factory UiCapabilities.fromJson(Map<String, dynamic> json) => UiCapabilities(
    enableFilter: json['enableFilter'] as bool? ?? true,
    enableLens: json['enableLens'] as bool? ?? true,
    enableRatio: json['enableRatio'] as bool? ?? true,
    enableFrame: json['enableFrame'] as bool? ?? true,
    enableWatermark: json['enableWatermark'] as bool? ?? true,
    enableExtra: json['enableExtra'] as bool? ?? false,
  );
}

class PreviewCapabilities {
  final bool allowSmallViewport;
  final bool allowGridOverlay;
  final bool allowZoom;
  final bool allowImportImage;
  final bool allowTimer;
  final bool allowFlash;

  const PreviewCapabilities({required this.allowSmallViewport, required this.allowGridOverlay, required this.allowZoom, required this.allowImportImage, required this.allowTimer, required this.allowFlash});

  factory PreviewCapabilities.fromJson(Map<String, dynamic> json) => PreviewCapabilities(
    allowSmallViewport: json['allowSmallViewport'] as bool? ?? true,
    allowGridOverlay: json['allowGridOverlay'] as bool? ?? true,
    allowZoom: json['allowZoom'] as bool? ?? true,
    allowImportImage: json['allowImportImage'] as bool? ?? true,
    allowTimer: json['allowTimer'] as bool? ?? true,
    allowFlash: json['allowFlash'] as bool? ?? true,
  );
}

class PreviewPolicy {
  final bool enableLut;
  final bool enableTemperature;
  final bool enableContrast;
  final bool enableSaturation;
  final bool enableVignette;
  final bool enableLightLensEffect;
  final bool enableGrain;
  final bool enableBloom;
  final bool enableChromaticAberration;
  final bool enableFrameComposite;
  final bool enableWatermarkComposite;

  const PreviewPolicy({required this.enableLut, required this.enableTemperature, required this.enableContrast, required this.enableSaturation, required this.enableVignette, required this.enableLightLensEffect, required this.enableGrain, required this.enableBloom, required this.enableChromaticAberration, required this.enableFrameComposite, required this.enableWatermarkComposite});

  /// 占位默认値（相机 JSON 未加载时使用）
  factory PreviewPolicy.empty() => const PreviewPolicy(
    enableLut: false,
    enableTemperature: false,
    enableContrast: false,
    enableSaturation: false,
    enableVignette: false,
    enableLightLensEffect: false,
    enableGrain: false,
    enableBloom: false,
    enableChromaticAberration: false,
    enableFrameComposite: false,
    enableWatermarkComposite: false,
  );

  factory PreviewPolicy.fromJson(Map<String, dynamic> json) => PreviewPolicy(
    enableLut: json['enableLut'] as bool? ?? true,
    enableTemperature: json['enableTemperature'] as bool? ?? true,
    enableContrast: json['enableContrast'] as bool? ?? true,
    enableSaturation: json['enableSaturation'] as bool? ?? true,
    enableVignette: json['enableVignette'] as bool? ?? true,
    enableLightLensEffect: json['enableLightLensEffect'] as bool? ?? true,
    enableGrain: json['enableGrain'] as bool? ?? false,
    enableBloom: json['enableBloom'] as bool? ?? false,
    enableChromaticAberration: json['enableChromaticAberration'] as bool? ?? false,
    enableFrameComposite: json['enableFrameComposite'] as bool? ?? false,
    enableWatermarkComposite: json['enableWatermarkComposite'] as bool? ?? true,
  );
}

class ExportPolicy {
  final double jpegQuality;
  final bool applyRatioCrop;
  final bool applyFrameOnExport;
  final bool applyWatermarkOnExport;
  final bool preserveMetadata;

  const ExportPolicy({required this.jpegQuality, required this.applyRatioCrop, required this.applyFrameOnExport, required this.applyWatermarkOnExport, required this.preserveMetadata});

  factory ExportPolicy.fromJson(Map<String, dynamic> json) => ExportPolicy(
    jpegQuality: (json['jpegQuality'] as num?)?.toDouble() ?? 0.92,
    applyRatioCrop: json['applyRatioCrop'] as bool? ?? true,
    applyFrameOnExport: json['applyFrameOnExport'] as bool? ?? true,
    applyWatermarkOnExport: json['applyWatermarkOnExport'] as bool? ?? true,
    preserveMetadata: json['preserveMetadata'] as bool? ?? true,
  );
}

class VideoConfig {
  final bool enabled;
  final List<int> fpsOptions;
  final List<String> resolutionOptions;
  final int defaultFps;
  final String defaultResolution;
  final bool supportsAudio;
  final int videoBitrate;

  const VideoConfig({required this.enabled, required this.fpsOptions, required this.resolutionOptions, required this.defaultFps, required this.defaultResolution, required this.supportsAudio, required this.videoBitrate});

  factory VideoConfig.fromJson(Map<String, dynamic> json) => VideoConfig(
    enabled: json['enabled'] as bool? ?? false,
    fpsOptions: (json['fpsOptions'] as List<dynamic>?)?.map((e) => (e as num).toInt()).toList() ?? [30],
    resolutionOptions: (json['resolutionOptions'] as List<dynamic>?)?.map((e) => e as String).toList() ?? ['HD'],
    defaultFps: (json['defaultFps'] as num?)?.toInt() ?? 30,
    defaultResolution: json['defaultResolution'] as String? ?? 'HD',
    supportsAudio: json['supportsAudio'] as bool? ?? true,
    videoBitrate: (json['videoBitrate'] as num?)?.toInt() ?? 12000000,
  );
}

class CameraAssets {
  final String thumbnail;
  final String icon;

  const CameraAssets({required this.thumbnail, required this.icon});

  factory CameraAssets.fromJson(Map<String, dynamic> json) => CameraAssets(
    thumbnail: json['thumbnail'] as String? ?? '',
    icon: json['icon'] as String? ?? '',
  );
}

class CameraMeta {
  final String version;
  final bool premium;
  final int sortOrder;
  final List<String> tags;

  const CameraMeta({required this.version, required this.premium, required this.sortOrder, required this.tags});

  factory CameraMeta.fromJson(Map<String, dynamic> json) => CameraMeta(
    version: json['version'] as String? ?? '1',
    premium: json['premium'] as bool? ?? false,
    sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
    tags: (json['tags'] as List<dynamic>?)?.map((e) => e as String).toList() ?? [],
  );
}
