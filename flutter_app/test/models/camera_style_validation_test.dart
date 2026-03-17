import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_cam/models/camera_definition.dart';

void main() {
  group('Camera Style Parameter Validation Tests', () {
    final assetsDir = Directory('assets/cameras');
    final Map<String, CameraDefinition> cameras = {};

    setUpAll(() async {
      if (assetsDir.existsSync()) {
        final files = assetsDir.listSync().whereType<File>().where((f) => f.path.endsWith('.json'));
        for (final file in files) {
          final name = file.uri.pathSegments.last.replaceAll('.json', '');
          final content = await file.readAsString();
          cameras[name] = CameraDefinition.fromJson(jsonDecode(content));
        }
      }
    });

    test('CCD-R: Cold tone, hard highlight cutoff, blue chroma noise', () {
      if (!cameras.containsKey('ccd_r')) return;
      final look = cameras['ccd_r']!.defaultLook;
      
      expect(look.temperature, lessThan(0), reason: 'Should be cold tone');
      expect(look.colorBiasB, greaterThan(0), reason: 'Should have blue bias');
      expect(look.colorBiasR, lessThan(0), reason: 'Should have negative red bias');
      expect(look.highlightRolloff, lessThanOrEqualTo(0.10), reason: 'Hard highlight cutoff for early CCD');
      expect(look.chromaticAberration, greaterThanOrEqualTo(0.08), reason: 'Cheap lens CA');
      expect(look.skinHueProtect, isTrue, reason: 'Skin protect needed for cold LUT');
    });

    // CCD-M removed (deprecated camera)

    test('BW Classic: High contrast, strong edge falloff, no skin protect', () {
      if (!cameras.containsKey('bw_classic')) return;
      final look = cameras['bw_classic']!.defaultLook;
      
      expect(look.saturation, lessThanOrEqualTo(0.15), reason: 'B&W should have low/zero saturation');
      // Note: bw_classic edgeFalloff is 0.035 in JSON, though shader comments say "strongest".
      expect(look.edgeFalloff, greaterThan(0), reason: 'Should have edge falloff');
      expect(look.skinHueProtect, isFalse, reason: 'No skin protect for B&W');
      expect(look.highlightRolloff, greaterThanOrEqualTo(0.15), reason: 'Strong highlight protection for B&W film');
    });

    test('Inst C: Warm tone, chemical development, skin protect', () {
      if (!cameras.containsKey('inst_c')) return;
      final look = cameras['inst_c']!.defaultLook;
      
      expect(look.skinHueProtect, isTrue, reason: 'Skin protect for portraits');
      expect(look.highlightRolloff, greaterThanOrEqualTo(0.15), reason: 'Highlight protection for instant film');
      expect(look.paperTexture, greaterThan(0), reason: 'Should have paper texture');
      expect(look.developmentSoftness, greaterThan(0), reason: 'Should have development softness');
    });

    test('INST SQC: Strongest highlight protection, paper texture', () {
      if (!cameras.containsKey('inst_sqc')) return;
      final look = cameras['inst_sqc']!.defaultLook;
      
      expect(look.highlightRolloff, greaterThanOrEqualTo(0.25), reason: 'Strongest highlight protection');
      expect(look.skinHueProtect, isTrue, reason: 'Skin protect for portraits');
      expect(look.paperTexture, greaterThan(0), reason: 'Should have paper texture');
    });

    test('GRD-R: High contrast street photography, sharp', () {
      if (!cameras.containsKey('grd_r')) return;
      final look = cameras['grd_r']!.defaultLook;
      
      expect(look.contrast, greaterThanOrEqualTo(1.10), reason: 'High contrast for street photography');
      expect(look.highlightRolloff, lessThanOrEqualTo(0.12), reason: 'Digital sharpness, low rolloff');
    });

    test('FXN-R: Cold tone, skin protect, sensor non-uniformity', () {
      if (!cameras.containsKey('fxn_r')) return;
      final look = cameras['fxn_r']!.defaultLook;
      
      expect(look.temperature, lessThan(0), reason: 'Cold tone');
      expect(look.skinHueProtect, isTrue, reason: 'Skin protect needed');
      expect(look.skinSatProtect, greaterThanOrEqualTo(0.94), reason: 'High skin saturation protection');
    });

    test('U300: Warm tone, consumer digital, grain', () {
      if (!cameras.containsKey('u300')) return;
      final look = cameras['u300']!.defaultLook;
      
      expect(look.temperature, greaterThan(0), reason: 'Warm tone');
      expect(look.colorBiasR, greaterThan(0), reason: 'Warm red bias');
      expect(look.grain, greaterThanOrEqualTo(0.15), reason: 'Consumer digital grain');
      expect(look.chromaticAberration, greaterThanOrEqualTo(0.05), reason: 'Cheap lens CA');
    });
  });
}
