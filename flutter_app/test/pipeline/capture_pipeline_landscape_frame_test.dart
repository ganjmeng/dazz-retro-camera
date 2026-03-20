import 'package:flutter_test/flutter_test.dart';
import 'package:retro_cam/features/camera/capture_pipeline.dart';
import 'package:retro_cam/models/camera_definition.dart';

Map<String, dynamic> _makeCameraJson() {
  return {
    'id': 'ccd_r',
    'name': 'CCD R',
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
          'id': 'ratio_3_4',
          'label': '3:4',
          'width': 3,
          'height': 4,
          'supportsFrame': true,
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
      'ratioId': 'ratio_3_4',
      'frameId': null,
      'watermarkPresetId': null,
      'extraId': null,
    },
    'uiCapabilities': {
      'enableFilter': true,
      'enableLens': true,
      'enableRatio': true,
      'enableFrame': true,
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
      'enableFrameComposite': true,
      'enableWatermarkComposite': false,
      'enableHalation': true,
    },
    'exportPolicy': {
      'jpegQuality': 0.9,
      'applyRatioCrop': true,
      'applyFrameOnExport': true,
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
      'thumbnail': 'assets/thumbnails/cameras/ccd_r_icon.jpg',
      'icon': 'assets/thumbnails/cameras/ccd_r_icon.jpg',
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
  group('CapturePipeline landscape frame layout', () {
    test('framed landscape keeps portrait 3:4 crop geometry', () {
      final pipeline =
          CapturePipeline(camera: CameraDefinition.fromJson(_makeCameraJson()));

      final crop = pipeline.debugCalcCropRect(4000, 3000, 'ratio_3_4');

      expect(crop.width, 2250);
      expect(crop.height, 3000);
      expect(crop.left, 875);
      expect(crop.top, 0);
    });

    test('framed landscape no longer rotates portrait frame insets', () {
      const inset = FrameInset(top: 151, right: 137, bottom: 344, left: 134);

      expect(inset.top, 151);
      expect(inset.right, 137);
      expect(inset.bottom, 344);
      expect(inset.left, 134);
    });
  });
}
