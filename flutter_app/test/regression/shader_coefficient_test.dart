// 回归测试：Shader 系数跨平台一致性验证
// 确保 Android GLSL 和 iOS Metal Shader 中的色温/色调/色偏系数完全一致

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Regression: Shader 系数跨平台一致性', () {
    test('Android CaptureGLProcessor 应使用修复后的 temperature 系数', () {
      final file = File(
          'android/app/src/main/kotlin/com/retrocam/app/camera/CaptureGLProcessor.kt');
      if (!file.existsSync()) return;

      final content = file.readAsStringSync();

      // 修复后的系数：shift / 1000.0，然后 * 0.3
      expect(
        content.contains('shift / 1000.0'),
        isTrue,
        reason: 'CaptureGLProcessor applyTemperature 应使用 shift / 1000.0',
      );
      expect(
        content.contains('s * 0.3'),
        isTrue,
        reason: 'CaptureGLProcessor applyTemperature 应使用 s * 0.3 系数',
      );

      // 不应包含旧的错误系数：shift * 0.1
      // 注意：需要精确匹配 applyTemperature 函数中的系数
      // 使用正则匹配确保不是其他地方的 * 0.1
      // 确认 applyTemperature 函数内不再使用 shift * 0.1
      // 注意：cornerWarmShift 中的 * 0.1 是正确的，不应被匹配
      final tempFuncMatch = RegExp(
        r'vec3 applyTemperature\(vec3 c, float shift\).*?return c;',
        dotAll: true,
      ).firstMatch(content);
      if (tempFuncMatch != null) {
        expect(
          tempFuncMatch.group(0)!.contains('shift * 0.1'),
          isFalse,
          reason: 'applyTemperature 函数内不应包含旧的 shift * 0.1 系数',
        );
      }
    });

    test('Android CaptureGLProcessor 应使用修复后的 tint 系数', () {
      final file = File(
          'android/app/src/main/kotlin/com/retrocam/app/camera/CaptureGLProcessor.kt');
      if (!file.existsSync()) return;

      final content = file.readAsStringSync();

      // 修复后的系数：shift / 1000.0，然后 * 0.2
      expect(
        content.contains('shift / 1000.0'),
        isTrue,
        reason: 'CaptureGLProcessor applyTint 应使用 shift / 1000.0',
      );
      expect(
        content.contains('s * 0.2'),
        isTrue,
        reason: 'CaptureGLProcessor applyTint 应使用 s * 0.2 系数',
      );
    });

    test('Android CameraGLRenderer 通用 Shader 应包含所有渲染 pass', () {
      final file = File(
          'android/app/src/main/kotlin/com/retrocam/app/camera/CameraGLRenderer.kt');
      if (!file.existsSync()) return;

      final content = file.readAsStringSync();

      // 必须包含的 uniform 声明
      final requiredUniforms = [
        'uTemperatureShift',
        'uTintShift',
        'uContrast',
        'uSaturation',
        'uHighlights',
        'uShadows',
        'uWhites',
        'uBlacks',
        'uClarity',
        'uVibrance',
        'uColorBiasR',
        'uColorBiasG',
        'uColorBiasB',
        'uGrainAmount',
        'uVignetteAmount',
        'uChromaticAberration',
        'uBloomAmount',
        'uHalationAmount',
      ];

      for (final uniform in requiredUniforms) {
        expect(
          content.contains('uniform float $uniform'),
          isTrue,
          reason: 'CameraGLRenderer 通用 Shader 应声明 $uniform',
        );
      }
    });

    test('Android CameraGLRenderer 不应有相机专用 Shader 分支', () {
      final file = File(
          'android/app/src/main/kotlin/com/retrocam/app/camera/CameraGLRenderer.kt');
      if (!file.existsSync()) return;

      final content = file.readAsStringSync();

      // 不应包含相机专用 Shader 引用
      final removedShaders = [
        'BWClassicGLRenderer',
        'CCDRGLRenderer',
        'CPM35GLRenderer',
        'FQSShaderSource',
        'GRDRGLRenderer',
        'InstCShaderSource',
        'SQCGLRenderer',
        'U300GLRenderer',
      ];

      for (final shader in removedShaders) {
        expect(
          content.contains(shader),
          isFalse,
          reason: 'CameraGLRenderer 不应引用已删除的 $shader',
        );
      }
    });

    test('iOS CapturePipeline.metal 的 temperature 方向应与预览一致', () {
      final file = File('ios/Runner/Camera/CapturePipeline.metal');
      if (!file.existsSync()) return;

      final content = file.readAsStringSync();

      // 修复后：正值偏暖（+R -B），与预览 Shader 一致
      // cp_temperatureShift 函数中：
      // color.r = clamp(color.r + s * 0.3, 0.0, 1.0)
      // color.b = clamp(color.b - s * 0.3, 0.0, 1.0)
      expect(
        content.contains('color.r + s * 0.3') ||
            content.contains('color.r = clamp(color.r + s * 0.3'),
        isTrue,
        reason: 'iOS cp_temperatureShift 应为正值偏暖（+R）',
      );
    });

    test('iOS MetalRenderer 不应有相机专用 Shader 分支', () {
      final file = File('ios/Runner/Camera/MetalRenderer.swift');
      if (!file.existsSync()) return;

      final content = file.readAsStringSync();

      // 不应包含相机专用 Shader 引用
      // 检查是否还有相机专用 Shader 的 when/switch 分支
      // 注意：注释中可能还有残留，但不影响功能
      final removedShaders = [
        'BWClassicShader',
        'CCDRShader',
        'FQSShader',
        'GRDRShader',
        'InstCShader',
        'SQCShader',
        'U300Shader',
      ];

      for (final shader in removedShaders) {
        expect(
          content.contains(shader),
          isFalse,
          reason: 'MetalRenderer 不应引用已删除的 $shader',
        );
      }
    });

    test('iOS CameraShaders.metal 应包含完整的渲染管线', () {
      final file = File('ios/Runner/Camera/CameraShaders.metal');
      if (!file.existsSync()) return;

      final content = file.readAsStringSync();

      // 必须包含的渲染 pass
      final requiredPasses = [
        'applyTemperatureShift',
        'applyTintShift',
        'applyColorBias',
        'applyHighlightsShadows',
        'applyClarity',
        'applyVibrance',
      ];

      for (final pass in requiredPasses) {
        expect(
          content.contains(pass),
          isTrue,
          reason: 'CameraShaders.metal 应包含 $pass 渲染 pass',
        );
      }
    });
  });
}
