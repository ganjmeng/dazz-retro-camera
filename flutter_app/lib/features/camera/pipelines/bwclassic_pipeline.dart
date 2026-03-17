import 'dart:ui' as ui;
import '../capture_pipeline_ext.dart';
import '../preview_renderer.dart';

Future<ui.Image> processBWClassic(ui.Image srcImage, PreviewRenderParams params) async {
  // BWClassic Shader: 12 passes

  // Pass 4: Highlight Rolloff (0.18)
  srcImage = await drawHighlightRolloff(srcImage, 0.18);

  // Pass 6: Sensor Non-uniformity
  srcImage = await drawSensorNonUniformity(srcImage, 0.05, 0.12);

  // Pass 7: Development Softness (0.025)
  srcImage = await drawDevelopmentSoftness(srcImage, 0.025);

  // Pass 8: Chemical Irregularity (0.018)
  srcImage = await drawChemicalIrregularity(srcImage, 0.018);

  return srcImage;
}
