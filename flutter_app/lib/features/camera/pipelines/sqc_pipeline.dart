import 'dart:ui' as ui;
import './pipeline_utils.dart';
import '../capture_pipeline_ext.dart';
import '../preview_renderer.dart';
import './instc_pipeline.dart' show applyIsolateEffects;

/// SQC / Inst SQ 专属成片管线
/// 对标 SQCShader.metal（19 Pass），补全预览中被 SIMPLIFIED 注释掉的 8 个 Pass
/// SQC 与 InstC 算法相同，参数略有差异（通过 defaultLook JSON 配置传入）
Future<ui.Image> processSQC(ui.Image srcImage, PreviewRenderParams params) async {
  // ── Pass 8: Highlight Rolloff ──────────────────────────────────────────────
  // SQC defaultLook: highlightRolloff=0.28（比 InstC 更强，SQ 相纸更亮）
  if (params.highlightRolloff > 0.001) {
    srcImage = await drawHighlightRolloff(srcImage, params.highlightRolloff);
  }

  // ── Pass 15: Edge Falloff + Center Gain + Corner Warm Shift ───────────────
  // SQC defaultLook: centerGain=0.03, edgeFalloff=0.06, cornerWarmShift=0.03
  if (params.centerGain > 0.001 || params.edgeFalloff > 0.001) {
    srcImage = await drawSensorNonUniformity(
      srcImage,
      params.centerGain,
      params.edgeFalloff,
      cornerWarmShift: params.defaultLook.cornerWarmShift,
    );
  }

  // ── Pass 16: Development Softness ─────────────────────────────────────────
  // SQC defaultLook: developmentSoftness=0.04（比 InstC 稍强，SQ 化学扩散更明显）
  if (params.developmentSoftness > 0.001) {
    srcImage = await drawDevelopmentSoftness(srcImage, params.developmentSoftness);
  }

  // ── Pass 12 + 13 + 14 + 17: Fine Grain + Paper Texture + Skin + Chemical ──
  // SQC paperUvScale1=120.0（SQC 相纸纤维更密，UV 缩放更大）
  // SQC irregUvScale=3.0（SQC 化学不规则感空间频率更高）
  final isoParams = IsolateParams.from(params);
  if (isoParams.chemicalIrregularity > 0.001 ||
      isoParams.paperTexture > 0.001 ||
      isoParams.skinHueProtect) {
    srcImage = await applyIsolateEffects(srcImage, isoParams);
  }

  return srcImage;
}
