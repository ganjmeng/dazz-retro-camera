import 'dart:ui' as ui;
import '../capture_pipeline_ext.dart';
import '../preview_renderer.dart';

Future<ui.Image> processFXNR(ui.Image srcImage, PreviewRenderParams params) async {
  // FXN-R uses the generic CameraShaders.metal, but with specific defaultLook values.
  // These passes were SIMPLIFIED in the shader and need to be applied here.

  // Pass 2.5: Highlight Rolloff (0.16)
  srcImage = await drawHighlightRolloff(srcImage, 0.16);

  // Pass 6: Sensor Non-uniformity + Skin Protection
  // centerGain: 0.01, edgeFalloff: 0.035, cornerWarmShift: -0.015
  srcImage = await drawSensorNonUniformity(srcImage, 0.01, 0.035, cornerWarmShift: -0.015);

  // skinHueProtect: 1.0, skinSatProtect: 0.96, skinLumaSoften: 0.03, skinRedLimit: 1.04
  srcImage = await drawSkinHueProtect(srcImage, 1.0, satProtect: 0.96, lumaSoften: 0.03, redLimit: 1.04);

  // developmentSoftness: 0.02
  srcImage = await drawDevelopmentSoftness(srcImage, 0.02);

  // chemicalIrregularity: 0.01
  srcImage = await drawChemicalIrregularity(srcImage, 0.01);

  return srcImage;
}
