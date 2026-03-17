import 'dart:ui' as ui;
import '../capture_pipeline_ext.dart';
import '../preview_renderer.dart';

Future<ui.Image> processFQS(ui.Image srcImage, PreviewRenderParams params) async {
  // FQS Shader: 15 passes

  // Pass 1.5: Development Softness (0.02)
  srcImage = await drawDevelopmentSoftness(srcImage, 0.02);

  // Pass 6.5: Highlight Rolloff (0.12)
  srcImage = await drawHighlightRolloff(srcImage, 0.12);

  // Pass 7: Skin Protection
  srcImage = await drawSkinHueProtect(srcImage, 1.0);

  // Pass 11.5: Sensor Non-uniformity
  srcImage = await drawSensorNonUniformity(srcImage, 0.03, 0.08);

  return srcImage;
}
