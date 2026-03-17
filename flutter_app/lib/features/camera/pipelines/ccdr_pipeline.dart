import 'dart:ui' as ui;
import '../capture_pipeline_ext.dart';
import '../preview_renderer.dart';

Future<ui.Image> processCCDR(ui.Image srcImage, PreviewRenderParams params) async {
  // CCDR Shader: 14 passes

  // Pass 2: Highlight Rolloff (0.06)
  srcImage = await drawHighlightRolloff(srcImage, 0.06);

  // Pass 7: Skin Protection
  srcImage = await drawSkinHueProtect(srcImage, 1.0);

  // Pass 8: Sensor Non-uniformity
  srcImage = await drawSensorNonUniformity(srcImage, 0.08, 0.20);

  // Pass 9: Chemical Irregularity (0.008)
  srcImage = await drawChemicalIrregularity(srcImage, 0.008);

  return srcImage;
}
