import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_cam/features/camera/pipelines/pipeline_utils.dart';
import 'package:retro_cam/features/camera/preview_renderer.dart';
import 'package:retro_cam/models/camera_definition.dart';

void main() {
  group('Pipeline Performance Benchmarks', () {
    test('processImageChunk performance (CPU Fallback)', () {
      // Create a 1000x1000 image chunk (1 million pixels)
      final width = 1000;
      final height = 1000;
      final pixels = Uint8List(width * height * 4);
      
      // Fill with some data
      for (int i = 0; i < pixels.length; i += 4) {
        pixels[i] = 200;     // R
        pixels[i+1] = 150;   // G
        pixels[i+2] = 100;   // B
        pixels[i+3] = 255;   // A
      }

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
          skinHueProtect: true, // Enable complex math
          skinSatProtect: 0.95,
          chemicalIrregularity: 0.05, // Enable random math
          paperTexture: 0.05, // Enable random math
        ),
      );
      final params = IsolateParams.from(previewParams);

      final payload = IsolatePayload(
        pixels,
        0,
        height,
        width,
        height,
        params,
      );

      // Measure execution time
      final stopwatch = Stopwatch()..start();
      final result = processImageChunk(payload);
      stopwatch.stop();

      // Print for visibility
      print('Processed 1 million pixels (complex pipeline) in ${stopwatch.elapsedMilliseconds} ms');
      
      // In Dart VM, this should be reasonably fast (e.g. < 500ms for 1MP)
      // We don't assert strictly on time because CI environments vary wildly,
      // but we ensure it completes and returns valid data.
      expect(result.length, equals(pixels.length));
    });

    test('LUT generation performance', () {
      final stopwatch = Stopwatch()..start();
      
      // Generate Sensor Non-uniformity Table (256x256)
      final table = buildSensorNonUniformityTable(256, 256, 0.1, 0.2, 0.05);
      
      stopwatch.stop();
      print('Generated 256x256 LUT in ${stopwatch.elapsedMilliseconds} ms');
      
      expect(table.length, equals(256 * 256 * 3));
      // Should be very fast (< 50ms)
      expect(stopwatch.elapsedMilliseconds, lessThan(1000));
    });
  });
}
