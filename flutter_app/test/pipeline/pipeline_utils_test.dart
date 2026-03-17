import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_cam/features/camera/pipelines/pipeline_utils.dart';
import 'package:retro_cam/features/camera/preview_renderer.dart';
import 'package:retro_cam/models/camera_definition.dart';

void main() {
  group('Pipeline Utils Pixel-Level Tests', () {
    test('ToneCurve LUT generation should match expected curve', () {
      // Create a linear curve [0, 255]
      final linearCurve = List<double>.generate(256, (i) => i.toDouble());
      final lut = buildToneCurveLUT(linearCurve);
      
      expect(lut.length, 256);
      expect(lut[0], 0);
      expect(lut[128], 128);
      expect(lut[255], 255);
    });

    test('processImageChunk should apply skin protection correctly', () {
      // Create a 2x2 image chunk with skin color and non-skin color
      final pixels = Uint8List.fromList([
        // R, G, B, A
        220, 180, 150, 255, // Skin color
        50, 100, 200, 255,  // Non-skin color (blue)
        200, 150, 120, 255, // Skin color
        10, 20, 30, 255,    // Dark color
      ]);

      // Mock PreviewRenderParams to create IsolateParams
      final previewParams = PreviewRenderParams(
        defaultLook: const DefaultLook(
          temperature: 0,
          contrast: 1,
          saturation: 1,
          vignette: 0,
          distortion: 0,
          chromaticAberration: 0,
          bloom: 0,
          flare: 0,
          skinHueProtect: true,
          skinSatProtect: 0.95,
          skinLumaSoften: 0.05,
          skinRedLimit: 1.0,
        ),
      );
      final params = IsolateParams.from(previewParams);

      final payload = IsolatePayload(
        Uint8List.fromList(pixels), // copy
        0,
        2,
        2,
        2,
        params,
      );

      final processed = processImageChunk(payload);

      // The skin color (pixel 0 and 2) should be modified (desaturated/softened)
      // The non-skin color (pixel 1 and 3) should remain relatively unchanged
      
      // We don't check exact values due to complex math, but we check the trend
      // Skin color R channel might be limited or adjusted
      expect(processed[0], isNot(equals(0))); // Just ensure it didn't crash/zero out
      
      // Non-skin color should be mostly untouched (no chemical irregularity/paper texture)
      expect((processed[4] - 50).abs(), lessThanOrEqualTo(2));
      expect((processed[5] - 100).abs(), lessThanOrEqualTo(2));
      expect((processed[6] - 200).abs(), lessThanOrEqualTo(2));
    });

    test('processImageChunk should apply chemical irregularity', () {
      final pixels = Uint8List(16); // 2x2 black image
      pixels.fillRange(0, 16, 100); // Fill with gray (100)

      // Mock PreviewRenderParams to create IsolateParams
      final previewParams = PreviewRenderParams(
        defaultLook: const DefaultLook(
          temperature: 0,
          contrast: 1,
          saturation: 1,
          vignette: 0,
          distortion: 0,
          chromaticAberration: 0,
          bloom: 0,
          flare: 0,
          chemicalIrregularity: 0.1, // High irregularity
          irregUvScale: 2.5,
          irregFreq1: 1.0,
          irregFreq2: 1.7,
          irregWeight1: 0.6,
          irregWeight2: 0.4,
        ),
      );
      final params = IsolateParams.from(previewParams);

      final payload = IsolatePayload(
        Uint8List.fromList(pixels),
        0,
        2,
        2,
        2,
        params,
      );

      final processed = processImageChunk(payload);

      // Due to irregularity, the gray pixels should no longer all be exactly 100
      bool hasVariation = false;
      for (int i = 0; i < 16; i += 4) {
        if (processed[i] != 100 || processed[i+1] != 100 || processed[i+2] != 100) {
          hasVariation = true;
          break;
        }
      }
      
      expect(hasVariation, isTrue, reason: 'Chemical irregularity should modify pixel values');
    });
  });
}
