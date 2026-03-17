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
         enableGrain: false, enableBloom: false, enableHalation: false,
         enablePaperTexture: false, enableChromaticAberration: false,
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

  double get effectiveHalation => defaultLook.halation.clamp(0.0, 1.0);

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
    final lens = activeLens?.contrast ?? 0.0; // lens.contrast is additive offset
    return (base * filter + lens).clamp(0.5, 2.0);
  }

  double get effectiveSaturation {
    final base = defaultLook.saturation;
    final filter = activeFilter?.saturation ?? 1.0;
    final lens = activeLens?.saturation ?? 0.0; // lens.saturation is additive offset
    return (base * filter + lens).clamp(0.0, 2.0);
  }

  /// 镜头曝光偏移（叠加到 exposureOffset 上）
  double get effectiveLensExposure => activeLens?.exposure ?? 0.0;

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

  // ── 拍立得即时成像专属参数 getter ──────────────────────────────────────────────
  double get highlightRolloff => defaultLook.highlightRolloff.clamp(0.0, 1.0);
  double get centerGain => defaultLook.centerGain.clamp(0.0, 0.2);
  double get edgeFalloff => defaultLook.edgeFalloff.clamp(0.0, 1.0);
  double get cornerWarmShift => defaultLook.cornerWarmShift.clamp(0.0, 5.0);
  double get skinHueProtect => defaultLook.skinHueProtect ? 1.0 : 0.0;
  double get chemicalIrregularity => defaultLook.chemicalIrregularity.clamp(0.0, 0.1);
  /// FIX: noiseAmount 现已添加到 DefaultLook
  double get noiseAmount => defaultLook.noiseAmount.clamp(0.0, 1.0);
  double get skinSatProtect => defaultLook.skinSatProtect.clamp(0.0, 1.0);
  double get skinLumaSoften => defaultLook.skinLumaSoften.clamp(0.0, 0.2);
  double get skinRedLimit => defaultLook.skinRedLimit.clamp(0.9, 1.2);

  double get paperTexture => defaultLook.paperTexture.clamp(0.0, 1.0);
  double get developmentSoftness => defaultLook.developmentSoftness.clamp(0.0, 1.0);

  // 化学不规则感参数
  double get irregUvScale => defaultLook.irregUvScale;
  double get irregFreq1 => defaultLook.irregFreq1;
  double get irregFreq2 => defaultLook.irregFreq2;
  double get irregWeight1 => defaultLook.irregWeight1;
  double get irregWeight2 => defaultLook.irregWeight2;

  // 相纸纹理参数
  double get paperUvScale1 => defaultLook.paperUvScale1;
  double get paperUvScale2 => defaultLook.paperUvScale2;
  double get paperWeight1 => defaultLook.paperWeight1;
  double get paperWeight2 => defaultLook.paperWeight2;

  Map<String, dynamic> toJson() => {
        'contrast': effectiveContrast,
        'saturation': effectiveSaturation,
        'temperatureShift': effectiveTemperature,
        'tintShift': effectiveTint,
        'highlights': effectiveHighlights,
        'shadows': effectiveShadows,
        'whites': effectiveWhites,
        'blacks': effectiveBlacks,
        'clarity': effectiveClarity,
        'vibrance': effectiveVibrance,
        'colorBiasR': effectiveColorBiasR,
        'colorBiasG': effectiveColorBiasG,
        'colorBiasB': effectiveColorBiasB,
        'grainAmount': effectiveGrain,
        'noiseAmount': noiseAmount,
        'vignetteAmount': effectiveVignette,
        'chromaticAberration': effectiveChromaticAberration,
        'bloomAmount': effectiveBloom,
        'highlightRolloff': highlightRolloff,
        'paperTexture': paperTexture,
        'edgeFalloff': edgeFalloff,
        'cornerWarmShift': defaultLook.cornerWarmShift, // 直接从 defaultLook 读取
        'centerGain': centerGain,
        'developmentSoftness': developmentSoftness,
        'chemicalIrregularity': chemicalIrregularity,
        'skinHueProtect': skinHueProtect,
        'skinSatProtect': defaultLook.skinSatProtect,
        'skinLumaSoften': defaultLook.skinLumaSoften,
        'skinRedLimit': defaultLook.skinRedLimit,

        'irregUvScale': irregUvScale,
        'irregFreq1': irregFreq1,
        'irregFreq2': irregFreq2,
        'irregWeight1': irregWeight1,
        'irregWeight2': irregWeight2,

        'paperUvScale1': paperUvScale1,
        'paperUvScale2': paperUvScale2,
        'paperWeight1': paperWeight1,
        'paperWeight2': paperWeight2,
        'halationAmount': effectiveHalation,
        'lensVignette': effectiveVignette,
        'exposureOffset': exposureOffset + effectiveLensExposure,
        'softFocus': effectiveSoftFocus,
        'distortion': effectiveDistortion,
        'grainSize': defaultLook.grainSize.clamp(0.5, 3.0),
        'luminanceNoise': defaultLook.luminanceNoise.clamp(0.0, 0.5),
        'chromaNoise': defaultLook.chromaNoise.clamp(0.0, 0.5),
        'exposureVariation': defaultLook.exposureVariation.clamp(0.0, 0.1),
        // ── 新增：Fade / Split Toning / Light Leak ──
        'fadeAmount': defaultLook.fadeAmount.clamp(0.0, 0.5),
        'fade': defaultLook.fadeAmount.clamp(0.0, 0.5),
        'shadowTintR': defaultLook.shadowTintR.clamp(-0.2, 0.2),
        'shadowTintG': defaultLook.shadowTintG.clamp(-0.2, 0.2),
        'shadowTintB': defaultLook.shadowTintB.clamp(-0.2, 0.2),
        'highlightTintR': defaultLook.highlightTintR.clamp(-0.2, 0.2),
        'highlightTintG': defaultLook.highlightTintG.clamp(-0.2, 0.2),
        'highlightTintB': defaultLook.highlightTintB.clamp(-0.2, 0.2),
        'splitToneBalance': defaultLook.splitToneBalance.clamp(0.0, 1.0),
        'lightLeakAmount': defaultLook.lightLeakAmount.clamp(0.0, 1.0),
      };
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
            // Phase 2 重构：所有渲染特效已下沉到 Native GPU Shader
            // Flutter 层仅显示纯 Texture，不再做像素级渲染
            // 色彩调整、色差、Bloom、Halation、相纸纹理、暗角等全部由 Native Shader 处理
            child: Texture(textureId: textureId),
          ),
        );
      },
    );
  }
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

