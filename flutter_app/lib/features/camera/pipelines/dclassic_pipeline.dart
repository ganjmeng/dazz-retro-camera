import 'dart:ui' as ui;
import '../capture_pipeline_ext.dart';
import '../preview_renderer.dart';

Future<ui.Image> processDClassic(ui.Image srcImage, PreviewRenderParams params) async {
  // D-Classic is a digital camera simulation inspired by early 2000s point-and-shoots.
  // It uses the generic CameraShaders.metal, but its look is defined by its
  // defaultLook parameters. We apply the relevant effects here to match the
  // intended style.

  // 1. Highlight Rolloff (subtle, to mimic digital sensor clipping)
  // D-Classic doesn't have a strong film-like rolloff, but a slight softening
  // of highlights is appropriate for a digital look.
  srcImage = await drawHighlightRolloff(srcImage, 0.08);

  // 2. Sensor Non-uniformity (very low, for a clean digital look)
  // Unlike film cameras, digital sensors are more uniform. We add a very
  // subtle center gain to mimic the lens's natural light falloff.
  srcImage = await drawSensorNonUniformity(srcImage, 0.015, 0.025);

  // 3. Skin Protection (important for digital portraits)
  // Digital sensors can sometimes make skin tones look unnatural. This pass
  // ensures skin tones are preserved, which is crucial for a camera tagged
  // with "family" and "everyday".
  srcImage = await drawSkinHueProtect(srcImage, 1.0, satProtect: 0.98, lumaSoften: 0.01, redLimit: 1.02);

  return srcImage;
}
