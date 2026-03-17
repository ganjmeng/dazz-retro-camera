import 'dart:ui' as ui;
import '../capture_pipeline_ext.dart';
import '../preview_renderer.dart';

Future<ui.Image> processGRDR(ui.Image srcImage, PreviewRenderParams params) async {
  // GRDR Shader: 12 passes

  // Pass 3: Highlight Rolloff (0.10)
  srcImage = await drawHighlightRolloff(srcImage, 0.10);

  // Pass 8: Skin Protection
  srcImage = await drawSkinHueProtect(srcImage, 1.0);

  // Pass 9: Sensor Non-uniformity
  srcImage = await drawSensorNonUniformity(srcImage, 0.02, 0.05);

  return srcImage;
}
