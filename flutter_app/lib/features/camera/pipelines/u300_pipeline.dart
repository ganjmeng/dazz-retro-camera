import 'dart:ui' as ui;
import './pipeline_utils.dart';
import '../capture_pipeline_ext.dart';
import '../preview_renderer.dart';

Future<ui.Image> processU300(ui.Image srcImage, PreviewRenderParams params) async {
  // U300 Shader: 14 passes

  // Pass 2: Highlight Rolloff (0.15)
  srcImage = /* HighlightRolloff LUT (val: 0.15) */

  // Pass 7: Skin Protection
  srcImage = /* SkinHueProtect (val: 1.0) */

  // Pass 8: Sensor Non-uniformity
  srcImage = /* SensorNonUniformity Table (cg: 0.06, ef: 0.15) */

  // Pass 9: Development Softness (0.03)
  srcImage = await drawDevelopmentSoftness(srcImage, 0.03);

  // Pass 10: Chemical Irregularity (0.025)
  srcImage = await drawChemicalIrregularity(srcImage, 0.025);

  return srcImage;
}
