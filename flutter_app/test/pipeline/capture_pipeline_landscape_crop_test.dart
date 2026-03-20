import 'package:flutter_test/flutter_test.dart';
import 'package:retro_cam/features/camera/capture_pipeline.dart';
import 'package:retro_cam/models/camera_definition.dart';

Map<String, dynamic> _makeCameraJson() {
  return {
    'id': 'cpm35',
    'name': 'CPM35',
    'category': 'film',
    'mode': 'photo',
    'supportsPhoto': true,
    'supportsVideo': false,
    'sensor': {
      'type': 'film_scan',
      'dynamicRange': 10.0,
      'baseNoise': 0.1,
      'colorDepth': 12,
    },
    'defaultLook': {},
    'modules': {
      'filters': [],
      'lenses': [],
      'ratios': [
        {
          'id': 'ratio_2_3',
          'label': '2:3',
          'width': 2,
          'height': 3,
          'supportsFrame': false,
        },
      ],
      'frames': [],
      'watermarks': {
        'presets': [],
        'editor': {},
      },
      'extras': [],
    },
    'defaultSelection': {
      'filterId': null,
      'lensId': null,
      'ratioId': 'ratio_2_3',
      'frameId': null,
      'watermarkPresetId': null,
      'extraId': null,
    },
    'uiCapabilities': {
      'enableFilter': true,
      'enableLens': true,
      'enableRatio': true,
      'enableFrame': false,
      'enableWatermark': false,
      'enableExtra': false,
    },
    'previewCapabilities': {
      'allowSmallViewport': true,
      'allowGridOverlay': true,
      'allowZoom': true,
      'allowImportImage': false,
      'allowTimer': true,
      'allowFlash': true,
    },
    'previewPolicy': {
      'enableLut': true,
      'enableTemperature': true,
      'enableContrast': true,
      'enableSaturation': true,
      'enableVignette': true,
      'enableLightLensEffect': true,
      'enableGrain': true,
      'enableBloom': true,
      'enableChromaticAberration': true,
      'enableFrameComposite': false,
      'enableWatermarkComposite': false,
      'enableHalation': true,
    },
    'exportPolicy': {
      'jpegQuality': 0.9,
      'applyRatioCrop': true,
      'applyFrameOnExport': false,
      'applyWatermarkOnExport': false,
      'preserveMetadata': true,
    },
    'videoConfig': {
      'enabled': false,
      'fpsOptions': [30],
      'resolutionOptions': ['HD'],
      'defaultFps': 30,
      'defaultResolution': 'HD',
      'supportsAudio': false,
      'videoBitrate': 8000000,
    },
    'assets': {
      'thumbnail': 'assets/thumbnails/cameras/cpm35_icon.jpg',
      'icon': 'assets/thumbnails/cameras/cpm35_icon.jpg',
    },
    'meta': {
      'version': '1.0',
      'premium': false,
      'sortOrder': 1,
      'tags': ['film'],
    },
  };
}

void main() {
  group('CapturePipeline landscape crop parity', () {
    test('2:3 ratio keeps portrait crop geometry on landscape source', () {
      final pipeline =
          CapturePipeline(camera: CameraDefinition.fromJson(_makeCameraJson()));

      final crop = pipeline.debugCalcCropRect(4000, 3000, 'ratio_2_3');

      expect(crop.width, 2000);
      expect(crop.height, 3000);
      expect(crop.left, 1000);
      expect(crop.top, 0);
    });

    test('low quality landscape export stays near 1920 long edge after rotate',
        () {
      final pipeline =
          CapturePipeline(camera: CameraDefinition.fromJson(_makeCameraJson()));

      final crop = pipeline.debugCalcCropRect(4000, 3000, 'ratio_2_3');
      final scale = CapturePipeline.kMaxDimLow / crop.height;
      final rotatedWidth = (crop.height * scale).round();
      final rotatedHeight = (crop.width * scale).round();

      expect(rotatedWidth, 1920);
      expect(rotatedHeight, 1280);
    });

    test(
        'medium quality landscape export stays near 1920 long edge after rotate',
        () {
      final pipeline =
          CapturePipeline(camera: CameraDefinition.fromJson(_makeCameraJson()));

      final crop = pipeline.debugCalcCropRect(4000, 3000, 'ratio_2_3');
      final scale = CapturePipeline.kMaxDimMid / crop.height;
      final rotatedWidth = (crop.height * scale).round();
      final rotatedHeight = (crop.width * scale).round();

      expect(rotatedWidth, 1920);
      expect(rotatedHeight, 1280);
    });

    test('high quality landscape export stays near 4096 long edge after rotate',
        () {
      final pipeline =
          CapturePipeline(camera: CameraDefinition.fromJson(_makeCameraJson()));

      final crop = pipeline.debugCalcCropRect(4000, 3000, 'ratio_2_3');
      final scale = CapturePipeline.kMaxDimHigh / crop.height;
      final rotatedWidth = (crop.height * scale).round();
      final rotatedHeight = (crop.width * scale).round();

      expect(rotatedWidth, 4096);
      expect(rotatedHeight, 2731);
    });
  });
}
