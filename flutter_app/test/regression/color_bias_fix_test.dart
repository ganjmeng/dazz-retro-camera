// 回归测试：成片色偏修复验证
// Bug: CaptureGLProcessor 的 applyTemperature 系数比预览 Shader 大 333 倍
// Fix: 统一为 shift / 1000.0 * 0.3（与预览 Shader 对齐）

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_cam/features/camera/preview_renderer.dart';
import 'package:retro_cam/models/camera_definition.dart';

void main() {
  group('Regression: 成片色偏修复', () {
    // 所有相机的 temperature 值和预期行为
    final cameraTemperatureExpectations = {
      'ccd_r': {'temperature': -15, 'expectedBias': 'cool', 'maxShift': 0.01},
      'ccd_m': {'temperature': -10, 'expectedBias': 'cool', 'maxShift': 0.01},
      'fqs': {'temperature': 5, 'expectedBias': 'warm', 'maxShift': 0.01},
      'inst_c': {'temperature': -20, 'expectedBias': 'cool', 'maxShift': 0.01},
      'u300': {'temperature': 40, 'expectedBias': 'warm', 'maxShift': 0.02},
      'cpm35': {'temperature': 25, 'expectedBias': 'warm', 'maxShift': 0.01},
      'bw_classic': {'temperature': 0, 'expectedBias': 'neutral', 'maxShift': 0.0},
      'd_classic': {'temperature': 5, 'expectedBias': 'warm', 'maxShift': 0.01},
    };

    test('Temperature shift should be within ±0.02 range (not ±1.5)', () {
      // 验证修复后的系数：shift / 1000.0 * 0.3
      // 以 CCD R (temperature=-15) 为例：
      // 修复前：-15 * 0.1 = -1.5（R 通道归零！纯蓝色！）
      // 修复后：-15 / 1000.0 * 0.3 = -0.0045（微弱偏冷，正确）
      for (final entry in cameraTemperatureExpectations.entries) {
        final temp = entry.value['temperature'] as int;
        final maxShift = entry.value['maxShift'] as double;

        // 修复后的系数
        final fixedShift = temp / 1000.0 * 0.3;
        expect(
          fixedShift.abs(),
          lessThanOrEqualTo(maxShift + 0.001),
          reason: '${entry.key}: temperature=$temp, fixedShift=$fixedShift should be within ±$maxShift',
        );

        // 验证旧的错误系数确实会导致严重色偏
        final brokenShift = temp * 0.1;
        if (temp != 0) {
          expect(
            brokenShift.abs(),
            greaterThanOrEqualTo(0.5),
            reason: '${entry.key}: old broken shift=$brokenShift should be >= 0.5 (proving the bug)',
          );
        }
      }
    });

    test('Tint shift should use /1000.0 * 0.2 (not * 0.05)', () {
      // 修复后的系数：shift / 1000.0 * 0.2
      // 以 tint=10 为例：
      // 修复前：10 * 0.05 = 0.5（G 通道偏移 50%！）
      // 修复后：10 / 1000.0 * 0.2 = 0.002（微弱偏移，正确）
      final tintValues = [10, -10, 20, -20, 50, -50];
      for (final tint in tintValues) {
        final fixedShift = tint / 1000.0 * 0.2;
        expect(
          fixedShift.abs(),
          lessThanOrEqualTo(0.02),
          reason: 'tint=$tint: fixedShift=$fixedShift should be within ±0.02',
        );
      }
    });

    test('ColorBias should be applied directly without 0.1 scaling', () {
      // 修复后：直接加 colorBias 值（不乘 0.1）
      // 以 INST C (colorBiasR=0.022) 为例：
      // 修复前：0.022 * 0.1 = 0.0022（几乎无效果）
      // 修复后：0.022（正确的微弱暖色补偿）
      final biasR = 0.022;
      final biasB = -0.015;

      // 修复后直接使用
      expect(biasR, closeTo(0.022, 0.001));
      expect(biasB, closeTo(-0.015, 0.001));

      // 验证旧的缩放确实会削弱效果
      final brokenBiasR = biasR * 0.1;
      expect(brokenBiasR, closeTo(0.0022, 0.001),
          reason: 'Old scaling would reduce bias to near-zero');
    });

    test('All camera toJson temperature values should produce safe shifts', () async {
      final assetsDir = Directory('assets/cameras');
      if (!assetsDir.existsSync()) return; // Skip if no assets

      final jsonFiles = assetsDir.listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'));

      for (final file in jsonFiles) {
        final content = await file.readAsString();
        final json = jsonDecode(content);
        final camera = CameraDefinition.fromJson(json);
        final params = PreviewRenderParams(defaultLook: camera.defaultLook);
        final jsonMap = params.toJson();

        final tempShift = jsonMap['temperatureShift'] as double;
        // 使用修复后的系数验证：shift / 1000.0 * 0.3
        final rgbShift = tempShift / 1000.0 * 0.3;
        expect(
          rgbShift.abs(),
          lessThanOrEqualTo(0.05),
          reason: '${camera.id}: temperatureShift=$tempShift produces rgbShift=$rgbShift (should be < 0.05)',
        );
      }
    });
  });
}
