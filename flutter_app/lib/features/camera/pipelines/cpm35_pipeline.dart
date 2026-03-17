import 'dart:ui' as ui;
import './pipeline_utils.dart';
import '../capture_pipeline_ext.dart';
import '../preview_renderer.dart';

Future<ui.Image> processCPM35(ui.Image srcImage, PreviewRenderParams params) async {
  // CPM35 Shader: 16 passes

  // Pass 7: Highlight Rolloff (0.14)
  srcImage = /* HighlightRolloff LUT (val: 0.14) */

  // Pass 11: Skin Protection (skinRedLimit=1.05)
  srcImage = /* SkinHueProtect (val: 1.05) */

  // Pass 12: Sensor Non-uniformity
  srcImage = /* SensorNonUniformity Table (cg: 0.04, ef: 0.10) */

  // Pass 13: Development Softness (0.028)
  srcImage = await drawDevelopmentSoftness(srcImage, 0.028);

  return srcImage;
}
