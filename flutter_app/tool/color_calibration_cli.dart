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

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln(
      'Usage: dart run tool/color_calibration_cli.dart <reference.csv> <measured.csv>',
    );
    exit(64);
  }
  final reference = _loadCsv(args[0]);
  final measured = _loadCsv(args[1]);
  final report = ColorCalibration.evaluate(
    reference: reference,
    measured: measured,
  );
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report.toJson()));
}
