import 'dart:ui' as ui;
import '../capture_pipeline_ext.dart';
import '../preview_renderer.dart';

Future<ui.Image> processCPM35(ui.Image srcImage, PreviewRenderParams params) async {
  // CPM35 Shader: 16 passes

  // Pass 7: Highlight Rolloff (0.14)
  srcImage = await drawHighlightRolloff(srcImage, 0.14);

  // Pass 11: Skin Protection (skinRedLimit=1.05)
  srcImage = await drawSkinHueProtect(srcImage, 1.05);

  // Pass 12: Sensor Non-uniformity
  srcImage = await drawSensorNonUniformity(srcImage, 0.04, 0.10);

  // Pass 13: Development Softness (0.028)
  srcImage = await drawDevelopmentSoftness(srcImage, 0.028);

  return srcImage;
}
