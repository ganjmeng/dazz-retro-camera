// camera_definition.dart
// Final CameraDefinition model matching the Final Consolidated Spec.
// All cameras are loaded from JSON assets — no code changes needed to add new cameras.

import 'dart:convert';
import 'package:flutter/services.dart';

dynamic _coerceNumericStrings(dynamic value) {
  if (value is Map) {
    return value.map((key, v) => MapEntry(key, _coerceNumericStrings(v)));
  }
  if (value is List) {
    return value.map(_coerceNumericStrings).toList();
  }
  if (value is String) {
    final s = value.trim();
    if (s.isEmpty) return value;
    final intVal = int.tryParse(s);
    if (intVal != null && RegExp(r'^[-+]?\d+$').hasMatch(s)) return intVal;
    final doubleVal = double.tryParse(s);
    if (doubleVal != null) return doubleVal;
  }
  return value;
}

/// 兼容 bool 和 num 类型的 JSON bool 字段解析器
/// 防止 JSON 中 1.0/0.0 等数值类型导致 Dart `as bool?` 强转失败
bool _parseBoolField(dynamic val) {
  if (val == null) return false;
  if (val is bool) return val;
  if (val is num) return val != 0;
  if (val is String) {
    final s = val.trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'yes' || s == 'on';
  }
  return false;
}

num? _parseNumField(dynamic value) {
  if (value == null) return null;
  if (value is num) return value;
  if (value is String) {
    final s = value.trim().toLowerCase();
    if (s.isEmpty) return null;
    switch (s) {
      case 'none':
      case 'off':
        return 0.0;
      case 'light':
      case 'low':
        return 0.25;
      case 'medium':
      case 'mid':
        return 0.5;
      case 'heavy':
      case 'high':
        return 0.8;
    }
    return num.tryParse(s);
  }
  return null;
}

double _asDouble(dynamic value, {double fallback = 0.0}) =>
    (_parseNumField(value) ?? fallback).toDouble();

int _asInt(dynamic value, {int fallback = 0}) =>
    (_parseNumField(value) ?? fallback).toInt();

// ─────────────────────────────────────────────
// Top-level model
// ──────────────────────────────────────────────

class CameraDefinition {
  final String id;
  final String name;
  final String category;
  final String mode;
  final bool supportsPhoto;
  final bool supportsVideo;
  final bool supportsLivePhoto;
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
    this.supportsLivePhoto = true,
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
      supportsPhoto: _parseBoolField(json['supportsPhoto']) ||
          json['supportsPhoto'] == null,
      supportsVideo: _parseBoolField(json['supportsVideo']),
      supportsLivePhoto: json.containsKey('supportsLivePhoto')
          ? _parseBoolField(json['supportsLivePhoto'])
          : true,
      focalLengthLabel: json['focalLengthLabel'] as String?,
      sensor: SensorConfig.fromJson(Map<String, dynamic>.from(
          _coerceNumericStrings(json['sensor'] as Map) as Map)),
      defaultLook: DefaultLook.fromJson(Map<String, dynamic>.from(
          _coerceNumericStrings(json['defaultLook'] as Map) as Map)),
      modules: CameraModules.fromJson(Map<String, dynamic>.from(
          _coerceNumericStrings(json['modules'] as Map) as Map)),
      defaultSelection: DefaultSelection.fromJson(Map<String, dynamic>.from(
          _coerceNumericStrings(json['defaultSelection'] as Map) as Map)),
      uiCapabilities: UiCapabilities.fromJson(Map<String, dynamic>.from(
          _coerceNumericStrings(json['uiCapabilities'] as Map) as Map)),
      previewCapabilities: PreviewCapabilities.fromJson(
          Map<String, dynamic>.from(
              _coerceNumericStrings(json['previewCapabilities'] as Map)
                  as Map)),
      previewPolicy: PreviewPolicy.fromJson(Map<String, dynamic>.from(
          _coerceNumericStrings(json['previewPolicy'] as Map) as Map)),
      exportPolicy: ExportPolicy.fromJson(Map<String, dynamic>.from(
          _coerceNumericStrings(json['exportPolicy'] as Map) as Map)),
      videoConfig: VideoConfig.fromJson(Map<String, dynamic>.from(
          _coerceNumericStrings(json['videoConfig'] as Map) as Map)),
      assets: CameraAssets.fromJson(
          Map<String, dynamic>.from(json['assets'] as Map)),
      meta: CameraMeta.fromJson(Map<String, dynamic>.from(json['meta'] as Map)),
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
    try {
      return modules.filters.firstWhere((f) => f.id == id);
    } catch (_) {
      return null;
    }
  }

  LensDefinition? lensById(String? id) {
    if (id == null) return null;
    try {
      return modules.lenses.firstWhere((l) => l.id == id);
    } catch (_) {
      return null;
    }
  }

  RatioDefinition? ratioById(String? id) {
    if (id == null) return null;
    try {
      return modules.ratios.firstWhere((r) => r.id == id);
    } catch (_) {
      return null;
    }
  }

  FrameDefinition? frameById(String? id) {
    if (id == null) return null;
    try {
      return modules.frames.firstWhere((f) => f.id == id);
    } catch (_) {
      return null;
    }
  }

  WatermarkPreset? watermarkById(String? id) {
    if (id == null) return null;
    try {
      return modules.watermarks.presets.firstWhere((w) => w.id == id);
    } catch (_) {
      return null;
    }
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

  const SensorConfig(
      {required this.type,
      required this.dynamicRange,
      required this.baseNoise,
      required this.colorDepth});

  factory SensorConfig.fromJson(Map<String, dynamic> json) => SensorConfig(
        type: json['type'] as String,
        dynamicRange: _asInt(json['dynamicRange']),
        baseNoise: _asDouble(json['baseNoise']),
        colorDepth: _asInt(json['colorDepth']),
      );
}

// ─────────────────────────────────────────────
// DefaultLook
// ─────────────────────────────────────────────

class DefaultLook {
  final String? baseLut;
  final String? baseLutDaylight; // 场景 LUT：日光
  final String? baseLutIndoor; // 场景 LUT：室内
  final String? baseLutNight; // 场景 LUT：夜景
  final double lutStrength; // 0.0 ~ 1.0 LUT 混合强度
  final double temperature; // -100 (cool) ~ +100 (warm)
  final double tint; // -100 (green) ~ +100 (magenta)
  final double contrast; // 0.5 ~ 1.8 multiplier
  final double highlights; // -100 ~ +100 (Lightroom-style)
  final double shadows; // -100 ~ +100
  final double whites; // -100 ~ +100
  final double blacks; // -100 ~ +100
  final double clarity; // -100 ~ +100 (midtone micro-contrast)
  final double vibrance; // -100 ~ +100 (smart saturation)
  final double saturation; // 0.0 ~ 2.0 multiplier
  final double vignette; // 0.0 ~ 1.0
  final double distortion;
  final double chromaticAberration;
  final double bloom; // 0.0 ~ 1.0
  final double flare;
  final double grain; // film grain pattern / structure strength
  final double grainAmount; // final film-grain blend weight
  final double dehaze; // 0.0 ~ 10.0 atmospheric dehaze strength
  final double noiseAmount; // final sensor-noise blend weight
  final double colorBiasR; // -1.0 ~ +1.0 red channel bias
  final double colorBiasG; // -1.0 ~ +1.0 green channel bias
  final double colorBiasB; // -1.0 ~ +1.0 blue channel bias
  final double halation; // 0.0 ~ 1.0 highlight halation（胶片高光发光）
  final double grainSize; // 0.5 ~ 3.0 grain particle size（颗粒大小）
  final double grainRoughness; // 0.0 ~ 1.0 grain roughness（颗粒粗糙/不均匀程度）
  final double grainLumaBias; // 0.0 ~ 1.0 grain emphasis from balanced -> shadow biased
  final double grainColorVariation; // 0.0 ~ 0.5 subtle RGB separation for color grain
  final double sharpen; // 0.0 ~ 2.0 unsharp mask strength
  final double sharpness; // 0.0 ~ 2.0 sharpness multiplier（锐度）
  final double bwChannelR; // 0.0 ~ 1.0 B&W channel mixer R
  final double bwChannelG; // 0.0 ~ 1.0 B&W channel mixer G
  final double bwChannelB; // 0.0 ~ 1.0 B&W channel mixer B
  // ── 拍立得即时成像专属参数（Instax / Polaroid 通用——所有拍立得机型均可复用）───────────────
  // 化学显影特性组
  final double highlightRolloff; // 0.0 ~ 1.0 高光柔和滴落（Inst C=0.20，SQC=0.28）
  final double highlightRolloff2; // 0.0 ~ 1.0 二段高光滚落（胶片高光保护）
  final double paperTexture; // 0.0 ~ 1.0 相纸纹理强度（Inst C=0.06，SQC=0.05）
  final double paperUvScale1;
  final double paperUvScale2;
  final double paperWeight1;
  final double paperWeight2;
  final double edgeFalloff; // 0.0 ~ 1.0 边缘曝光衰减（不均匀曝光）
  final double exposureVariation; // 0.0 ~ 1.0 全局曝光不均匀幅度
  final double cornerWarmShift; // 0.0 ~ 1.0 边角偏暖（化学显影边缘特征）
  final double topBottomBias; // -1.0 ~ 1.0 上下方向曝光偏置
  final double leftRightBias; // -1.0 ~ 1.0 左右方向曝光偏置
  final double centerGain; // 0.0 ~ 0.2 中心增亮（内置闪光灯中心亮度，Inst C=0.02，SQC=0.03）
  final double
      developmentSoftness; // 0.0 ~ 0.2 显影柔化（化学扩散软化，Inst C=0.03，SQC=0.04）
  final double
      chemicalIrregularity; // 0.0 ~ 0.1 化学不规则感（胶片面积越小越低，Inst C=0.015，SQC=0.02）
  final double irregUvScale;
  final double irregFreq1;
  final double irregFreq2;
  final double irregWeight1;
  final double irregWeight2;
  // 肤色保护组（拍立得以人像为主，防止肤色过橙/过红）
  final bool skinHueProtect; // 肤色色相保护开关（Inst C=true，SQC=true）
  final double skinSatProtect; // 0.0 ~ 1.0 肤色饱和度保护（Inst C=0.92，SQC=0.95）
  final double skinLumaSoften; // 0.0 ~ 0.2 肤色亮度柔化（Inst C=0.05，SQC=0.04）
  final double skinRedLimit; // 0.9 ~ 1.2 肤色红限（Inst C=1.02，SQC=1.03）
  // ── Fade / Split Toning / Light Leak（新增）───────────────────────────────────────
  final double fadeAmount; // 0.0 ~ 0.3 褒色强度（提升黑场）
  final double shadowTintR; // -0.2 ~ 0.2 阴影色调 R
  final double shadowTintG; // -0.2 ~ 0.2 阴影色调 G
  final double shadowTintB; // -0.2 ~ 0.2 阴影色调 B
  final double highlightTintR; // -0.2 ~ 0.2 高光色调 R
  final double highlightTintG; // -0.2 ~ 0.2 高光色调 G
  final double highlightTintB; // -0.2 ~ 0.2 高光色调 B
  final double splitToneBalance; // 0.0 ~ 1.0 分离色调平衡（默认 0.5）
  final double lightLeakAmount; // 0.0 ~ 1.0 漏光强度
  final double dustAmount; // 0.0 ~ 1.0 灰尘/白点贴图强度
  final double scratchAmount; // 0.0 ~ 1.0 划痕/纤维贴图强度
  final double luminanceNoise; // 0.0 ~ 0.5 亮度噪声
  final double chromaNoise; // 0.0 ~ 0.5 色度噪声
  final double toneCurveStrength; // 0.0 ~ 1.0 Tone Curve 强度
  final double highlightWarmAmount; // 0.0 ~ 1.0 highlight warmth push
  final List<List<double>> toneCurvePoints; // optional custom tone-curve points
  // ── Filmic Tone Mapping（JSON 驱动）────────────────────────────────────────────
  final double toneMapToe; // 0.0 ~ 1.0 阴影卷曲强度（toe）
  final double toneMapShoulder; // 0.0 ~ 1.0 高光肩部压缩强度（shoulder）
  final double toneMapStrength; // 0.0 ~ 1.0 filmic 映射混合强度
  final double midGrayDensity; // -1.0 ~ 1.0 中灰密度（18% 灰锚点附近）
  final double highlightRolloffPivot; // 0.5 ~ 0.95 高光 rolloff 起始阈值
  final double highlightRolloffSoftKnee; // 0.0 ~ 1.0 高光 rolloff 软膝强度
  // 风格响应权重：让共享渲染算子重新回到 JSON 配置驱动。
  final double bloomResponse; // 0.0 ~ 1.0
  final double halationResponse; // 0.0 ~ 1.0
  final double fadeResponse; // 0.0 ~ 1.0
  final double highlightRolloffResponse; // 0.0 ~ 1.0
  final double sceneShadowResponse; // 0.0 ~ 1.0
  final double sceneHighlightResponse; // 0.0 ~ 1.0
  final double sceneWhitesResponse; // 0.0 ~ 1.0
  final double toneCurveResponse; // 0.0 ~ 1.0

  const DefaultLook({
    this.baseLut,
    this.baseLutDaylight,
    this.baseLutIndoor,
    this.baseLutNight,
    this.lutStrength = 1.0,
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
    this.grainAmount = 0,
    this.dehaze = 0,
    this.noiseAmount = 0, // FIX: 数字噪点强度
    this.colorBiasR = 0,
    this.colorBiasG = 0,
    this.colorBiasB = 0,
    this.halation = 0,
    this.grainSize = 1.0,
    this.grainRoughness = 0.5,
    this.grainLumaBias = 0.65,
    this.grainColorVariation = 0.08,
    this.sharpen = 0.0,
    this.sharpness = 1.0,
    this.bwChannelR = 0.0,
    this.bwChannelG = 0.0,
    this.bwChannelB = 0.0,
    // 拍立得即时成像专属字段（默认为 0，不影响其他相机）
    this.highlightRolloff = 0,
    this.highlightRolloff2 = 0,
    this.paperTexture = 0,
    this.paperUvScale1 = 8.0,
    this.paperUvScale2 = 32.0,
    this.paperWeight1 = 0.7,
    this.paperWeight2 = 0.3,
    this.edgeFalloff = 0,
    this.exposureVariation = 0,
    this.cornerWarmShift = 0,
    this.topBottomBias = 0,
    this.leftRightBias = 0,
    this.centerGain = 0,
    this.developmentSoftness = 0,
    this.chemicalIrregularity = 0,
    this.irregUvScale = 2.5,
    this.irregFreq1 = 1.0,
    this.irregFreq2 = 1.7,
    this.irregWeight1 = 0.6,
    this.irregWeight2 = 0.4,
    this.skinHueProtect = false,
    this.skinSatProtect = 1.0,
    this.skinLumaSoften = 0,
    this.skinRedLimit = 1.0,
    // Fade / Split Toning / Light Leak
    this.fadeAmount = 0,
    this.shadowTintR = 0,
    this.shadowTintG = 0,
    this.shadowTintB = 0,
    this.highlightTintR = 0,
    this.highlightTintG = 0,
    this.highlightTintB = 0,
    this.splitToneBalance = 0.5,
    this.lightLeakAmount = 0,
    this.dustAmount = 0,
    this.scratchAmount = 0,
    this.luminanceNoise = 0,
    this.chromaNoise = 0,
    this.toneCurveStrength = 0,
    this.highlightWarmAmount = 0,
    this.toneCurvePoints = const [],
    this.toneMapToe = 0.0,
    this.toneMapShoulder = 0.0,
    this.toneMapStrength = 0.0,
    this.midGrayDensity = 0.0,
    this.highlightRolloffPivot = 0.76,
    this.highlightRolloffSoftKnee = 0.35,
    this.bloomResponse = 1.0,
    this.halationResponse = 1.0,
    this.fadeResponse = 1.0,
    this.highlightRolloffResponse = 1.0,
    this.sceneShadowResponse = 1.0,
    this.sceneHighlightResponse = 1.0,
    this.sceneWhitesResponse = 1.0,
    this.toneCurveResponse = 1.0,
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
        halation: 0,
        sharpen: 0,
        grainSize: 1.0,
        grainLumaBias: 0.65,
        sharpness: 1.0,
      );

  factory DefaultLook.fromJson(Map<String, dynamic> json) => DefaultLook(
        baseLut: json['baseLut'] as String?,
        baseLutDaylight: json['baseLutDaylight'] as String?,
        baseLutIndoor: json['baseLutIndoor'] as String?,
        baseLutNight: json['baseLutNight'] as String?,
        lutStrength: _asDouble(json['lutStrength'], fallback: 1.0),
        temperature: _asDouble(json['temperature']),
        tint: _asDouble(json['tint']),
        contrast: _asDouble(json['contrast'], fallback: 1.0),
        highlights: _asDouble(json['highlights']),
        shadows: _asDouble(json['shadows']),
        whites: _asDouble(json['whites']),
        blacks: _asDouble(json['blacks']),
        clarity: _asDouble(json['clarity']),
        vibrance: _asDouble(json['vibrance']),
        saturation: _asDouble(json['saturation'], fallback: 1.0),
        vignette: _asDouble(json['vignette']),
        distortion: _asDouble(json['distortion']),
        chromaticAberration: _asDouble(json['chromaticAberration']),
        bloom: _asDouble(json['bloom']),
        flare: _asDouble(json['flare']),
        grain: _asDouble(json['grain']),
        grainAmount: _asDouble(json['grainAmount']),
        dehaze: _asDouble(json['dehaze']),
        noiseAmount: _asDouble(json['noiseAmount']),
        colorBiasR: _asDouble(json['colorBiasR']),
        colorBiasG: _asDouble(json['colorBiasG']),
        colorBiasB: _asDouble(json['colorBiasB']),
        halation: _asDouble(json['halation']),
        grainSize: _asDouble(json['grainSize'], fallback: 1.0),
        grainRoughness: _asDouble(json['grainRoughness'], fallback: 0.5),
        grainLumaBias: _asDouble(json['grainLumaBias'], fallback: 0.65),
        grainColorVariation:
            _asDouble(json['grainColorVariation'], fallback: 0.08),
        sharpen: _asDouble(json['sharpen']),
        sharpness: _asDouble(json['sharpness'], fallback: 1.0),
        bwChannelR: _asDouble(json['bwChannelR']),
        bwChannelG: _asDouble(json['bwChannelG']),
        bwChannelB: _asDouble(json['bwChannelB']),
        // 拍立得即时成像专属字段
        highlightRolloff: _asDouble(json['highlightRolloff']),
        highlightRolloff2: _asDouble(json['highlightRolloff2']),
        paperTexture: _asDouble(json["paperTexture"]),
        paperUvScale1: _asDouble(json["paperUvScale1"], fallback: 8.0),
        paperUvScale2: _asDouble(json["paperUvScale2"], fallback: 32.0),
        paperWeight1: _asDouble(json["paperWeight1"], fallback: 0.7),
        paperWeight2: _asDouble(json["paperWeight2"], fallback: 0.3),
        edgeFalloff: _asDouble(json['edgeFalloff']),
        exposureVariation: _asDouble(json['exposureVariation']),
        cornerWarmShift: _asDouble(json['cornerWarmShift']),
        topBottomBias: _asDouble(json['topBottomBias']),
        leftRightBias: _asDouble(json['leftRightBias']),
        centerGain: _asDouble(json['centerGain']),
        developmentSoftness: _asDouble(json['developmentSoftness']),
        chemicalIrregularity: _asDouble(json["chemicalIrregularity"]),
        irregUvScale: _asDouble(json["irregUvScale"], fallback: 2.5),
        irregFreq1: _asDouble(json["irregFreq1"], fallback: 1.0),
        irregFreq2: _asDouble(json["irregFreq2"], fallback: 1.7),
        irregWeight1: _asDouble(json["irregWeight1"], fallback: 0.6),
        irregWeight2: _asDouble(json["irregWeight2"], fallback: 0.4),
        skinHueProtect: _parseBoolField(json['skinHueProtect']),
        skinSatProtect: _asDouble(json['skinSatProtect'], fallback: 1.0),
        skinLumaSoften: _asDouble(json['skinLumaSoften']),
        skinRedLimit: _asDouble(json['skinRedLimit'], fallback: 1.0),
        // Fade / Split Toning / Light Leak
        fadeAmount: _asDouble(json['fadeAmount']),
        shadowTintR: _asDouble(json['shadowTintR']),
        shadowTintG: _asDouble(json['shadowTintG']),
        shadowTintB: _asDouble(json['shadowTintB']),
        highlightTintR: _asDouble(json['highlightTintR']),
        highlightTintG: _asDouble(json['highlightTintG']),
        highlightTintB: _asDouble(json['highlightTintB']),
        splitToneBalance: _asDouble(json['splitToneBalance'], fallback: 0.5),
        lightLeakAmount: _asDouble(json['lightLeakAmount']),
        dustAmount: _asDouble(json['dustAmount']),
        scratchAmount: _asDouble(json['scratchAmount']),
        luminanceNoise: _asDouble(json['luminanceNoise']),
        chromaNoise: _asDouble(json['chromaNoise']),
        toneCurveStrength: _asDouble(json['toneCurveStrength']),
        highlightWarmAmount: _asDouble(json['highlightWarmAmount']),
        toneCurvePoints: ((json['toneCurvePoints'] as List?) ?? const [])
            .whereType<List>()
            .map((point) => point.map((v) => _asDouble(v)).toList())
            .where((point) => point.length >= 2)
            .map((point) => [point[0], point[1]])
            .toList(),
        toneMapToe: _asDouble(json['toneMapToe']),
        toneMapShoulder: _asDouble(json['toneMapShoulder']),
        toneMapStrength: _asDouble(json['toneMapStrength']),
        midGrayDensity: _asDouble(json['midGrayDensity']),
        highlightRolloffPivot:
            _asDouble(json['highlightRolloffPivot'], fallback: 0.76),
        highlightRolloffSoftKnee:
            _asDouble(json['highlightRolloffSoftKnee'], fallback: 0.35),
        bloomResponse: _asDouble(json['bloomResponse'], fallback: 1.0),
        halationResponse: _asDouble(json['halationResponse'], fallback: 1.0),
        fadeResponse: _asDouble(json['fadeResponse'], fallback: 1.0),
        highlightRolloffResponse:
            _asDouble(json['highlightRolloffResponse'], fallback: 1.0),
        sceneShadowResponse:
            _asDouble(json['sceneShadowResponse'], fallback: 1.0),
        sceneHighlightResponse:
            _asDouble(json['sceneHighlightResponse'], fallback: 1.0),
        sceneWhitesResponse:
            _asDouble(json['sceneWhitesResponse'], fallback: 1.0),
        toneCurveResponse: _asDouble(json['toneCurveResponse'], fallback: 1.0),
      );

  Map<String, dynamic> toJson() => {
        if (baseLut != null) 'baseLut': baseLut,
        if (baseLutDaylight != null) 'baseLutDaylight': baseLutDaylight,
        if (baseLutIndoor != null) 'baseLutIndoor': baseLutIndoor,
        if (baseLutNight != null) 'baseLutNight': baseLutNight,
        if (baseLut != null || lutStrength != 1.0) 'lutStrength': lutStrength,
        'temperature': temperature,
        'tint': tint,
        'contrast': contrast,
        'highlights': highlights,
        'shadows': shadows,
        'whites': whites,
        'blacks': blacks,
        'clarity': clarity,
        'vibrance': vibrance,
        'saturation': saturation,
        'vignette': vignette,
        'distortion': distortion,
        'chromaticAberration': chromaticAberration,
        'bloom': bloom,
        'flare': flare,
        'grain': grain,
        if (grainAmount != 0) 'grainAmount': grainAmount,
        'dehaze': dehaze,
        'noiseAmount': noiseAmount, // FIX: 数字噪点强度
        'colorBiasR': colorBiasR,
        'colorBiasG': colorBiasG,
        'colorBiasB': colorBiasB,
        'halation': halation,
        'grainSize': grainSize,
        'grainRoughness': grainRoughness,
        if (grainLumaBias != 0.65) 'grainLumaBias': grainLumaBias,
        if (grainColorVariation != 0.08)
          'grainColorVariation': grainColorVariation,
        'sharpen': sharpen,
        'sharpness': sharpness,
        if (bwChannelR != 0) 'bwChannelR': bwChannelR,
        if (bwChannelG != 0) 'bwChannelG': bwChannelG,
        if (bwChannelB != 0) 'bwChannelB': bwChannelB,
        // 拍立得即时成像专属字段（默认为 0 时不影响其他相机）
        if (highlightRolloff != 0) 'highlightRolloff': highlightRolloff,
        if (highlightRolloff2 != 0) 'highlightRolloff2': highlightRolloff2,
        if (paperTexture != 0) 'paperTexture': paperTexture,
        if (edgeFalloff != 0) 'edgeFalloff': edgeFalloff,
        if (exposureVariation != 0) 'exposureVariation': exposureVariation,
        if (cornerWarmShift != 0) 'cornerWarmShift': cornerWarmShift,
        if (topBottomBias != 0) 'topBottomBias': topBottomBias,
        if (leftRightBias != 0) 'leftRightBias': leftRightBias,
        if (centerGain != 0) 'centerGain': centerGain,
        if (developmentSoftness != 0)
          'developmentSoftness': developmentSoftness,
        if (chemicalIrregularity != 0)
          'chemicalIrregularity': chemicalIrregularity,
        if (skinHueProtect) 'skinHueProtect': skinHueProtect,
        if (skinSatProtect != 1.0) 'skinSatProtect': skinSatProtect,
        if (skinLumaSoften != 0) 'skinLumaSoften': skinLumaSoften,
        if (skinRedLimit != 1.0) 'skinRedLimit': skinRedLimit,
        // Fade / Split Toning / Light Leak
        if (fadeAmount != 0) 'fadeAmount': fadeAmount,
        if (shadowTintR != 0) 'shadowTintR': shadowTintR,
        if (shadowTintG != 0) 'shadowTintG': shadowTintG,
        if (shadowTintB != 0) 'shadowTintB': shadowTintB,
        if (highlightTintR != 0) 'highlightTintR': highlightTintR,
        if (highlightTintG != 0) 'highlightTintG': highlightTintG,
        if (highlightTintB != 0) 'highlightTintB': highlightTintB,
        if (splitToneBalance != 0.5) 'splitToneBalance': splitToneBalance,
        if (lightLeakAmount != 0) 'lightLeakAmount': lightLeakAmount,
        if (dustAmount != 0) 'dustAmount': dustAmount,
        if (scratchAmount != 0) 'scratchAmount': scratchAmount,
        if (luminanceNoise != 0) 'luminanceNoise': luminanceNoise,
        if (chromaNoise != 0) 'chromaNoise': chromaNoise,
        if (toneCurveStrength != 0) 'toneCurveStrength': toneCurveStrength,
        if (highlightWarmAmount != 0)
          'highlightWarmAmount': highlightWarmAmount,
        if (toneCurvePoints.isNotEmpty) 'toneCurvePoints': toneCurvePoints,
        if (toneMapToe != 0) 'toneMapToe': toneMapToe,
        if (toneMapShoulder != 0) 'toneMapShoulder': toneMapShoulder,
        if (toneMapStrength != 0) 'toneMapStrength': toneMapStrength,
        if (midGrayDensity != 0) 'midGrayDensity': midGrayDensity,
        if (highlightRolloffPivot != 0.76)
          'highlightRolloffPivot': highlightRolloffPivot,
        if (highlightRolloffSoftKnee != 0.35)
          'highlightRolloffSoftKnee': highlightRolloffSoftKnee,
        if (bloomResponse != 1.0) 'bloomResponse': bloomResponse,
        if (halationResponse != 1.0) 'halationResponse': halationResponse,
        if (fadeResponse != 1.0) 'fadeResponse': fadeResponse,
        if (highlightRolloffResponse != 1.0)
          'highlightRolloffResponse': highlightRolloffResponse,
        if (sceneShadowResponse != 1.0)
          'sceneShadowResponse': sceneShadowResponse,
        if (sceneHighlightResponse != 1.0)
          'sceneHighlightResponse': sceneHighlightResponse,
        if (sceneWhitesResponse != 1.0)
          'sceneWhitesResponse': sceneWhitesResponse,
        if (toneCurveResponse != 1.0) 'toneCurveResponse': toneCurveResponse,
      };
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

  const CameraModules(
      {required this.filters,
      required this.lenses,
      required this.ratios,
      required this.frames,
      required this.watermarks,
      required this.extras});

  factory CameraModules.fromJson(Map<String, dynamic> json) => CameraModules(
        filters: (json['filters'] as List<dynamic>)
            .map((e) =>
                FilterDefinition.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        lenses: (json['lenses'] as List<dynamic>)
            .map((e) =>
                LensDefinition.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        ratios: (json['ratios'] as List<dynamic>)
            .map((e) =>
                RatioDefinition.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        frames: (json['frames'] as List<dynamic>)
            .map((e) =>
                FrameDefinition.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        watermarks: WatermarkModule.fromJson(
            Map<String, dynamic>.from(json['watermarks'] as Map)),
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
  final String grain; // 'none' | 'light' | 'medium' | 'heavy'
  final double grainSize; // 0.5 ~ 3.0 颗粒大小
  final double vignette; // 0.0 ~ 1.0 暗角强度
  final double sharpness; // 0.0 ~ 2.0 锐度
  final double halation; // 0.0 ~ 1.0 高光发光（FQS 专用）
  final String? thumbnail;

  const FilterDefinition({
    required this.id,
    required this.name,
    required this.nameEn,
    this.lut,
    required this.contrast,
    required this.saturation,
    required this.grain,
    this.grainSize = 1.0,
    this.vignette = 0.0,
    this.sharpness = 1.0,
    this.halation = 0.0,
    this.thumbnail,
  });

  factory FilterDefinition.fromJson(Map<String, dynamic> json) =>
      FilterDefinition(
        id: json['id'] as String,
        name: json['name'] as String,
        nameEn: json['nameEn'] as String? ?? json['name'] as String,
        lut: json['lut'] as String?,
        contrast: (json['contrast'] as num?)?.toDouble() ?? 1.0,
        saturation: (json['saturation'] as num?)?.toDouble() ?? 1.0,
        grain: json['grain'] as String? ?? 'none',
        grainSize: (json['grainSize'] as num?)?.toDouble() ?? 1.0,
        vignette: (json['vignette'] as num?)?.toDouble() ?? 0.0,
        sharpness: (json['sharpness'] as num?)?.toDouble() ?? 1.0,
        halation: (json['halation'] as num?)?.toDouble() ?? 0.0,
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
  final double vignette; // 暗角强度 0.0~1.0
  final double distortion; // 畸变：正=桶形，负=枕形
  final double chromaticAberration; // 色差强度 0.0~1.0
  final double edgeBlur; // 边缘模糊 0.0~1.0
  final double exposure; // 曝光补偿 EV（-2.0~+2.0）
  final double contrast; // 对比度调整 -1.0~+1.0
  final double saturation; // 饱和度调整 -1.0~+1.0
  final double highlightCompression; // 高光压缩（ND专用）0.0~1.0
  // 保留旧字段（向后兼容）
  final double bloom;
  final double flare;
  final double softFocus;
  final double refraction;
  final String? thumbnail;

  /// 镜头图标资源路径（assets/lenses/lens_xxx.png）
  final String? iconPath;

  /// 圆形鱼眼模式：画面映射为圆形+四周黑色（等距投影）
  final bool fisheyeMode;
  final bool circularFisheyeCrop;

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
    this.iconPath,
    this.fisheyeMode = false,
    this.circularFisheyeCrop = false,
  });

  factory LensDefinition.fromJson(Map<String, dynamic> json) => LensDefinition(
        id: json['id'] as String,
        name: json['name'] as String,
        nameEn: json['nameEn'] as String? ?? json['name'] as String,
        zoomFactor: (json['zoomFactor'] as num?)?.toDouble() ?? 1.0,
        vignette: (json['vignette'] as num?)?.toDouble() ?? 0.0,
        distortion: (json['distortion'] as num?)?.toDouble() ?? 0.0,
        chromaticAberration:
            (json['chromaticAberration'] as num?)?.toDouble() ?? 0.0,
        edgeBlur: (json['edgeBlur'] as num?)?.toDouble() ?? 0.0,
        exposure: (json['exposure'] as num?)?.toDouble() ?? 0.0,
        contrast: (json['contrast'] as num?)?.toDouble() ?? 0.0,
        saturation: (json['saturation'] as num?)?.toDouble() ?? 0.0,
        highlightCompression:
            (json['highlightCompression'] as num?)?.toDouble() ?? 0.0,
        bloom: (json['bloom'] as num?)?.toDouble() ?? 0.0,
        flare: (json['flare'] as num?)?.toDouble() ?? 0.0,
        softFocus: (json['softFocus'] as num?)?.toDouble() ?? 0.0,
        refraction: (json['refraction'] as num?)?.toDouble() ?? 0.0,
        thumbnail: json['thumbnail'] as String?,
        iconPath: json['iconPath'] as String?,
        fisheyeMode: json['fisheyeMode'] as bool? ?? false,
        circularFisheyeCrop: json['circularFisheyeCrop'] as bool? ??
            (json['fisheyeMode'] as bool? ?? false),
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

  const RatioDefinition(
      {required this.id,
      required this.label,
      required this.width,
      required this.height,
      required this.supportsFrame});

  double get aspectRatio => width / height;

  factory RatioDefinition.fromJson(Map<String, dynamic> json) =>
      RatioDefinition(
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

  /// 是否为空相框（id == 'none'）
  bool get isNone => id == 'none';

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

  factory FrameDefinition.fromJson(Map<String, dynamic> json) =>
      FrameDefinition(
        id: json['id'] as String,
        name: json['name'] as String,
        nameEn: json['nameEn'] as String? ?? json['name'] as String,
        asset: json['asset'] as String?,
        ratioAssets:
            ((json['ratioAssets'] as Map?)?.cast<String, dynamic>())?.map(
                  (k, v) => MapEntry(k, v as String),
                ) ??
                const {},
        backgroundColor: json['backgroundColor'] as String? ?? '#FFFFFF',
        inset: FrameInset.fromJson(
            (json['inset'] as Map?)?.cast<String, dynamic>() ??
                const <String, dynamic>{}),
        ratioInsets: ((json['ratioInsets'] as Map?)?.cast<String, dynamic>())
                ?.map(
              (k, v) => MapEntry(
                  k, FrameInset.fromJson(Map<String, dynamic>.from(v as Map))),
            ) ??
            const {},
        supportedRatios: (json['supportedRatios'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            [],
        thumbnail: json['thumbnail'] as String?,
        lightLeak: (json['lightLeak'] as num?)?.toDouble() ?? 0.0,
        shake: (json['shake'] as num?)?.toDouble() ?? 0.0,
        outerPadding: (json['outerPadding'] as num?)?.toDouble() ?? 0.0,
        outerBackgroundColor:
            json['outerBackgroundColor'] as String? ?? '#FFFFFF',
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

  const FrameInset(
      {required this.top,
      required this.right,
      required this.bottom,
      required this.left});

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

  factory WatermarkModule.fromJson(Map<String, dynamic> json) =>
      WatermarkModule(
        presets: (json['presets'] as List<dynamic>)
            .map((e) =>
                WatermarkPreset.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        editor: WatermarkEditor.fromJson(
            (json['editor'] as Map?)?.cast<String, dynamic>() ??
                const <String, dynamic>{}),
      );
}

class WatermarkPreset {
  final String id;
  final String name;
  final String? color;
  final String? position;
  final double? fontSize;
  final String? fontFamily;

  const WatermarkPreset(
      {required this.id,
      required this.name,
      this.color,
      this.position,
      this.fontSize,
      this.fontFamily});

  bool get isNone => id == 'none';

  factory WatermarkPreset.fromJson(Map<String, dynamic> json) =>
      WatermarkPreset(
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

  const WatermarkEditor(
      {required this.allowColorChange,
      required this.allowPositionChange,
      required this.allowSizeChange,
      required this.allowOrientationChange});

  factory WatermarkEditor.fromJson(Map<String, dynamic> json) =>
      WatermarkEditor(
        allowColorChange: json['allowColorChange'] as bool? ?? false,
        allowPositionChange: json['allowPositionChange'] as bool? ?? false,
        allowSizeChange: json['allowSizeChange'] as bool? ?? false,
        allowOrientationChange:
            json['allowOrientationChange'] as bool? ?? false,
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

  const DefaultSelection(
      {this.filterId,
      this.lensId,
      this.ratioId,
      this.frameId,
      this.watermarkPresetId,
      this.extraId});

  factory DefaultSelection.fromJson(Map<String, dynamic> json) =>
      DefaultSelection(
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

  const UiCapabilities(
      {required this.enableFilter,
      required this.enableLens,
      required this.enableRatio,
      required this.enableFrame,
      required this.enableWatermark,
      required this.enableExtra});

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

  const PreviewCapabilities(
      {required this.allowSmallViewport,
      required this.allowGridOverlay,
      required this.allowZoom,
      required this.allowImportImage,
      required this.allowTimer,
      required this.allowFlash});

  factory PreviewCapabilities.fromJson(Map<String, dynamic> json) =>
      PreviewCapabilities(
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
  final bool enableHalation;
  final bool enablePaperTexture;
  final bool enableChromaticAberration;
  final bool enableFrameComposite;
  final bool enableWatermarkComposite;

  const PreviewPolicy(
      {required this.enableLut,
      required this.enableTemperature,
      required this.enableContrast,
      required this.enableSaturation,
      required this.enableVignette,
      required this.enableLightLensEffect,
      required this.enableGrain,
      required this.enableBloom,
      required this.enableHalation,
      required this.enablePaperTexture,
      required this.enableChromaticAberration,
      required this.enableFrameComposite,
      required this.enableWatermarkComposite});

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
        enableHalation: false,
        enablePaperTexture: false,
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
        enableHalation: json['enableHalation'] as bool? ?? false,
        enablePaperTexture: json['enablePaperTexture'] as bool? ?? false,
        enableChromaticAberration:
            json['enableChromaticAberration'] as bool? ?? false,
        enableFrameComposite: json['enableFrameComposite'] as bool? ?? false,
        enableWatermarkComposite:
            json['enableWatermarkComposite'] as bool? ?? true,
      );
}

class ExportPolicy {
  final double jpegQuality;
  final bool applyRatioCrop;
  final bool applyFrameOnExport;
  final bool applyWatermarkOnExport;
  final bool preserveMetadata;

  const ExportPolicy(
      {required this.jpegQuality,
      required this.applyRatioCrop,
      required this.applyFrameOnExport,
      required this.applyWatermarkOnExport,
      required this.preserveMetadata});

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

  const VideoConfig(
      {required this.enabled,
      required this.fpsOptions,
      required this.resolutionOptions,
      required this.defaultFps,
      required this.defaultResolution,
      required this.supportsAudio,
      required this.videoBitrate});

  factory VideoConfig.fromJson(Map<String, dynamic> json) => VideoConfig(
        enabled: json['enabled'] as bool? ?? false,
        fpsOptions: (json['fpsOptions'] as List<dynamic>?)
                ?.map((e) => (e as num).toInt())
                .toList() ??
            [30],
        resolutionOptions: (json['resolutionOptions'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            ['HD'],
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

  const CameraMeta(
      {required this.version,
      required this.premium,
      required this.sortOrder,
      required this.tags});

  factory CameraMeta.fromJson(Map<String, dynamic> json) => CameraMeta(
        version: json['version'] as String? ?? '1',
        premium: json['premium'] as bool? ?? false,
        sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
        tags: (json['tags'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            [],
      );
}
