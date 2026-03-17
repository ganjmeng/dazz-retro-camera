import 'dart:ui' as ui;
import '../capture_pipeline_ext.dart';
import '../preview_renderer.dart';

Future<ui.Image> processDClassic(ui.Image srcImage, PreviewRenderParams params) async {
  // D-Classic also uses the generic CameraShaders.metal. It has fewer specific
  // passes defined in its defaultLook, so we only apply those.

  // No specific Highlight Rolloff, Sensor Non-uniformity, or Skin Protection
  // passes are defined for D-Classic in its defaultLook.

  return srcImage;
}
