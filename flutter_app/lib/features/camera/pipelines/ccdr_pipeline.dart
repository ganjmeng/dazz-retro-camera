import 'dart:ui' as ui;
import './pipeline_utils.dart';
import '../capture_pipeline_ext.dart';
import '../preview_renderer.dart';
import './instc_pipeline.dart' show _applyIsolateEffects;

/// CCD-R / CCD-M 专属成片管线
/// 对标 CCDRShader.metal（14 Pass），补全预览中被 SIMPLIFIED 注释掉的 4 个 Pass
/// CCD-R / CCD-M（复古 CCD 相机）最强边缘衰减，轻微高光滚落，化学感极轻
Future<ui.Image> processCCDR(ui.Image srcImage, PreviewRenderParams params) async {
  // ── Pass 2: Highlight Rolloff ──────────────────────────────────────────────
  // CCD-R defaultLook: highlightRolloff=0.06（最轻，CCD 传感器高光截断硬）
  if (params.highlightRolloff > 0.001) {
    srcImage = await drawHighlightRolloff(srcImage, params.highlightRolloff);
  }

  // ── Pass 8: Sensor Non-uniformity ─────────────────────────────────────────
  // CCD-R defaultLook: centerGain=0.08, edgeFalloff=0.20（最强，CCD 镜头边缘衰减明显）
  // CCD-R cornerWarmShift=0.03（角落偏暖，模拟 CCD 传感器色差）
  if (params.centerGain > 0.001 || params.edgeFalloff > 0.001) {
    srcImage = await drawSensorNonUniformity(
      srcImage,
      params.centerGain,
      params.edgeFalloff,
      cornerWarmShift: params.defaultLook.cornerWarmShift,
    );
  }

  // ── Pass 7 + 9: Skin Protection + Chemical Irregularity ───────────────────
  // CCD-R defaultLook: skinHueProtect=1.0, skinSatProtect=0.95
  // CCD-R defaultLook: chemicalIrregularity=0.008（极轻，CCD 无化学显影）
  final isoParams = IsolateParams.from(params);
  if (isoParams.chemicalIrregularity > 0.001 || isoParams.skinHueProtect) {
    srcImage = await _applyIsolateEffects(srcImage, isoParams);
  }

  return srcImage;
}
