/// Preset 核心数据模型
/// 代表一台"虚拟相机"，包含其视觉效果的完整配置。

class DateStampConfig {
  final bool enabled;
  final String format;
  final String color;
  final String position;

  const DateStampConfig({
    required this.enabled,
    this.format = 'yyyy MM dd',
    this.color = '#FFFFA500',
    this.position = 'bottomRight',
  });

  factory DateStampConfig.fromJson(Map<String, dynamic> json) => DateStampConfig(
        enabled: json['enabled'] as bool? ?? false,
        format: json['format'] as String? ?? 'yyyy MM dd',
        color: json['color'] as String? ?? '#FFFFA500',
        position: json['position'] as String? ?? 'bottomRight',
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'format': format,
        'color': color,
        'position': position,
      };
}

class PresetParams {
  final double exposureBias;
  final double contrast;
  final double saturation;
  final double temperatureShift;
  final double tintShift;
  final double sharpen;
  final double blurRadius;
  final double grainAmount;
  final double noiseAmount;
  final double vignetteAmount;
  final double chromaticAberration;
  final double bloomAmount;
  final double halationAmount;
  final double jpegArtifacts;
  final double scanlineAmount;
  final DateStampConfig dateStamp;

  const PresetParams({
    this.exposureBias = 0.0,
    this.contrast = 1.0,
    this.saturation = 1.0,
    this.temperatureShift = 0.0,
    this.tintShift = 0.0,
    this.sharpen = 0.0,
    this.blurRadius = 0.0,
    this.grainAmount = 0.0,
    this.noiseAmount = 0.0,
    this.vignetteAmount = 0.0,
    this.chromaticAberration = 0.0,
    this.bloomAmount = 0.0,
    this.halationAmount = 0.0,
    this.jpegArtifacts = 0.0,
    this.scanlineAmount = 0.0,
    required this.dateStamp,
  });

  factory PresetParams.fromJson(Map<String, dynamic> json) => PresetParams(
        exposureBias: (json['exposureBias'] as num?)?.toDouble() ?? 0.0,
        contrast: (json['contrast'] as num?)?.toDouble() ?? 1.0,
        saturation: (json['saturation'] as num?)?.toDouble() ?? 1.0,
        temperatureShift: (json['temperatureShift'] as num?)?.toDouble() ?? 0.0,
        tintShift: (json['tintShift'] as num?)?.toDouble() ?? 0.0,
        sharpen: (json['sharpen'] as num?)?.toDouble() ?? 0.0,
        blurRadius: (json['blurRadius'] as num?)?.toDouble() ?? 0.0,
        grainAmount: (json['grainAmount'] as num?)?.toDouble() ?? 0.0,
        noiseAmount: (json['noiseAmount'] as num?)?.toDouble() ?? 0.0,
        vignetteAmount: (json['vignetteAmount'] as num?)?.toDouble() ?? 0.0,
        chromaticAberration: (json['chromaticAberration'] as num?)?.toDouble() ?? 0.0,
        bloomAmount: (json['bloomAmount'] as num?)?.toDouble() ?? 0.0,
        halationAmount: (json['halationAmount'] as num?)?.toDouble() ?? 0.0,
        jpegArtifacts: (json['jpegArtifacts'] as num?)?.toDouble() ?? 0.0,
        scanlineAmount: (json['scanlineAmount'] as num?)?.toDouble() ?? 0.0,
        dateStamp: DateStampConfig.fromJson(
            json['dateStamp'] as Map<String, dynamic>? ?? {}),
      );

  Map<String, dynamic> toJson() => {
        'exposureBias': exposureBias,
        'contrast': contrast,
        'saturation': saturation,
        'temperatureShift': temperatureShift,
        'tintShift': tintShift,
        'sharpen': sharpen,
        'blurRadius': blurRadius,
        'grainAmount': grainAmount,
        'noiseAmount': noiseAmount,
        'vignetteAmount': vignetteAmount,
        'chromaticAberration': chromaticAberration,
        'bloomAmount': bloomAmount,
        'halationAmount': halationAmount,
        'jpegArtifacts': jpegArtifacts,
        'scanlineAmount': scanlineAmount,
        'dateStamp': dateStamp.toJson(),
      };
}

class PresetResources {
  final String lutName;
  final String grainTextureName;
  final List<String> leakTextureNames;
  final String? frameOverlayName;

  const PresetResources({
    required this.lutName,
    required this.grainTextureName,
    this.leakTextureNames = const [],
    this.frameOverlayName,
  });

  factory PresetResources.fromJson(Map<String, dynamic> json) => PresetResources(
        lutName: json['lutName'] as String,
        grainTextureName: json['grainTextureName'] as String,
        leakTextureNames: (json['leakTextureNames'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            [],
        frameOverlayName: json['frameOverlayName'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'lutName': lutName,
        'grainTextureName': grainTextureName,
        'leakTextureNames': leakTextureNames,
        'frameOverlayName': frameOverlayName,
      };
}

class Preset {
  final String id;
  final String name;
  final String category;
  final bool supportsPhoto;
  final bool supportsVideo;
  final bool isPremium;
  final PresetResources resources;
  final PresetParams params;

  const Preset({
    required this.id,
    required this.name,
    required this.category,
    required this.supportsPhoto,
    required this.supportsVideo,
    required this.isPremium,
    required this.resources,
    required this.params,
  });

  factory Preset.fromJson(Map<String, dynamic> json) => Preset(
        id: json['id'] as String,
        name: json['name'] as String,
        category: json['category'] as String,
        supportsPhoto: json['supportsPhoto'] as bool? ?? true,
        supportsVideo: json['supportsVideo'] as bool? ?? false,
        isPremium: json['isPremium'] as bool? ?? false,
        resources: PresetResources.fromJson(
            json['resources'] as Map<String, dynamic>),
        params: PresetParams.fromJson(json['params'] as Map<String, dynamic>),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'category': category,
        'supportsPhoto': supportsPhoto,
        'supportsVideo': supportsVideo,
        'isPremium': isPremium,
        'resources': resources.toJson(),
        'params': params.toJson(),
      };
}
