// ─── CameraDefinition 数据模型 ─────────────────────────────────────────────
// 完整实现 CameraDefinition 架构，相机是顶层产品对象，
// 所有选项（胶卷/镜头/相纸/比例/水印）归属于相机本身。

// ─── 传感器模型 ───────────────────────────────────────────────────────────────
class SensorModel {
  final String type; // 'ccd' | 'film' | 'instant' | 'vhs' | 'disposable'
  final double dynamicRange;
  final double baseNoise;
  final double colorDepth;

  const SensorModel({
    required this.type,
    this.dynamicRange = 8.0,
    this.baseNoise = 0.0,
    this.colorDepth = 8.0,
  });

  factory SensorModel.fromJson(Map<String, dynamic> json) => SensorModel(
        type: json['type'] as String? ?? 'ccd',
        dynamicRange: (json['dynamic_range'] as num?)?.toDouble() ??
            (json['dynamicRange'] as num?)?.toDouble() ?? 8.0,
        baseNoise: (json['noise'] as num?)?.toDouble() ??
            (json['baseNoise'] as num?)?.toDouble() ?? 0.0,
        colorDepth: (json['colorDepth'] as num?)?.toDouble() ?? 8.0,
      );

  Map<String, dynamic> toJson() => {
        'type': type,
        'dynamicRange': dynamicRange,
        'baseNoise': baseNoise,
        'colorDepth': colorDepth,
      };
}

// ─── 基础色彩模型 ─────────────────────────────────────────────────────────────
class ColorModel {
  final String? baseLut; // 基础 LUT 路径
  final double temperature; // 色温偏移 (-1000 ~ +1000)
  final double contrast; // 对比度 (0.5 ~ 2.0)
  final double saturation; // 饱和度 (0.0 ~ 2.0)
  final double brightness; // 亮度 (-1.0 ~ 1.0)

  const ColorModel({
    this.baseLut,
    this.temperature = 0.0,
    this.contrast = 1.0,
    this.saturation = 1.0,
    this.brightness = 0.0,
  });

  factory ColorModel.fromJson(Map<String, dynamic> json) => ColorModel(
        baseLut: json['baseLut'] as String?,
        temperature: (json['temperature'] as num?)?.toDouble() ?? 0.0,
        contrast: (json['contrast'] as num?)?.toDouble() ?? 1.0,
        saturation: (json['saturation'] as num?)?.toDouble() ?? 1.0,
        brightness: (json['brightness'] as num?)?.toDouble() ?? 0.0,
      );

  Map<String, dynamic> toJson() => {
        if (baseLut != null) 'baseLut': baseLut,
        'temperature': temperature,
        'contrast': contrast,
        'saturation': saturation,
        'brightness': brightness,
      };
}

// ─── 高光模型 ─────────────────────────────────────────────────────────────────
class HighlightModel {
  final double halation; // 光晕强度 (0.0 ~ 1.0)
  final double rolloff; // 高光过渡 (0.0 ~ 1.0)

  const HighlightModel({this.halation = 0.0, this.rolloff = 0.0});

  factory HighlightModel.fromJson(Map<String, dynamic> json) => HighlightModel(
        halation: (json['halation'] as num?)?.toDouble() ?? 0.0,
        rolloff: (json['rolloff'] as num?)?.toDouble() ?? 0.0,
      );

  Map<String, dynamic> toJson() => {
        'halation': halation,
        'rolloff': rolloff,
      };
}

// ─── BaseModel ────────────────────────────────────────────────────────────────
class BaseModel {
  final SensorModel sensor;
  final ColorModel color;
  final HighlightModel highlight;

  const BaseModel({
    required this.sensor,
    required this.color,
    this.highlight = const HighlightModel(),
  });

  factory BaseModel.fromJson(Map<String, dynamic> json) => BaseModel(
        sensor: SensorModel.fromJson(
            json['sensor'] as Map<String, dynamic>? ?? {}),
        color: ColorModel.fromJson(
            json['color'] as Map<String, dynamic>? ?? {}),
        highlight: json['highlight'] != null
            ? HighlightModel.fromJson(json['highlight'] as Map<String, dynamic>)
            : const HighlightModel(),
      );

  Map<String, dynamic> toJson() => {
        'sensor': sensor.toJson(),
        'color': color.toJson(),
        'highlight': highlight.toJson(),
      };
}

// ─── Film 渲染参数 ────────────────────────────────────────────────────────────
class FilmRendering {
  final String? lut; // LUT 文件路径 (assets/lut/xxx.cube)
  final String? grainTexture; // 颗粒纹理路径
  final double grainIntensity; // 颗粒强度 (0.0 ~ 1.0)
  final double temperatureShift; // 色温偏移
  final double chromaticAberration; // 色差强度 (0.0 ~ 0.1)
  final double vignetteAmount; // 暗角强度 (0.0 ~ 1.0)
  final double jpegArtifacts; // JPEG 压缩伪影 (0.0 ~ 1.0)
  final double fadeAmount; // 褪色量 (0.0 ~ 1.0)

  const FilmRendering({
    this.lut,
    this.grainTexture,
    this.grainIntensity = 0.0,
    this.temperatureShift = 0.0,
    this.chromaticAberration = 0.0,
    this.vignetteAmount = 0.0,
    this.jpegArtifacts = 0.0,
    this.fadeAmount = 0.0,
  });

  factory FilmRendering.fromJson(Map<String, dynamic> json) => FilmRendering(
        lut: json['lut'] as String?,
        grainTexture: (json['grain'] ?? json['grainTexture']) as String?,
        grainIntensity: (json['grainIntensity'] as num?)?.toDouble() ?? 0.0,
        temperatureShift: (json['temperatureShift'] as num?)?.toDouble() ?? 0.0,
        chromaticAberration:
            (json['chromaticAberration'] as num?)?.toDouble() ?? 0.0,
        vignetteAmount:
            (json['vignetteAmount'] ?? json['vignette'] as num?)?.toDouble() ??
                0.0,
        jpegArtifacts: (json['jpegArtifacts'] as num?)?.toDouble() ?? 0.0,
        fadeAmount: (json['fadeAmount'] as num?)?.toDouble() ?? 0.0,
      );

  Map<String, dynamic> toJson() => {
        if (lut != null) 'lut': lut,
        if (grainTexture != null) 'grainTexture': grainTexture,
        'grainIntensity': grainIntensity,
        'temperatureShift': temperatureShift,
        'chromaticAberration': chromaticAberration,
        'vignetteAmount': vignetteAmount,
        'jpegArtifacts': jpegArtifacts,
        'fadeAmount': fadeAmount,
      };
}

// ─── Film 选项 ────────────────────────────────────────────────────────────────
class FilmOption {
  final String id;
  final String name;
  final bool isDefault;
  final bool isPremium;
  final FilmRendering rendering;

  const FilmOption({
    required this.id,
    required this.name,
    this.isDefault = false,
    this.isPremium = false,
    required this.rendering,
  });

  factory FilmOption.fromJson(Map<String, dynamic> json) => FilmOption(
        id: json['id'] as String,
        name: json['name'] as String,
        isDefault: json['isDefault'] as bool? ?? false,
        isPremium: json['isPremium'] as bool? ?? false,
        rendering: FilmRendering.fromJson(
            json['rendering'] as Map<String, dynamic>? ?? {}),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'isDefault': isDefault,
        'isPremium': isPremium,
        'rendering': rendering.toJson(),
      };
}

// ─── Lens 渲染参数 ────────────────────────────────────────────────────────────
class LensRendering {
  final double vignette; // 暗角 (0.0 ~ 1.0)
  final double distortion; // 畸变 (-0.5 ~ 0.5)
  final double chromaticAberration; // 色差 (0.0 ~ 0.1)
  final double bloom; // 光晕 (0.0 ~ 1.0)
  final double flare; // 眩光 (0.0 ~ 1.0)
  final double blurRadius; // 软焦模糊 (0.0 ~ 5.0)

  const LensRendering({
    this.vignette = 0.0,
    this.distortion = 0.0,
    this.chromaticAberration = 0.0,
    this.bloom = 0.0,
    this.flare = 0.0,
    this.blurRadius = 0.0,
  });

  factory LensRendering.fromJson(Map<String, dynamic> json) => LensRendering(
        vignette: (json['vignette'] as num?)?.toDouble() ?? 0.0,
        distortion: (json['distortion'] as num?)?.toDouble() ?? 0.0,
        chromaticAberration:
            (json['chromaticAberration'] as num?)?.toDouble() ?? 0.0,
        bloom: (json['bloom'] as num?)?.toDouble() ?? 0.0,
        flare: (json['flare'] as num?)?.toDouble() ?? 0.0,
        blurRadius: (json['blurRadius'] as num?)?.toDouble() ?? 0.0,
      );

  Map<String, dynamic> toJson() => {
        'vignette': vignette,
        'distortion': distortion,
        'chromaticAberration': chromaticAberration,
        'bloom': bloom,
        'flare': flare,
        'blurRadius': blurRadius,
      };
}

// ─── Lens 选项 ────────────────────────────────────────────────────────────────
class LensOption {
  final String id;
  final String name;
  final bool isDefault;
  final LensRendering rendering;

  const LensOption({
    required this.id,
    required this.name,
    this.isDefault = false,
    required this.rendering,
  });

  factory LensOption.fromJson(Map<String, dynamic> json) => LensOption(
        id: json['id'] as String,
        name: json['name'] as String,
        isDefault: json['isDefault'] as bool? ?? false,
        rendering: LensRendering.fromJson(
            json['rendering'] as Map<String, dynamic>? ?? {}),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'isDefault': isDefault,
        'rendering': rendering.toJson(),
      };
}

// ─── Paper 渲染参数 ───────────────────────────────────────────────────────────
class PaperRendering {
  final String? frameAsset; // 边框图片资源路径
  final String? paperTexture; // 相纸纹理路径
  final double frameScale; // 边框缩放比例
  final String backgroundColor; // 背景颜色 (hex)
  final double marginTop; // 上边距比例 (0.0 ~ 0.5)
  final double marginBottom; // 下边距比例 (0.0 ~ 0.5)
  final double marginLeft; // 左边距比例 (0.0 ~ 0.5)
  final double marginRight; // 右边距比例 (0.0 ~ 0.5)

  const PaperRendering({
    this.frameAsset,
    this.paperTexture,
    this.frameScale = 1.0,
    this.backgroundColor = '#FFFFFF',
    this.marginTop = 0.05,
    this.marginBottom = 0.2,
    this.marginLeft = 0.05,
    this.marginRight = 0.05,
  });

  factory PaperRendering.fromJson(Map<String, dynamic> json) => PaperRendering(
        frameAsset: (json['frameAsset'] ?? json['frame']) as String?,
        paperTexture: json['paperTexture'] as String?,
        frameScale: (json['frameScale'] as num?)?.toDouble() ?? 1.0,
        backgroundColor: json['backgroundColor'] as String? ?? '#FFFFFF',
        marginTop: (json['marginTop'] as num?)?.toDouble() ?? 0.05,
        marginBottom: (json['marginBottom'] as num?)?.toDouble() ?? 0.2,
        marginLeft: (json['marginLeft'] as num?)?.toDouble() ?? 0.05,
        marginRight: (json['marginRight'] as num?)?.toDouble() ?? 0.05,
      );

  Map<String, dynamic> toJson() => {
        if (frameAsset != null) 'frameAsset': frameAsset,
        if (paperTexture != null) 'paperTexture': paperTexture,
        'frameScale': frameScale,
        'backgroundColor': backgroundColor,
        'marginTop': marginTop,
        'marginBottom': marginBottom,
        'marginLeft': marginLeft,
        'marginRight': marginRight,
      };
}

// ─── Paper 选项 ───────────────────────────────────────────────────────────────
class PaperOption {
  final String id;
  final String name;
  final bool isDefault;
  final PaperRendering rendering;

  const PaperOption({
    required this.id,
    required this.name,
    this.isDefault = false,
    required this.rendering,
  });

  factory PaperOption.fromJson(Map<String, dynamic> json) => PaperOption(
        id: json['id'] as String,
        name: json['name'] as String,
        isDefault: json['isDefault'] as bool? ?? false,
        rendering: PaperRendering.fromJson(
            json['rendering'] as Map<String, dynamic>? ?? {}),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'isDefault': isDefault,
        'rendering': rendering.toJson(),
      };
}

// ─── Ratio 选项 ───────────────────────────────────────────────────────────────
class RatioOption {
  final String id;
  final String name;
  final String value; // '4:3' | '1:1' | '16:9' | '3:2'
  final bool isDefault;

  const RatioOption({
    required this.id,
    required this.name,
    required this.value,
    this.isDefault = false,
  });

  /// 返回宽高比数值
  double get aspectRatio {
    final parts = value.split(':');
    if (parts.length != 2) return 4 / 3;
    final w = double.tryParse(parts[0]) ?? 4;
    final h = double.tryParse(parts[1]) ?? 3;
    return w / h;
  }

  factory RatioOption.fromJson(Map<String, dynamic> json) => RatioOption(
        id: json['id'] as String,
        name: json['name'] as String? ?? json['value'] as String? ?? '4:3',
        value: json['value'] as String? ?? '4:3',
        isDefault: json['isDefault'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'value': value,
        'isDefault': isDefault,
      };
}

// ─── Watermark 渲染参数 ───────────────────────────────────────────────────────
class WatermarkRendering {
  final String position; // 'bottom_right' | 'bottom_left' | 'top_left' | 'frame_bottom'
  final String color; // hex color
  final double opacity; // 0.0 ~ 1.0
  final String? font; // 字体名称
  final double fontSize; // 字体大小
  final String? textFormat; // 文本格式（用于 frame_text 类型）
  final String? asset; // 图片水印资源路径
  final String renderLayer; // 'image' | 'frame'

  const WatermarkRendering({
    this.position = 'bottom_right',
    this.color = '#FF8A3D',
    this.opacity = 0.9,
    this.font,
    this.fontSize = 14.0,
    this.textFormat,
    this.asset,
    this.renderLayer = 'image',
  });

  factory WatermarkRendering.fromJson(Map<String, dynamic> json) =>
      WatermarkRendering(
        position: json['position'] as String? ?? 'bottom_right',
        color: json['color'] as String? ?? '#FF8A3D',
        opacity: (json['opacity'] as num?)?.toDouble() ?? 0.9,
        font: json['font'] as String?,
        fontSize: (json['fontSize'] as num?)?.toDouble() ?? 14.0,
        textFormat: json['textFormat'] as String? ?? json['text'] as String?,
        asset: json['asset'] as String?,
        renderLayer: json['renderLayer'] as String? ?? 'image',
      );

  Map<String, dynamic> toJson() => {
        'position': position,
        'color': color,
        'opacity': opacity,
        if (font != null) 'font': font,
        'fontSize': fontSize,
        if (textFormat != null) 'textFormat': textFormat,
        if (asset != null) 'asset': asset,
        'renderLayer': renderLayer,
      };
}

// ─── Watermark 选项 ───────────────────────────────────────────────────────────
class WatermarkOption {
  final String id;
  final String name;
  final String type; // 'digital_date' | 'camera_name' | 'frame_text' | 'video_rec' | 'none'
  final bool isDefault;
  final WatermarkRendering rendering;

  const WatermarkOption({
    required this.id,
    required this.name,
    required this.type,
    this.isDefault = false,
    required this.rendering,
  });

  bool get isNone => type == 'none';

  factory WatermarkOption.fromJson(Map<String, dynamic> json) => WatermarkOption(
        id: json['id'] as String,
        name: json['name'] as String,
        type: json['type'] as String? ?? 'none',
        isDefault: json['isDefault'] as bool? ?? false,
        rendering: json['rendering'] != null
            ? WatermarkRendering.fromJson(
                json['rendering'] as Map<String, dynamic>)
            : const WatermarkRendering(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'isDefault': isDefault,
        'rendering': rendering.toJson(),
      };
}

// ─── OptionGroups ─────────────────────────────────────────────────────────────
class OptionGroups {
  final List<FilmOption> films;
  final List<LensOption> lenses;
  final List<PaperOption> papers;
  final List<RatioOption> ratios;
  final List<WatermarkOption> watermarks;

  const OptionGroups({
    this.films = const [],
    this.lenses = const [],
    this.papers = const [],
    this.ratios = const [],
    this.watermarks = const [],
  });

  factory OptionGroups.fromJson(Map<String, dynamic> json) => OptionGroups(
        films: (json['films'] as List<dynamic>? ?? [])
            .map((e) => FilmOption.fromJson(e as Map<String, dynamic>))
            .toList(),
        lenses: (json['lenses'] as List<dynamic>? ?? [])
            .map((e) => LensOption.fromJson(e as Map<String, dynamic>))
            .toList(),
        papers: (json['papers'] as List<dynamic>? ?? [])
            .map((e) => PaperOption.fromJson(e as Map<String, dynamic>))
            .toList(),
        ratios: (json['ratios'] as List<dynamic>? ?? [])
            .map((e) => RatioOption.fromJson(e as Map<String, dynamic>))
            .toList(),
        watermarks: (json['watermarks'] as List<dynamic>? ?? [])
            .map((e) => WatermarkOption.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'films': films.map((e) => e.toJson()).toList(),
        'lenses': lenses.map((e) => e.toJson()).toList(),
        'papers': papers.map((e) => e.toJson()).toList(),
        'ratios': ratios.map((e) => e.toJson()).toList(),
        'watermarks': watermarks.map((e) => e.toJson()).toList(),
      };
}

// ─── DefaultSelection ─────────────────────────────────────────────────────────
class DefaultSelection {
  final String? filmId;
  final String? lensId;
  final String? paperId;
  final String? ratioId;
  final String? watermarkId;

  const DefaultSelection({
    this.filmId,
    this.lensId,
    this.paperId,
    this.ratioId,
    this.watermarkId,
  });

  factory DefaultSelection.fromJson(Map<String, dynamic> json) =>
      DefaultSelection(
        filmId: json['filmId'] as String?,
        lensId: json['lensId'] as String?,
        paperId: json['paperId'] as String?,
        ratioId: json['ratioId'] as String?,
        watermarkId: json['watermarkId'] as String?,
      );

  Map<String, dynamic> toJson() => {
        if (filmId != null) 'filmId': filmId,
        if (lensId != null) 'lensId': lensId,
        if (paperId != null) 'paperId': paperId,
        if (ratioId != null) 'ratioId': ratioId,
        if (watermarkId != null) 'watermarkId': watermarkId,
      };
}

// ─── UiCapabilities ───────────────────────────────────────────────────────────
class UiCapabilities {
  final bool showFilmSelector;
  final bool showLensSelector;
  final bool showPaperSelector;
  final bool showRatioSelector;
  final bool showWatermarkSelector;
  final bool showEffectSelector;
  final bool showFlashButton;
  final bool showTimerButton;
  final bool showGridButton;

  const UiCapabilities({
    this.showFilmSelector = false,
    this.showLensSelector = false,
    this.showPaperSelector = false,
    this.showRatioSelector = true,
    this.showWatermarkSelector = true,
    this.showEffectSelector = false,
    this.showFlashButton = true,
    this.showTimerButton = true,
    this.showGridButton = true,
  });

  factory UiCapabilities.fromJson(Map<String, dynamic> json) => UiCapabilities(
        showFilmSelector: json['showFilmSelector'] as bool? ?? false,
        showLensSelector: json['showLensSelector'] as bool? ?? false,
        showPaperSelector: json['showPaperSelector'] as bool? ?? false,
        showRatioSelector: json['showRatioSelector'] as bool? ?? true,
        showWatermarkSelector: json['showWatermarkSelector'] as bool? ?? true,
        showEffectSelector: json['showEffectSelector'] as bool? ?? false,
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
        'showEffectSelector': showEffectSelector,
        'showFlashButton': showFlashButton,
        'showTimerButton': showTimerButton,
        'showGridButton': showGridButton,
      };
}

// ─── PreviewPolicy ────────────────────────────────────────────────────────────
class PreviewPolicy {
  final bool enableLut;
  final bool enableTemperature;
  final bool enableContrast;
  final bool enableSaturation;
  final bool enableVignette;
  // 以下在预览中禁用以保证帧率
  final bool enableGrain; // 始终 false
  final bool enableBloom; // 始终 false
  final bool enableChromaticAberration; // 始终 false
  final bool enablePaperComposite; // 始终 false
  final bool enableWatermark; // 始终 false

  const PreviewPolicy({
    this.enableLut = true,
    this.enableTemperature = true,
    this.enableContrast = true,
    this.enableSaturation = true,
    this.enableVignette = true,
    this.enableGrain = false,
    this.enableBloom = false,
    this.enableChromaticAberration = false,
    this.enablePaperComposite = false,
    this.enableWatermark = false,
  });

  factory PreviewPolicy.fromJson(Map<String, dynamic> json) => PreviewPolicy(
        enableLut: json['enableLut'] as bool? ?? true,
        enableTemperature: json['enableTemperature'] as bool? ?? true,
        enableContrast: json['enableContrast'] as bool? ?? true,
        enableSaturation: json['enableSaturation'] as bool? ?? true,
        enableVignette: json['enableVignette'] as bool? ?? true,
      );
}

// ─── ExportPolicy ─────────────────────────────────────────────────────────────
class ExportPolicy {
  final int maxResolution; // 最大分辨率（长边像素数）
  final int jpegQuality; // JPEG 质量 (0-100)
  final bool preserveMetadata; // 是否保留 EXIF
  final bool applyPaperComposite; // 是否合成相纸边框
  final bool applyWatermark; // 是否合成水印
  final bool applyRatioCrop; // 是否按比例裁剪

  const ExportPolicy({
    this.maxResolution = 4000,
    this.jpegQuality = 92,
    this.preserveMetadata = true,
    this.applyPaperComposite = true,
    this.applyWatermark = true,
    this.applyRatioCrop = true,
  });

  factory ExportPolicy.fromJson(Map<String, dynamic> json) => ExportPolicy(
        maxResolution: json['maxResolution'] as int? ?? 4000,
        jpegQuality: json['jpegQuality'] as int? ?? 92,
        preserveMetadata: json['preserveMetadata'] as bool? ?? true,
        applyPaperComposite: json['applyPaperComposite'] as bool? ?? true,
        applyWatermark: json['applyWatermark'] as bool? ?? true,
        applyRatioCrop: json['applyRatioCrop'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'maxResolution': maxResolution,
        'jpegQuality': jpegQuality,
        'preserveMetadata': preserveMetadata,
        'applyPaperComposite': applyPaperComposite,
        'applyWatermark': applyWatermark,
        'applyRatioCrop': applyRatioCrop,
      };
}

// ─── CameraDefinition（顶层产品对象）─────────────────────────────────────────
class CameraDefinition {
  final String id;
  final String name;
  final String category; // 'digital_ccd' | 'film' | 'instant' | 'video' | 'disposable'
  final String outputType; // 'photo' | 'video' | 'instant'
  final bool isPremium;
  final String? thumbnail; // 缩略图路径

  final BaseModel baseModel;
  final OptionGroups optionGroups;
  final DefaultSelection defaultSelection;
  final UiCapabilities uiCapabilities;
  final PreviewPolicy previewPolicy;
  final ExportPolicy exportPolicy;

  const CameraDefinition({
    required this.id,
    required this.name,
    required this.category,
    this.outputType = 'photo',
    this.isPremium = false,
    this.thumbnail,
    required this.baseModel,
    required this.optionGroups,
    required this.defaultSelection,
    required this.uiCapabilities,
    this.previewPolicy = const PreviewPolicy(),
    this.exportPolicy = const ExportPolicy(),
  });

  // ── 便捷访问器 ──────────────────────────────────────────────────────────────

  /// 获取默认选中的 Film
  FilmOption? get defaultFilm {
    final films = optionGroups.films;
    if (films.isEmpty) return null;
    final id = defaultSelection.filmId;
    if (id != null) {
      try {
        return films.firstWhere((f) => f.id == id);
      } catch (_) {}
    }
    try {
      return films.firstWhere((f) => f.isDefault);
    } catch (_) {
      return films.first;
    }
  }

  /// 获取默认选中的 Lens
  LensOption? get defaultLens {
    final lenses = optionGroups.lenses;
    if (lenses.isEmpty) return null;
    final id = defaultSelection.lensId;
    if (id != null) {
      try {
        return lenses.firstWhere((l) => l.id == id);
      } catch (_) {}
    }
    try {
      return lenses.firstWhere((l) => l.isDefault);
    } catch (_) {
      return lenses.first;
    }
  }

  /// 获取默认选中的 Paper
  PaperOption? get defaultPaper {
    final papers = optionGroups.papers;
    if (papers.isEmpty) return null;
    final id = defaultSelection.paperId;
    if (id != null) {
      try {
        return papers.firstWhere((p) => p.id == id);
      } catch (_) {}
    }
    try {
      return papers.firstWhere((p) => p.isDefault);
    } catch (_) {
      return papers.first;
    }
  }

  /// 获取默认选中的 Ratio
  RatioOption? get defaultRatio {
    final ratios = optionGroups.ratios;
    if (ratios.isEmpty) return null;
    final id = defaultSelection.ratioId;
    if (id != null) {
      try {
        return ratios.firstWhere((r) => r.id == id);
      } catch (_) {}
    }
    try {
      return ratios.firstWhere((r) => r.isDefault);
    } catch (_) {
      return ratios.first;
    }
  }

  /// 获取默认选中的 Watermark
  WatermarkOption? get defaultWatermark {
    final watermarks = optionGroups.watermarks;
    if (watermarks.isEmpty) return null;
    final id = defaultSelection.watermarkId;
    if (id != null) {
      try {
        return watermarks.firstWhere((w) => w.id == id);
      } catch (_) {}
    }
    try {
      return watermarks.firstWhere((w) => w.isDefault);
    } catch (_) {
      return watermarks.first;
    }
  }

  factory CameraDefinition.fromJson(Map<String, dynamic> json) {
    final rawBaseModel = json['baseModel'];
    final baseModel = rawBaseModel is Map<String, dynamic>
        ? BaseModel.fromJson(rawBaseModel)
        : const BaseModel(
            sensor: SensorModel(type: 'ccd'),
            color: ColorModel(),
          );

    final rawOptionGroups = json['optionGroups'];
    final optionGroups = rawOptionGroups is Map<String, dynamic>
        ? OptionGroups.fromJson(rawOptionGroups)
        : const OptionGroups();

    // 解析 defaultSelection：优先读 JSON，否则从 optionGroups 中取 isDefault 项
    DefaultSelection defaultSelection;
    if (json['defaultSelection'] != null) {
      defaultSelection = DefaultSelection.fromJson(
          json['defaultSelection'] as Map<String, dynamic>);
    } else {
      defaultSelection = DefaultSelection(
        filmId: optionGroups.films
            .where((f) => f.isDefault)
            .map((f) => f.id)
            .firstOrNull,
        lensId: optionGroups.lenses
            .where((l) => l.isDefault)
            .map((l) => l.id)
            .firstOrNull,
        paperId: optionGroups.papers
            .where((p) => p.isDefault)
            .map((p) => p.id)
            .firstOrNull,
        ratioId: optionGroups.ratios
            .where((r) => r.isDefault)
            .map((r) => r.id)
            .firstOrNull,
        watermarkId: optionGroups.watermarks
            .where((w) => w.isDefault)
            .map((w) => w.id)
            .firstOrNull,
      );
    }

    return CameraDefinition(
      id: json['id'] as String,
      name: json['name'] as String,
      category: json['category'] as String? ?? 'digital_ccd',
      outputType: json['outputType'] as String? ?? 'photo',
      isPremium: json['isPremium'] as bool? ?? false,
      thumbnail: json['thumbnail'] as String?,
      baseModel: baseModel,
      optionGroups: optionGroups,
      defaultSelection: defaultSelection,
      uiCapabilities: json['uiCapabilities'] != null
          ? UiCapabilities.fromJson(
              json['uiCapabilities'] as Map<String, dynamic>)
          : UiCapabilities(
              showFilmSelector: optionGroups.films.isNotEmpty,
              showLensSelector: optionGroups.lenses.isNotEmpty,
              showPaperSelector: optionGroups.papers.isNotEmpty,
              showRatioSelector: optionGroups.ratios.isNotEmpty,
              showWatermarkSelector: optionGroups.watermarks.isNotEmpty,
            ),
      previewPolicy: json['previewPolicy'] != null
          ? PreviewPolicy.fromJson(
              json['previewPolicy'] as Map<String, dynamic>)
          : const PreviewPolicy(),
      exportPolicy: json['exportPolicy'] != null
          ? ExportPolicy.fromJson(json['exportPolicy'] as Map<String, dynamic>)
          : const ExportPolicy(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'category': category,
        'outputType': outputType,
        'isPremium': isPremium,
        if (thumbnail != null) 'thumbnail': thumbnail,
        'baseModel': baseModel.toJson(),
        'optionGroups': optionGroups.toJson(),
        'defaultSelection': defaultSelection.toJson(),
        'uiCapabilities': uiCapabilities.toJson(),
        'exportPolicy': exportPolicy.toJson(),
      };
}

// ─── 当前相机选中状态 ─────────────────────────────────────────────────────────
class CameraSelectionState {
  final CameraDefinition camera;
  final FilmOption? selectedFilm;
  final LensOption? selectedLens;
  final PaperOption? selectedPaper;
  final RatioOption? selectedRatio;
  final WatermarkOption? selectedWatermark;

  const CameraSelectionState({
    required this.camera,
    this.selectedFilm,
    this.selectedLens,
    this.selectedPaper,
    this.selectedRatio,
    this.selectedWatermark,
  });

  /// 从相机定义创建初始选中状态（使用 defaultSelection）
  factory CameraSelectionState.fromCamera(CameraDefinition camera) {
    return CameraSelectionState(
      camera: camera,
      selectedFilm: camera.defaultFilm,
      selectedLens: camera.defaultLens,
      selectedPaper: camera.defaultPaper,
      selectedRatio: camera.defaultRatio,
      selectedWatermark: camera.defaultWatermark,
    );
  }

  CameraSelectionState copyWith({
    CameraDefinition? camera,
    FilmOption? selectedFilm,
    LensOption? selectedLens,
    PaperOption? selectedPaper,
    RatioOption? selectedRatio,
    WatermarkOption? selectedWatermark,
    bool clearFilm = false,
    bool clearLens = false,
    bool clearPaper = false,
    bool clearRatio = false,
    bool clearWatermark = false,
  }) {
    return CameraSelectionState(
      camera: camera ?? this.camera,
      selectedFilm: clearFilm ? null : (selectedFilm ?? this.selectedFilm),
      selectedLens: clearLens ? null : (selectedLens ?? this.selectedLens),
      selectedPaper: clearPaper ? null : (selectedPaper ?? this.selectedPaper),
      selectedRatio: clearRatio ? null : (selectedRatio ?? this.selectedRatio),
      selectedWatermark: clearWatermark
          ? null
          : (selectedWatermark ?? this.selectedWatermark),
    );
  }

  /// 当前选中的比例值（如 '4:3'）
  String get ratioValue => selectedRatio?.value ?? '4:3';

  /// 当前宽高比
  double get aspectRatio => selectedRatio?.aspectRatio ?? (4 / 3);

  /// 是否有相纸边框
  bool get hasPaper =>
      selectedPaper != null && selectedPaper!.rendering.frameAsset != null;

  /// 是否有水印
  bool get hasWatermark =>
      selectedWatermark != null && !selectedWatermark!.isNone;

  /// 是否有胶卷 LUT
  bool get hasFilmLut =>
      selectedFilm != null && selectedFilm!.rendering.lut != null;
}
