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
  final double temperature;   // -100 (cool) ~ +100 (warm)
  final double tint;          // -100 (green) ~ +100 (magenta)
  final double contrast;      // 0.5 ~ 1.8 multiplier
  final double highlights;    // -100 ~ +100 (Lightroom-style)
  final double shadows;       // -100 ~ +100
  final double whites;        // -100 ~ +100
  final double blacks;        // -100 ~ +100
  final double clarity;       // -100 ~ +100 (midtone micro-contrast)
  final double vibrance;      // -100 ~ +100 (smart saturation)
  final double saturation;    // 0.0 ~ 2.0 multiplier
  final double vignette;      // 0.0 ~ 1.0
  final double distortion;
  final double chromaticAberration;
  final double bloom;         // 0.0 ~ 1.0
  final double flare;
  final double grain;         // 0.0 ~ 1.0 grain strength
  final double colorBiasR;    // -1.0 ~ +1.0 red channel bias
  final double colorBiasG;    // -1.0 ~ +1.0 green channel bias
  final double colorBiasB;    // -1.0 ~ +1.0 blue channel bias

  const DefaultLook({
    this.baseLut,
    required this.temperature,
    this.tint = 0,
    required this.contrast,
    this.highlights = 0,
    this.shadows = 0,
    this.whites = 0,
    this.blacks = 0,
    this.clarity = 0,
    this.vibrance = 0,
    required this.saturation,
    required this.vignette,
    required this.distortion,
    required this.chromaticAberration,
    required this.bloom,
    required this.flare,
    this.grain = 0,
    this.colorBiasR = 0,
    this.colorBiasG = 0,
    this.colorBiasB = 0,
  });

  /// 占位默认値（相机 JSON 未加载时使用）
  factory DefaultLook.empty() => const DefaultLook(
    temperature: 0,
    contrast: 1.0,
    saturation: 1.0,
    vignette: 0,
    distortion: 0,
    chromaticAberration: 0,
    bloom: 0,
    flare: 0,
  );

  factory DefaultLook.fromJson(Map<String, dynamic> json) => DefaultLook(
    baseLut: json['baseLut'] as String?,
    temperature: (json['temperature'] as num? ?? 0).toDouble(),
    tint: (json['tint'] as num? ?? 0).toDouble(),
    contrast: (json['contrast'] as num? ?? 1.0).toDouble(),
    highlights: (json['highlights'] as num? ?? 0).toDouble(),
    shadows: (json['shadows'] as num? ?? 0).toDouble(),
    whites: (json['whites'] as num? ?? 0).toDouble(),
    blacks: (json['blacks'] as num? ?? 0).toDouble(),
    clarity: (json['clarity'] as num? ?? 0).toDouble(),
    vibrance: (json['vibrance'] as num? ?? 0).toDouble(),
    saturation: (json['saturation'] as num? ?? 1.0).toDouble(),
    vignette: (json['vignette'] as num? ?? 0).toDouble(),
    distortion: (json['distortion'] as num? ?? 0).toDouble(),
    chromaticAberration: (json['chromaticAberration'] as num? ?? 0).toDouble(),
    bloom: (json['bloom'] as num? ?? 0).toDouble(),
    flare: (json['flare'] as num? ?? 0).toDouble(),
    grain: (json['grain'] as num? ?? 0).toDouble(),
    colorBiasR: (json['colorBiasR'] as num? ?? 0).toDouble(),
    colorBiasG: (json['colorBiasG'] as num? ?? 0).toDouble(),
    colorBiasB: (json['colorBiasB'] as num? ?? 0).toDouble(),
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
  final double zoomFactor;           // 光学倍率，例如 1.0=x1, 2.0=x2
  final double vignette;             // 暗角强度 0.0~1.0
  final double distortion;           // 畸变：正=桶形，负=枕形
  final double chromaticAberration;  // 色差强度 0.0~1.0
  final double edgeBlur;             // 边缘模糊 0.0~1.0
  final double exposure;             // 曝光补偿 EV（-2.0~+2.0）
  final double contrast;             // 对比度调整 -1.0~+1.0
  final double saturation;           // 饱和度调整 -1.0~+1.0
  final double highlightCompression; // 高光压缩（ND专用）0.0~1.0
  // 保留旧字段（向后兼容）
  final double bloom;
  final double flare;
  final double softFocus;
  final double refraction;
  final String? thumbnail;

  const LensDefinition({
    required this.id,
    required this.name,
    required this.nameEn,
    this.zoomFactor = 1.0,
    required this.vignette,
    required this.distortion,
    required this.chromaticAberration,
    this.edgeBlur = 0.0,
    this.exposure = 0.0,
    this.contrast = 0.0,
    this.saturation = 0.0,
    this.highlightCompression = 0.0,
    this.bloom = 0.0,
    this.flare = 0.0,
    this.softFocus = 0.0,
    this.refraction = 0.0,
    this.thumbnail,
  });

  factory LensDefinition.fromJson(Map<String, dynamic> json) => LensDefinition(
    id: json['id'] as String,
    name: json['name'] as String,
    nameEn: json['nameEn'] as String? ?? json['name'] as String,
    zoomFactor: (json['zoomFactor'] as num?)?.toDouble() ?? 1.0,
    vignette: (json['vignette'] as num?)?.toDouble() ?? 0.0,
    distortion: (json['distortion'] as num?)?.toDouble() ?? 0.0,
    chromaticAberration: (json['chromaticAberration'] as num?)?.toDouble() ?? 0.0,
    edgeBlur: (json['edgeBlur'] as num?)?.toDouble() ?? 0.0,
    exposure: (json['exposure'] as num?)?.toDouble() ?? 0.0,
    contrast: (json['contrast'] as num?)?.toDouble() ?? 0.0,
    saturation: (json['saturation'] as num?)?.toDouble() ?? 0.0,
    highlightCompression: (json['highlightCompression'] as num?)?.toDouble() ?? 0.0,
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
  /// 按比例选择不同 PNG 资源：{ "ratio_1_1": "assets/frames/xxx_1x1.png", "ratio_3_4": "assets/frames/xxx_3x4.png" }
  /// 优先级高于 asset 字段；若对应比例不存在则回退到 asset
  final Map<String, String> ratioAssets;
  final String backgroundColor;
  final FrameInset inset;
  /// 按比例选择不同 inset：{ "ratio_1_1": FrameInset(...), "ratio_3_4": FrameInset(...) }
  /// 优先级高于 inset 字段；若对应比例不存在则回退到 inset
  final Map<String, FrameInset> ratioInsets;
  final List<String> supportedRatios;
  final String? thumbnail;
  /// 漏光强度 0.0~1.0（0=无，1=最强）
  final double lightLeak;
  /// 抖动模糊强度 0.0~1.0（0=无，1=最强）
  final double shake;
  /// 外层背景间距（相框外周的白边），相对于 1080px 参考宽度
  final double outerPadding;
  /// 外层背景色（相框外面的背景，默认白色）
  final String outerBackgroundColor;
  /// 相框圆角半径（相对于 1080px 参考宽度，0=无圆角）
  final double cornerRadius;
   /// 是否在图片区域边缘绘制内嵌阴影（增加拟物厚度感）
  final bool innerShadow;
  /// 是否支持用户选择背景色（拍立得相框支持，CCD铺满型相框不支持）
  final bool supportsBackground;
  const FrameDefinition({
    required this.id,
    required this.name,
    required this.nameEn,
    this.asset,
    this.ratioAssets = const {},
    required this.backgroundColor,
    required this.inset,
    this.ratioInsets = const {},
    required this.supportedRatios,
    this.thumbnail,
    this.lightLeak = 0.0,
    this.shake = 0.0,
    this.outerPadding = 0.0,
    this.outerBackgroundColor = '#FFFFFF',
    this.cornerRadius = 0.0,
    this.innerShadow = false,
    this.supportsBackground = false,
  });

  /// 根据 ratioId 获取实际使用的 asset 路径（优先 ratioAssets，回退 asset）
  String? assetForRatio(String? ratioId) {
    if (ratioId != null && ratioAssets.containsKey(ratioId)) {
      return ratioAssets[ratioId];
    }
    return asset;
  }

  /// 根据 ratioId 获取实际使用的 inset（优先 ratioInsets，回退 inset）
  FrameInset insetForRatio(String? ratioId) {
    if (ratioId != null && ratioInsets.containsKey(ratioId)) {
      return ratioInsets[ratioId]!;
    }
    return inset;
  }

  factory FrameDefinition.fromJson(Map<String, dynamic> json) => FrameDefinition(
    id: json['id'] as String,
    name: json['name'] as String,
    nameEn: json['nameEn'] as String? ?? json['name'] as String,
    asset: json['asset'] as String?,
    ratioAssets: (json['ratioAssets'] as Map<String, dynamic>?)?.map(
      (k, v) => MapEntry(k, v as String),
    ) ?? const {},
    backgroundColor: json['backgroundColor'] as String? ?? '#FFFFFF',
    inset: FrameInset.fromJson(json['inset'] as Map<String, dynamic>? ?? {}),
    ratioInsets: (json['ratioInsets'] as Map<String, dynamic>?)?.map(
      (k, v) => MapEntry(k, FrameInset.fromJson(v as Map<String, dynamic>)),
    ) ?? const {},
    supportedRatios: (json['supportedRatios'] as List<dynamic>?)?.map((e) => e as String).toList() ?? [],
    thumbnail: json['thumbnail'] as String?,
    lightLeak: (json['lightLeak'] as num?)?.toDouble() ?? 0.0,
    shake: (json['shake'] as num?)?.toDouble() ?? 0.0,
    outerPadding: (json['outerPadding'] as num?)?.toDouble() ?? 0.0,
    outerBackgroundColor: json['outerBackgroundColor'] as String? ?? '#FFFFFF',
    cornerRadius: (json['cornerRadius'] as num?)?.toDouble() ?? 0.0,
    innerShadow: json['innerShadow'] as bool? ?? false,
    supportsBackground: json['supportsBackground'] as bool? ?? false,
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
