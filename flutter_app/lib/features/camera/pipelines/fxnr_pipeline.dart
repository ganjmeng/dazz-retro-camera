import 'dart:ui' as ui;
import './pipeline_utils.dart';
import '../capture_pipeline_ext.dart';
import '../preview_renderer.dart';

Future<ui.Image> processFXNR(ui.Image srcImage, PreviewRenderParams params) async {
  // FXN-R uses the generic CameraShaders.metal, but with specific defaultLook values.
  // These passes were SIMPLIFIED in the shader and need to be applied here.

  // Pass 2.5: Highlight Rolloff (0.16)
  srcImage = /* HighlightRolloff LUT (val: 0.16) */

  // Pass 6: Sensor Non-uniformity + Skin Protection
  // centerGain: 0.01, edgeFalloff: 0.035, cornerWarmShift: -0.015
  srcImage = await drawSensorNonUniformity(srcImage, 0.01, 0.035, cornerWarmShift: -0.015);

  // skinHueProtect: 1.0, skinSatProtect: 0.96, skinLumaSoften: 0.03, skinRedLimit: 1.04
  srcImage = /* SkinHueProtect (val: 1.0) */

  // developmentSoftness: 0.02
  srcImage = await drawDevelopmentSoftness(srcImage, 0.02);

  // chemicalIrregularity: 0.01
  srcImage = await drawChemicalIrregularity(srcImage, 0.01);

  return srcImage;
}
