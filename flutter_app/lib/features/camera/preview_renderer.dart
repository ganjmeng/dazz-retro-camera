// preview_renderer.dart
// Real-time preview rendering pipeline for GRD R camera.
// Applies: temperature shift, contrast, saturation, vignette, chromatic aberration,
// bloom, soft-focus, and lens distortion using Flutter CustomPainter + ColorFilter.
//
// Design: Darkroom Aesthetics — deep brown-black, amber highlights, film grain texture.

import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../models/camera_definition.dart';

// ─────────────────────────────────────────────────────────────────────────────
// PreviewRenderParams — all parameters needed for one frame render
// ─────────────────────────────────────────────────────────────────────────────

class PreviewRenderParams {
  final DefaultLook defaultLook;
  final FilterDefinition? activeFilter;
  final LensDefinition? activeLens;
  final double temperatureOffset; // user-adjusted, -100..100
  final double exposureOffset;    // user-adjusted, -2.0..2.0
  final PreviewPolicy policy;

  const PreviewRenderParams({
    DefaultLook? defaultLook,
    this.activeFilter,
    this.activeLens,
    this.temperatureOffset = 0,
    this.exposureOffset = 0,
    PreviewPolicy? policy,
  }) : defaultLook = defaultLook ?? const DefaultLook(
         temperature: 0, contrast: 1.0, saturation: 1.0,
         vignette: 0, distortion: 0, chromaticAberration: 0,
         bloom: 0, flare: 0,
       ),
       policy = policy ?? const PreviewPolicy(
         enableLut: false, enableTemperature: false, enableContrast: false,
         enableSaturation: false, enableVignette: false, enableLightLensEffect: false,
         enableGrain: false, enableBloom: false, enableChromaticAberration: false,
         enableFrameComposite: false, enableWatermarkComposite: false,
       );

  // Effective vignette = defaultLook + lens override
  double get effectiveVignette {
    final base = defaultLook.vignette;
    final lens = activeLens?.vignette ?? 0;
    return (base + lens).clamp(0.0, 1.0);
  }

  double get effectiveChromaticAberration {
    final base = defaultLook.chromaticAberration;
    final lens = activeLens?.chromaticAberration ?? 0;
    return (base + lens).clamp(0.0, 0.1);
  }

  double get effectiveBloom {
    final base = defaultLook.bloom;
    final lens = activeLens?.bloom ?? 0;
    return (base + lens).clamp(0.0, 1.0);
  }

  double get effectiveSoftFocus {
    return (activeLens?.softFocus ?? 0).clamp(0.0, 1.0);
  }

  /// 真实镜头畸变：负值=桶形(barrel/fisheye)，正值=枕形(pincushion/tele)
  /// 来源：defaultLook.distortion + lens.distortion 叠加
  double get effectiveDistortion {
    final base = defaultLook.distortion;
    final lens = activeLens?.distortion ?? 0;
    return (base + lens).clamp(-1.0, 1.0);
  }

  double get effectiveContrast {
    final base = defaultLook.contrast;
    final filter = activeFilter?.contrast ?? 1.0;
    return (base * filter).clamp(0.5, 2.0);
  }

  double get effectiveSaturation {
    final base = defaultLook.saturation;
    final filter = activeFilter?.saturation ?? 1.0;
    return (base * filter).clamp(0.0, 2.0);
  }

  // Temperature: combine defaultLook + user offset
  // defaultLook.temperature is in Kelvin offset (-100 = cool, +100 = warm)
  double get effectiveTemperature {
    return (defaultLook.temperature + temperatureOffset).clamp(-100.0, 100.0);
  }

  double get effectiveTint => defaultLook.tint.clamp(-100.0, 100.0);
  double get effectiveHighlights => defaultLook.highlights.clamp(-100.0, 100.0);
  double get effectiveShadows => defaultLook.shadows.clamp(-100.0, 100.0);
  double get effectiveWhites => defaultLook.whites.clamp(-100.0, 100.0);
  double get effectiveBlacks => defaultLook.blacks.clamp(-100.0, 100.0);
  double get effectiveClarity => defaultLook.clarity.clamp(-100.0, 100.0);
  double get effectiveVibrance => defaultLook.vibrance.clamp(-100.0, 100.0);
  double get effectiveGrain => defaultLook.grain.clamp(0.0, 1.0);
  double get effectiveColorBiasR => defaultLook.colorBiasR.clamp(-1.0, 1.0);
  double get effectiveColorBiasG => defaultLook.colorBiasG.clamp(-1.0, 1.0);
  double get effectiveColorBiasB => defaultLook.colorBiasB.clamp(-1.0, 1.0);
}

// ─────────────────────────────────────────────────────────────────────────────
// PreviewFilterWidget — wraps camera Texture with render effects
// ─────────────────────────────────────────────────────────────────────────────

class PreviewFilterWidget extends StatelessWidget {
  final int textureId;
  final PreviewRenderParams params;
  /// 目标比例（用户选择，如 1:1/3:4/9:16）——只用于取景框容器大小计算
  final double aspectRatio;
  /// 相机传感器实际输出比例（固定为 3/4）——用于 cover 缩放计算
  static const double _kSensorAspect = 3.0 / 4.0; // CameraX 默认输出 4:3

  const PreviewFilterWidget({
    super.key,
    required this.textureId,
    required this.params,
    this.aspectRatio = 3 / 4,
  });

  @override
  Widget build(BuildContext context) {
    // 预览始终充满容器（BoxFit.cover 效果）
    // cover 计算基于传感器实际比例（_kSensorAspect = 3/4）
    // 而不是目标比例（aspectRatio），避免 1:1 等比例切换时画面被拉伸
    return LayoutBuilder(
      builder: (context, constraints) {
        final containerW = constraints.maxWidth;
        final containerH = constraints.maxHeight;
        // 使用传感器实际比例计算 cover
        const sensorAspect = _kSensorAspect;
        // BoxFit.cover：选择让内容充满容器的最小缩放
        final containerAspect = containerW / containerH;
        double overflowW, overflowH;
        if (containerAspect >= sensorAspect) {
          // 容器更宽 → 宽度铺满，高度可能超出
          overflowW = containerW;
          overflowH = containerW / sensorAspect;
        } else {
          // 容器更高 → 高度铺满，宽度可能超出
          overflowH = containerH;
          overflowW = containerH * sensorAspect;
        }
        return ClipRect(
          child: OverflowBox(
            maxWidth: overflowW,
            maxHeight: overflowH,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Layer 1: Raw camera texture with color correction
                _ColorCorrectedTexture(textureId: textureId, params: params),

                // Layer 2: Chromatic aberration (color fringing)
                if (params.policy.enableChromaticAberration &&
                    params.effectiveChromaticAberration > 0.001)
                  _ChromaticAberrationLayer(
                    textureId: textureId,
                    strength: params.effectiveChromaticAberration,
                  ),

                // Layer 3: Bloom / soft glow
                if (params.policy.enableBloom && params.effectiveBloom > 0.01)
                  _BloomLayer(
                    textureId: textureId,
                    strength: params.effectiveBloom,
                    softFocus: params.effectiveSoftFocus,
                  ),

                // Layer 4: Vignette overlay
                if (params.policy.enableVignette && params.effectiveVignette > 0.01)
                  _VignetteLayer(strength: params.effectiveVignette),

                // Layer 5: Lens distortion — handled by native GPU shader (Android OpenGL ES / iOS Metal)
                // updateLensParams(distortion) is called via MethodChannel when lens changes
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Layer 1: Color-corrected camera texture
// ─────────────────────────────────────────────────────────────────────────────

class _ColorCorrectedTexture extends StatelessWidget {
  final int textureId;
  final PreviewRenderParams params;

  const _ColorCorrectedTexture({
    required this.textureId,
    required this.params,
  });

  @override
  Widget build(BuildContext context) {
    final colorMatrix = buildColorMatrix(params);

    return ColorFiltered(
      colorFilter: ColorFilter.matrix(colorMatrix),
      child: Texture(textureId: textureId),
    );
  }

  /// Build a 5x4 color matrix combining the full pipeline:
  /// Exposure → Temperature → Tint → Blacks/Whites → Contrast → Highlights/Shadows
  /// → Clarity → Saturation → Vibrance → ColorBias
  static List<double> buildColorMatrix(PreviewRenderParams params) {
    var m = _identity();

    // 1. Exposure (brightness multiplier)
    final expMul = math.pow(2.0, params.exposureOffset).toDouble();
    m = _multiply(m, _exposureMatrix(expMul));

    // 2. Temperature shift (warm/cool)
    if (params.policy.enableTemperature) {
      m = _multiply(m, _temperatureMatrix(params.effectiveTemperature));
    }

    // 3. Tint shift (green/magenta)
    if (params.policy.enableTemperature && params.effectiveTint.abs() > 0.5) {
      m = _multiply(m, _tintMatrix(params.effectiveTint));
    }

    // 4. Blacks & Whites (offset-based tone mapping)
    if (params.policy.enableContrast) {
      if (params.effectiveBlacks.abs() > 0.5 || params.effectiveWhites.abs() > 0.5) {
        m = _multiply(m, _blacksWhitesMatrix(params.effectiveBlacks, params.effectiveWhites));
      }
    }

    // 5. Contrast (pivot at 0.5)
    if (params.policy.enableContrast) {
      m = _multiply(m, _contrastMatrix(params.effectiveContrast));
    }

    // 6. Highlights & Shadows (zone-based compression)
    if (params.policy.enableContrast) {
      if (params.effectiveHighlights.abs() > 0.5 || params.effectiveShadows.abs() > 0.5) {
        m = _multiply(m, _highlightsShadowsMatrix(
          params.effectiveHighlights, params.effectiveShadows));
      }
    }

    // 7. Clarity (midtone contrast boost — approximated via contrast + offset)
    if (params.policy.enableContrast && params.effectiveClarity.abs() > 0.5) {
      m = _multiply(m, _clarityMatrix(params.effectiveClarity));
    }

    // 8. Saturation
    if (params.policy.enableSaturation) {
      m = _multiply(m, _saturationMatrix(params.effectiveSaturation));
    }

    // 9. Vibrance (smart saturation — boosts low-saturation areas more)
    if (params.policy.enableSaturation && params.effectiveVibrance.abs() > 0.5) {
      m = _multiply(m, _vibranceMatrix(params.effectiveVibrance));
    }

    // 10. Color Bias (per-channel offset for film emulation)
    if (params.effectiveColorBiasR.abs() > 0.005 ||
        params.effectiveColorBiasG.abs() > 0.005 ||
        params.effectiveColorBiasB.abs() > 0.005) {
      m = _multiply(m, _colorBiasMatrix(
        params.effectiveColorBiasR,
        params.effectiveColorBiasG,
        params.effectiveColorBiasB,
      ));
    }

    return m;
  }

  static List<double> _identity() => [
    1, 0, 0, 0, 0,
    0, 1, 0, 0, 0,
    0, 0, 1, 0, 0,
    0, 0, 0, 1, 0,
  ];

  static List<double> _exposureMatrix(double mul) => [
    mul, 0, 0, 0, 0,
    0, mul, 0, 0, 0,
    0, 0, mul, 0, 0,
    0, 0, 0, 1, 0,
  ];

  /// Temperature: warm = more red/yellow, cool = more blue/cyan
  /// Green channel stays neutral to avoid purple/magenta cast on cool temperatures.
  static List<double> _temperatureMatrix(double temp) {
    // temp: -100 (cool) to +100 (warm)
    final t = temp / 100.0;
    final rShift = t * 0.20;   // warm: +red, cool: -red
    final bShift = -t * 0.20;  // warm: -blue, cool: +blue
    // Green is intentionally kept at 1.0 to avoid purple/magenta tint
    return [
      1 + rShift, 0, 0, 0, 0,
      0, 1.0, 0, 0, 0,
      0, 0, 1 + bShift, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  /// Contrast: pivot at 0.5
  /// Flutter ColorFilter.matrix offset column is in 0-255 range (not 0-1).
  static List<double> _contrastMatrix(double contrast) {
    final offset = 0.5 * (1 - contrast) * 255;
    return [
      contrast, 0, 0, 0, offset,
      0, contrast, 0, 0, offset,
      0, 0, contrast, 0, offset,
      0, 0, 0, 1, 0,
    ];
  }

  /// Saturation using luminance weights
  static List<double> _saturationMatrix(double sat) {
    const lr = 0.2126;
    const lg = 0.7152;
    const lb = 0.0722;
    final sr = (1 - sat) * lr;
    final sg = (1 - sat) * lg;
    final sb = (1 - sat) * lb;
    return [
      sr + sat, sg, sb, 0, 0,
      sr, sg + sat, sb, 0, 0,
      sr, sg, sb + sat, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  /// Tint: green/magenta axis shift
  /// tint: -100 (green) to +100 (magenta)
  static List<double> _tintMatrix(double tint) {
    final t = tint / 100.0;
    // Magenta = more red + more blue, less green
    // Green = more green, less red + less blue
    final gShift = -t * 0.12;  // tint>0 (magenta): reduce green
    final rbShift = t * 0.06;  // tint>0 (magenta): slight red+blue boost
    return [
      1 + rbShift, 0, 0, 0, 0,
      0, 1 + gShift, 0, 0, 0,
      0, 0, 1 + rbShift, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  /// Blacks & Whites: offset the black point and white point
  /// blacks: -100 (crush blacks) to +100 (lift blacks)
  /// whites: -100 (lower whites) to +100 (boost whites)
  static List<double> _blacksWhitesMatrix(double blacks, double whites) {
    // blacks: positive lifts shadows (adds offset), negative crushes
    // whites: positive expands highlights (scale), negative compresses
    final blacksOffset = blacks / 100.0 * 20.0;  // max ±20/255 offset
    final whitesScale = 1.0 + whites / 100.0 * 0.15; // max ±15% scale
    return [
      whitesScale, 0, 0, 0, blacksOffset,
      0, whitesScale, 0, 0, blacksOffset,
      0, 0, whitesScale, 0, blacksOffset,
      0, 0, 0, 1, 0,
    ];
  }

  /// Highlights & Shadows: zone-based tonal adjustment
  /// Approximated as asymmetric contrast around pivot points
  /// highlights: -100 (compress highlights) to +100 (boost highlights)
  /// shadows: -100 (deepen shadows) to +100 (lift shadows)
  static List<double> _highlightsShadowsMatrix(double highlights, double shadows) {
    // Highlights: affect upper tonal range (pivot at 0.75 = 191/255)
    // Shadows: affect lower tonal range (pivot at 0.25 = 64/255)
    // Approximation: use two-pass offset + scale
    final hScale = 1.0 + highlights / 100.0 * 0.12;
    final hOffset = -highlights / 100.0 * 0.12 * 191.0;
    final sScale = 1.0 - shadows / 100.0 * 0.08;
    final sOffset = shadows / 100.0 * 0.08 * 64.0 + shadows / 100.0 * 12.0;
    // Combine: net scale and offset
    final scale = hScale * sScale;
    final offset = hOffset * sScale + sOffset;
    return [
      scale, 0, 0, 0, offset,
      0, scale, 0, 0, offset,
      0, 0, scale, 0, offset,
      0, 0, 0, 1, 0,
    ];
  }

  /// Clarity: midtone micro-contrast boost
  /// Approximated as S-curve: increase contrast around midtones
  /// clarity: -100 (soften) to +100 (sharpen midtones)
  static List<double> _clarityMatrix(double clarity) {
    // Clarity boosts contrast in the midtone range (0.3-0.7)
    // Approximation: slight contrast increase + compensating offset
    final c = clarity / 100.0;
    final boost = 1.0 + c * 0.15;  // max 15% contrast boost
    final offset = -c * 0.15 * 0.5 * 255; // compensate pivot
    return [
      boost, 0, 0, 0, offset,
      0, boost, 0, 0, offset,
      0, 0, boost, 0, offset,
      0, 0, 0, 1, 0,
    ];
  }

  /// Vibrance: smart saturation (boosts low-saturation colors more)
  /// Approximated as weighted saturation with skin-tone protection
  /// vibrance: -100 (desaturate) to +100 (boost)
  static List<double> _vibranceMatrix(double vibrance) {
    // Vibrance is approximately 60% of equivalent saturation boost
    // but weighted to protect already-saturated colors
    // Approximation: lower saturation multiplier than full saturation
    final v = vibrance / 100.0 * 0.6;
    final sat = 1.0 + v;
    const lr = 0.2126;
    const lg = 0.7152;
    const lb = 0.0722;
    final sr = (1 - sat) * lr;
    final sg = (1 - sat) * lg;
    final sb = (1 - sat) * lb;
    return [
      sr + sat, sg, sb, 0, 0,
      sr, sg + sat, sb, 0, 0,
      sr, sg, sb + sat, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  /// Color Bias: per-channel offset for film emulation
  /// bias: -1.0 to +1.0, maps to ±30/255 offset per channel
  static List<double> _colorBiasMatrix(double r, double g, double b) {
    return [
      1, 0, 0, 0, r * 30.0,
      0, 1, 0, 0, g * 30.0,
      0, 0, 1, 0, b * 30.0,
      0, 0, 0, 1, 0,
    ];
  }

  /// Multiply two 5x4 color matrices (row-major, 20 elements)
  static List<double> _multiply(List<double> a, List<double> b) {
    final result = List<double>.filled(20, 0);
    for (int row = 0; row < 4; row++) {
      for (int col = 0; col < 5; col++) {
        double sum = 0;
        for (int k = 0; k < 4; k++) {
          sum += a[row * 5 + k] * b[k * 5 + col];
        }
        if (col == 4) {
          sum += a[row * 5 + 4]; // translation component
        }
        result[row * 5 + col] = sum;
      }
    }
    return result;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Layer 2: Chromatic Aberration (RGB channel offset)
// ─────────────────────────────────────────────────────────────────────────────

class _ChromaticAberrationLayer extends StatelessWidget {
  final int textureId;
  final double strength; // 0..0.1

  const _ChromaticAberrationLayer({
    required this.textureId,
    required this.strength,
  });

  @override
  @override
  Widget build(BuildContext context) {
    // offset: 边缘色差偏移量
    final offset = strength * 6.0; // pixels
    // alpha 随 strength 线性缩放，避免固定 alpha 导致全局偏紫色
    // strength=0.1(max) → alpha=0.25; strength=0.025 → alpha=0.06
    final alpha = (strength / 0.1 * 0.25).clamp(0.0, 0.25);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Red channel shifted left (alpha scales with strength)
        Positioned.fill(
          child: Transform.translate(
            offset: Offset(-offset, 0),
            child: ColorFiltered(
              colorFilter: ColorFilter.matrix([
                1, 0, 0, 0, 0,
                0, 0, 0, 0, 0,
                0, 0, 0, 0, 0,
                0, 0, 0, alpha, 0,
              ]),
              child: Texture(textureId: textureId),
            ),
          ),
        ),
        // Blue channel shifted right (alpha scales with strength)
        Positioned.fill(
          child: Transform.translate(
            offset: Offset(offset, 0),
            child: ColorFiltered(
              colorFilter: ColorFilter.matrix([
                0, 0, 0, 0, 0,
                0, 0, 0, 0, 0,
                0, 0, 1, 0, 0,
                0, 0, 0, alpha, 0,
              ]),
              child: Texture(textureId: textureId),
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Layer 3: Bloom / Soft Focus Glow
// ─────────────────────────────────────────────────────────────────────────────

class _BloomLayer extends StatelessWidget {
  final int textureId;
  final double strength; // 0..1
  final double softFocus; // 0..1

  const _BloomLayer({
    required this.textureId,
    required this.strength,
    required this.softFocus,
  });

  @override
  Widget build(BuildContext context) {
    final blurRadius = (strength * 12 + softFocus * 20).clamp(0.0, 30.0);
    final opacity = (strength * 0.25 + softFocus * 0.15).clamp(0.0, 0.5);

    return Opacity(
      opacity: opacity,
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: blurRadius,
          sigmaY: blurRadius,
          tileMode: TileMode.clamp,
        ),
        child: ColorFiltered(
          colorFilter: const ColorFilter.matrix([
            1.2, 0, 0, 0, 0,
            0, 1.1, 0, 0, 0,
            0, 0, 0.9, 0, 0,
            0, 0, 0, 1, 0,
          ]),
          child: Texture(textureId: textureId),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Layer 4: Vignette (radial dark gradient)
// ─────────────────────────────────────────────────────────────────────────────

class _VignetteLayer extends StatelessWidget {
  final double strength; // 0..1

  const _VignetteLayer({required this.strength});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _VignettePainter(strength: strength),
      ),
    );
  }
}

class _VignettePainter extends CustomPainter {
  final double strength;

  const _VignettePainter({required this.strength});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.sqrt(
      size.width * size.width + size.height * size.height,
    ) / 2;

    // Inner radius: clear zone (60% of frame)
    final innerRadius = radius * (1.0 - strength * 0.5);
    // Outer radius: full dark
    final outerRadius = radius * 1.1;

    final paint = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 1.0,
        colors: [
          Colors.transparent,
          Colors.transparent,
          Colors.black.withAlpha((strength * 200).round()),
        ],
        stops: [
          0.0,
          innerRadius / outerRadius,
          1.0,
        ],
      ).createShader(Rect.fromCircle(center: center, radius: outerRadius));

    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(_VignettePainter old) => old.strength != strength;
}
// ─────────────────────────────────────────────────────────────────────────────
// WatermarkOverlay — renders date/time watermark on preview
// ─────────────────────────────────────────────────────────────────────────────

class WatermarkOverlay extends StatelessWidget {
  final WatermarkPreset? preset;

  const WatermarkOverlay({super.key, this.preset});

  @override
  Widget build(BuildContext context) {
    if (preset == null || preset!.isNone) return const SizedBox.shrink();

    final color = _parseColor(preset!.color ?? '#FF8A3D');
    final now = DateTime.now();
    final dateStr =
        '${now.month} ${now.day.toString().padLeft(2, ' ')} \'${now.year.toString().substring(2)}';

    return Positioned(
      right: 16,
      bottom: 16,
      child: Text(
        dateStr,
        style: TextStyle(
          color: color,
          fontSize: preset!.fontSize ?? 14,
          fontFamily: 'monospace',
          fontWeight: FontWeight.bold,
          shadows: [
            Shadow(
              color: Colors.black.withAlpha(120),
              blurRadius: 4,
              offset: const Offset(1, 1),
            ),
          ],
        ),
      ),
    );
  }

  Color _parseColor(String hex) {
    try {
      final h = hex.replaceAll('#', '');
      return Color(int.parse('FF$h', radix: 16));
    } catch (_) {
      return const Color(0xFFFF8A3D);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// GridOverlay — rule-of-thirds grid
// ─────────────────────────────────────────────────────────────────────────────

class GridOverlay extends StatelessWidget {
  const GridOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _GridPainter(),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withAlpha(60)
      ..strokeWidth = 0.5;

    // Vertical lines at 1/3 and 2/3
    canvas.drawLine(
      Offset(size.width / 3, 0),
      Offset(size.width / 3, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(size.width * 2 / 3, 0),
      Offset(size.width * 2 / 3, size.height),
      paint,
    );

    // Horizontal lines at 1/3 and 2/3
    canvas.drawLine(
      Offset(0, size.height / 3),
      Offset(size.width, size.height / 3),
      paint,
    );
    canvas.drawLine(
      Offset(0, size.height * 2 / 3),
      Offset(size.width, size.height * 2 / 3),
      paint,
    );
  }

  @override
  bool shouldRepaint(_GridPainter old) => false;
}


/// Public top-level helper: compute a 20-element color matrix from [PreviewRenderParams].
/// Used by ImageEditScreen to apply the same DAZZ color pipeline to static images.
List<double> computeColorMatrix(PreviewRenderParams params) =>
    _ColorCorrectedTexture.buildColorMatrix(params);
