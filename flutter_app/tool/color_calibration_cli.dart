import 'dart:convert';
import 'dart:io';
import 'package:retro_cam/features/camera/color_calibration.dart';

List<RgbSample> _loadCsv(String path) {
  final lines = File(path).readAsLinesSync();
  final out = <RgbSample>[];
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final c = line.split(',');
    if (c.length < 4 || c[0] == 'id') continue;
    final id = c[0].trim();
    final r = double.tryParse(c[1].trim());
    final g = double.tryParse(c[2].trim());
    final b = double.tryParse(c[3].trim());
    if (r == null || g == null || b == null) continue;
    out.add(RgbSample(id: id, r: r, g: g, b: b));
  }
  return out;
}

class _CliOptions {
  final String? preset;
  final String? brand;
  final String? model;
  final String? runtimeCameraId;
  final String? scene;
  final double? sensorMp;
  final bool emitProfileTemplate;
  final List<String> positional;

  const _CliOptions({
    required this.positional,
    this.preset,
    this.brand,
    this.model,
    this.runtimeCameraId,
    this.scene,
    this.sensorMp,
    this.emitProfileTemplate = false,
  });
}

_CliOptions _parseArgs(List<String> args) {
  final positional = <String>[];
  String? preset;
  String? brand;
  String? model;
  String? runtimeCameraId;
  String? scene;
  double? sensorMp;
  var emitProfileTemplate = false;

  for (var i = 0; i < args.length; i += 1) {
    final arg = args[i];
    String nextValue() {
      if (i + 1 >= args.length) {
        stderr.writeln('Missing value for $arg');
        exit(64);
      }
      i += 1;
      return args[i];
    }

    switch (arg) {
      case '--preset':
        preset = nextValue();
        break;
      case '--brand':
        brand = nextValue();
        break;
      case '--model':
        model = nextValue();
        break;
      case '--runtime-camera-id':
        runtimeCameraId = nextValue();
        break;
      case '--scene':
        scene = nextValue();
        break;
      case '--sensor-mp':
        sensorMp = double.tryParse(nextValue());
        break;
      case '--emit-profile-template':
        emitProfileTemplate = true;
        break;
      default:
        positional.add(arg);
        break;
    }
  }

  return _CliOptions(
    positional: positional,
    preset: preset,
    brand: brand,
    model: model,
    runtimeCameraId: runtimeCameraId,
    scene: scene,
    sensorMp: sensorMp,
    emitProfileTemplate: emitProfileTemplate,
  );
}

String _sceneFieldName(String? scene) {
  switch ((scene ?? '').trim().toLowerCase()) {
    case 'daylight':
      return 'daylight';
    case 'indoor':
    case 'indoorwarm':
    case 'indoor_warm':
    case 'warm':
      return 'indoor';
    case 'backlit':
      return 'backlit';
    default:
      return 'daylight';
  }
}

String _profileConstName(String preset) {
  final parts = preset
      .split(RegExp(r'[^a-zA-Z0-9]+'))
      .where((e) => e.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '_kExactProfileTemplate';
  final title = parts
      .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
      .join();
  return '_kExact${title}Profile';
}

String _emitSceneDeltaTemplate({
  required String preset,
  required String scene,
  required ColorCalibrationReport report,
}) {
  return '''
// $preset / $scene
// benchmark: deltaEAvg=${report.deltaEAvg.toStringAsFixed(2)}, skinDeltaEAvg=${report.skinDeltaEAvg.toStringAsFixed(2)}, deltaEMax=${report.deltaEMax.toStringAsFixed(2)}, wbBiasAvg=${report.wbBiasAvg.toStringAsFixed(4)}
const SceneCalibrationDelta(
  temperatureOffset: 0.0,
  tintOffset: 0.0,
  contrastScale: 1.0,
  saturationScale: 1.0,
  colorBiasROffset: 0.0,
  colorBiasGOffset: 0.0,
  colorBiasBOffset: 0.0,
)''';
}

String _emitProfileTemplate({
  required String preset,
  required String brand,
  required String model,
  required String runtimeCameraId,
  required double sensorMp,
}) {
  final constName = _profileConstName(preset);
  return '''
const ExactDeviceCalibrationProfile $constName = ExactDeviceCalibrationProfile(
  brand: '${brand.trim().toLowerCase()}',
  model: '${model.trim().toLowerCase()}',
  cameraId: '$preset',
  runtimeCameraId: '$runtimeCameraId',
  sensorMp: ${sensorMp.toStringAsFixed(1)},
  temperatureOffset: 0.0,
  tintOffset: 0.0,
  contrastScale: 1.0,
  saturationScale: 1.0,
  colorBiasROffset: 0.0,
  colorBiasGOffset: 0.0,
  colorBiasBOffset: 0.0,
  ccm: const [1, 0, 0, 0, 1, 0, 0, 0, 1],
  whiteScaleR: 1.0,
  whiteScaleG: 1.0,
  whiteScaleB: 1.0,
  gamma: 2.2,
  daylight: const SceneCalibrationDelta(),
  indoor: const SceneCalibrationDelta(),
  backlit: const SceneCalibrationDelta(),
);''';
}

void main(List<String> args) {
  final options = _parseArgs(args);
  if (options.positional.length < 2) {
    stderr.writeln(
      'Usage: dart run tool/color_calibration_cli.dart <reference.csv> <measured.csv> [--preset fxn_r] [--scene daylight] [--brand xiaomi] [--model 14 ultra] [--runtime-camera-id 0] [--sensor-mp 50] [--emit-profile-template]',
    );
    exit(64);
  }
  final reference = _loadCsv(options.positional[0]);
  final measured = _loadCsv(options.positional[1]);
  final report = ColorCalibration.evaluate(
    reference: reference,
    measured: measured,
  );
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report.toJson()));
  stdout.writeln('');
  final preset = options.preset;
  final scene = _sceneFieldName(options.scene);
  if (preset != null) {
    stdout.writeln('# Scene delta template');
    stdout.writeln(
      _emitSceneDeltaTemplate(
        preset: preset,
        scene: scene,
        report: report,
      ),
    );
    stdout.writeln('');
  }
  if (options.emitProfileTemplate &&
      preset != null &&
      options.brand != null &&
      options.model != null &&
      options.runtimeCameraId != null &&
      options.sensorMp != null) {
    stdout.writeln('# Exact profile template');
    stdout.writeln(
      _emitProfileTemplate(
        preset: preset,
        brand: options.brand!,
        model: options.model!,
        runtimeCameraId: options.runtimeCameraId!,
        sensorMp: options.sensorMp!,
      ),
    );
    stdout.writeln('');
  }
  stdout.writeln('# Next step');
  stdout.writeln(
    '# 1. Run the same device through daylight / indoor warm / backlit.',
  );
  stdout.writeln(
    '# 2. Paste the scene deltas into lib/features/camera/device_calibration_profiles.dart.',
  );
  stdout.writeln(
    '# 3. Replace __fill_*__ placeholders with the real device signature before shipping.',
  );
}
