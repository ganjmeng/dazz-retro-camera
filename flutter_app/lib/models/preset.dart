/// 代表一台"虚拟相机"，包含其视觉效果的完整配置。

// ─── DateStamp 配置 ───────────────────────────────────────────────────────────

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

// ─── PresetParams（渲染参数） ─────────────────────────────────────────────────

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

// ─── PresetResources（资源引用） ──────────────────────────────────────────────

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
        lutName: json['lutName'] as String? ?? '',
        grainTextureName: json['grainTextureName'] as String? ?? '',
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

// ─── V3: OptionItem（选项条目） ───────────────────────────────────────────────

class OptionItem {
  final String id;
  final String name;
  final bool isDefault;
  // Legacy fields
  final String? lutName;
  final String? grainTextureName;
  final String? frameOverlayName;
  final String? watermarkName;
  // V3 rendering map (raw)
  final Map<String, dynamic>? rendering;
  // For ratio items
  final String? value;
  // For watermark items
  final String? type;

  const OptionItem({
    required this.id,
    required this.name,
    this.isDefault = false,
    this.lutName,
    this.grainTextureName,
    this.frameOverlayName,
    this.watermarkName,
    this.rendering,
    this.value,
    this.type,
  });

  factory OptionItem.fromJson(Map<String, dynamic> json) => OptionItem(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        isDefault: json['isDefault'] as bool? ?? false,
        lutName: json['lutName'] as String?,
        grainTextureName: json['grainTextureName'] as String?,
        frameOverlayName: json['frameOverlayName'] as String?,
        watermarkName: json['watermarkName'] as String?,
        rendering: json['rendering'] as Map<String, dynamic>?,
        value: json['value'] as String?,
        type: json['type'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'isDefault': isDefault,
        if (lutName != null) 'lutName': lutName,
        if (grainTextureName != null) 'grainTextureName': grainTextureName,
        if (frameOverlayName != null) 'frameOverlayName': frameOverlayName,
        if (watermarkName != null) 'watermarkName': watermarkName,
        if (rendering != null) 'rendering': rendering,
        if (value != null) 'value': value,
        if (type != null) 'type': type,
      };
}

// ─── V3: OptionGroup（选项组） ────────────────────────────────────────────────

class OptionGroup {
  final String type; // 'films' | 'lenses' | 'papers' | 'ratios' | 'watermarks'
  final String label;
  final String defaultId;
  final List<OptionItem> items;

  const OptionGroup({
    required this.type,
    required this.label,
    required this.defaultId,
    required this.items,
  });

  factory OptionGroup.fromJson(Map<String, dynamic> json) => OptionGroup(
        type: json['type'] as String? ?? '',
        label: json['label'] as String? ?? '',
        defaultId: json['defaultId'] as String? ?? '',
        items: (json['items'] as List<dynamic>?)
                ?.map((e) => OptionItem.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );

  Map<String, dynamic> toJson() => {
        'type': type,
        'label': label,
        'defaultId': defaultId,
        'items': items.map((e) => e.toJson()).toList(),
      };
}

// ─── V3: UiCapabilities（UI 能力声明） ────────────────────────────────────────

class UiCapabilities {
  final bool showFilmSelector;
  final bool showLensSelector;
  final bool showPaperSelector;
  final bool showRatioSelector;
  final bool showWatermarkSelector;
  final bool showFlashButton;
  final bool showTimerButton;
  final bool showGridButton;

  const UiCapabilities({
    this.showFilmSelector = false,
    this.showLensSelector = false,
    this.showPaperSelector = false,
    this.showRatioSelector = false,
    this.showWatermarkSelector = false,
    this.showFlashButton = true,
    this.showTimerButton = true,
    this.showGridButton = true,
  });

  factory UiCapabilities.fromJson(Map<String, dynamic> json) => UiCapabilities(
        showFilmSelector: json['showFilmSelector'] as bool? ?? false,
        showLensSelector: json['showLensSelector'] as bool? ?? false,
        showPaperSelector: json['showPaperSelector'] as bool? ?? false,
        showRatioSelector: json['showRatioSelector'] as bool? ?? false,
        showWatermarkSelector: json['showWatermarkSelector'] as bool? ?? false,
        showFlashButton: json['showFlashButton'] as bool? ?? true,
        showTimerButton: json['showTimerButton'] as bool? ?? true,
        showGridButton: json['showGridButton'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'showFilmSelector': showFilmSelector,
        'showLensSelector': showLensSelector,
        'showPaperSelector': showPaperSelector,
        'showRatioSelector': showRatioSelector,
        'showWatermarkSelector': showWatermarkSelector,
        'showFlashButton': showFlashButton,
        'showTimerButton': showTimerButton,
        'showGridButton': showGridButton,
      };
}

// ─── Preset（主模型） ─────────────────────────────────────────────────────────

class Preset {
  final String id;
  final String name;
  final String category;
  /// V3: 输出类型，'photo' | 'video' | 'both'
  final String outputType;
  /// V3: 基础机型名称（用于 UI 展示）
  final String baseModel;
  final bool isPremium;
  /// V3: 动态选项组（胶卷/镜头/相纸/比例/水印）
  final List<OptionGroup> optionGroups;
  /// V3: UI 能力声明（控制哪些选项按钮可见）
  final UiCapabilities uiCapabilities;
  /// 渲染资源（兼容旧版 JSON）
  final PresetResources? resources;
  /// 渲染参数（兼容旧版 JSON）
  final PresetParams? params;

  // 兼容旧字段
  bool get supportsPhoto => outputType == 'photo' || outputType == 'both';
  bool get supportsVideo => outputType == 'video' || outputType == 'both';

  const Preset({
    required this.id,
    required this.name,
    required this.category,
    this.outputType = 'photo',
    this.baseModel = '',
    this.isPremium = false,
    this.optionGroups = const [],
    this.uiCapabilities = const UiCapabilities(),
    this.resources,
    this.params,
  });

  factory Preset.fromJson(Map<String, dynamic> json) {
    // 解析 outputType：兼容旧版 supportsVideo 字段
    String outputType = json['outputType'] as String? ?? '';
    if (outputType.isEmpty) {
      final supportsVideo = json['supportsVideo'] as bool? ?? false;
      final supportsPhoto = json['supportsPhoto'] as bool? ?? true;
      if (supportsVideo && supportsPhoto) {
        outputType = 'both';
      } else if (supportsVideo) {
        outputType = 'video';
      } else {
        outputType = 'photo';
      }
    }

    // 解析 optionGroups
    // V3 格式: Map<String, List> {"films": [...], "ratios": [...]}
    // Legacy 格式: List<Map> [{type: "films", items: [...]}]
    List<OptionGroup> optionGroupsList = [];
    final rawOptionGroups = json['optionGroups'];
    if (rawOptionGroups is Map) {
      // V3 Map 格式
      final labelMap = {
        'films': '胶卷',
        'lenses': '镜头',
        'papers': '相纸',
        'ratios': '比例',
        'watermarks': '水印',
      };
      rawOptionGroups.forEach((key, value) {
        if (value is List) {
          final items = value
              .map((e) => OptionItem.fromJson(e as Map<String, dynamic>))
              .toList();
          final defaultItem = items.firstWhere(
            (i) => i.isDefault,
            orElse: () => items.isNotEmpty ? items.first : const OptionItem(id: '', name: ''),
          );
          optionGroupsList.add(OptionGroup(
            type: key as String,
            label: labelMap[key] ?? key as String,
            defaultId: defaultItem.id,
            items: items,
          ));
        }
      });
    } else if (rawOptionGroups is List) {
      // Legacy List 格式
      optionGroupsList = rawOptionGroups
          .map((e) => OptionGroup.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    // 解析 uiCapabilities
    final uiCap = json['uiCapabilities'] != null
        ? UiCapabilities.fromJson(json['uiCapabilities'] as Map<String, dynamic>)
        : UiCapabilities(
            showFilmSelector: optionGroupsList.any((g) => g.type == 'films'),
            showLensSelector: optionGroupsList.any((g) => g.type == 'lenses'),
            showPaperSelector: optionGroupsList.any((g) => g.type == 'papers'),
            showRatioSelector: optionGroupsList.any((g) => g.type == 'ratios'),
            showWatermarkSelector: optionGroupsList.any((g) => g.type == 'watermarks'),
          );

    // 解析 resources（可选）
    final resourcesJson = json['resources'] as Map<String, dynamic>?;
    final resources = resourcesJson != null ? PresetResources.fromJson(resourcesJson) : null;

    // 解析 params（可选）
    final paramsJson = json['params'] as Map<String, dynamic>?;
    final params = paramsJson != null ? PresetParams.fromJson(paramsJson) : null;

    // 解析 baseModel：V3 可能是 Map，兼容 String
    final rawBaseModel = json['baseModel'];
    final baseModel = rawBaseModel is String
        ? rawBaseModel
        : (json['name'] as String? ?? '');

    return Preset(
      id: json['id'] as String,
      name: json['name'] as String,
      category: json['category'] as String? ?? '',
      outputType: outputType,
      baseModel: baseModel,
      isPremium: json['isPremium'] as bool? ?? false,
      optionGroups: optionGroupsList,
      uiCapabilities: uiCap,
      resources: resources,
      params: params,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'category': category,
        'outputType': outputType,
        'baseModel': baseModel,
        'isPremium': isPremium,
        'optionGroups': optionGroups.map((e) => e.toJson()).toList(),
        'uiCapabilities': uiCapabilities.toJson(),
        if (resources != null) 'resources': resources!.toJson(),
        if (params != null) 'params': params!.toJson(),
      };
}
