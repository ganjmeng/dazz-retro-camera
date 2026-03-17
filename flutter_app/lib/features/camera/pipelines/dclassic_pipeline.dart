import 'dart:ui' as ui;
import './pipeline_utils.dart';
import '../capture_pipeline_ext.dart';
import '../preview_renderer.dart';
import './instc_pipeline.dart' show _applyIsolateEffects;

/// D-Classic 专属成片管线
/// 对标 CameraShaders.metal（通用 CCD Shader），参数参考 D-Classic defaultLook
/// D-Classic（2000 年代数码卡片机）偏暖、柔和、家庭感
Future<ui.Image> processDClassic(ui.Image srcImage, PreviewRenderParams params) async {
  // ── Pass 1: Highlight Rolloff ──────────────────────────────────────────────
  // D-Classic defaultLook: highlightRolloff=0.08（极轻，数码传感器高光截断比胶片硬）
  if (params.highlightRolloff > 0.001) {
    srcImage = await drawHighlightRolloff(srcImage, params.highlightRolloff);
  }

  // ── Pass 2: Sensor Non-uniformity ─────────────────────────────────────────
  // D-Classic defaultLook: centerGain=0.015, edgeFalloff=0.025（极轻，数码传感器均匀）
  // D-Classic cornerWarmShift=0.0（无角落偏色，数码传感器色彩均匀）
  if (params.centerGain > 0.001 || params.edgeFalloff > 0.001) {
    srcImage = await drawSensorNonUniformity(
      srcImage,
      params.centerGain,
      params.edgeFalloff,
      cornerWarmShift: params.defaultLook.cornerWarmShift,
    );
  }

  // ── Pass 3: Skin Protection ────────────────────────────────────────────────
  // D-Classic defaultLook: skinHueProtect=0.98（轻度，家庭日常用途）
  // skinSatProtect=0.98, skinLumaSoften=0.01, skinRedLimit=1.02（最保守参数）
  final isoParams = IsolateParams.from(params);
  if (isoParams.skinHueProtect) {
    srcImage = await _applyIsolateEffects(srcImage, isoParams);
  }

  return srcImage;
}
