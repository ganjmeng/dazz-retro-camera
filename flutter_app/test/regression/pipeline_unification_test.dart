// 回归测试：管线统一验证
// Phase 1: 确认所有相机专用 Pipeline/Renderer 文件已删除
// Phase 2: 确认 Flutter 层不再有像素级渲染逻辑

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_cam/features/camera/preview_renderer.dart';
import 'package:retro_cam/models/camera_definition.dart';

void main() {
  group('Regression: Phase 1 管线统一', () {
    test('相机专用 Dart Pipeline 文件应已删除', () {
      final deletedFiles = [
        'lib/features/camera/pipelines/bwclassic_pipeline.dart',
        'lib/features/camera/pipelines/ccdr_pipeline.dart',
        'lib/features/camera/pipelines/cpm35_pipeline.dart',
        'lib/features/camera/pipelines/dclassic_pipeline.dart',
        'lib/features/camera/pipelines/fqs_pipeline.dart',
        'lib/features/camera/pipelines/fxnr_pipeline.dart',
        'lib/features/camera/pipelines/grdr_pipeline.dart',
        'lib/features/camera/pipelines/instc_pipeline.dart',
        'lib/features/camera/pipelines/sqc_pipeline.dart',
        'lib/features/camera/pipelines/u300_pipeline.dart',
      ];

      for (final path in deletedFiles) {
        expect(
          File(path).existsSync(),
          isFalse,
          reason: '$path 应已删除（Phase 1 管线统一）',
        );
      }
    });

    test('通用 pipeline_utils.dart 应保留', () {
      expect(
        File('lib/features/camera/pipelines/pipeline_utils.dart').existsSync(),
        isTrue,
        reason: 'pipeline_utils.dart 应保留（通用 Isolate 处理函数）',
      );
    });

    test('Android 相机专用 Kotlin Renderer 文件应已删除', () {
      final deletedFiles = [
        'android/app/src/main/kotlin/com/retrocam/app/camera/BWClassicGLRenderer.kt',
        'android/app/src/main/kotlin/com/retrocam/app/camera/CCDRGLRenderer.kt',
        'android/app/src/main/kotlin/com/retrocam/app/camera/CPM35GLRenderer.kt',
        'android/app/src/main/kotlin/com/retrocam/app/camera/FQSGLRenderer.kt',
        'android/app/src/main/kotlin/com/retrocam/app/camera/GRDRGLRenderer.kt',
        'android/app/src/main/kotlin/com/retrocam/app/camera/InstCGLRenderer.kt',
        'android/app/src/main/kotlin/com/retrocam/app/camera/SQCGLRenderer.kt',
        'android/app/src/main/kotlin/com/retrocam/app/camera/U300GLRenderer.kt',
      ];

      for (final path in deletedFiles) {
        expect(
          File(path).existsSync(),
          isFalse,
          reason: '$path 应已删除（Phase 1 管线统一）',
        );
      }
    });

    test('iOS 相机专用 Metal Shader 文件应已删除', () {
      final deletedFiles = [
        'ios/Runner/Camera/BWClassicShader.metal',
        'ios/Runner/Camera/CCDRShader.metal',
        'ios/Runner/Camera/CPM35Shader.metal',
        'ios/Runner/Camera/FQSShader.metal',
        'ios/Runner/Camera/GRDRShader.metal',
        'ios/Runner/Camera/InstCShader.metal',
        'ios/Runner/Camera/SQCShader.metal',
        'ios/Runner/Camera/U300Shader.metal',
      ];

      for (final path in deletedFiles) {
        expect(
          File(path).existsSync(),
          isFalse,
          reason: '$path 应已删除（Phase 1 管线统一）',
        );
      }
    });

    test('通用 Native Shader 文件应保留', () {
      final retainedFiles = [
        'android/app/src/main/kotlin/com/retrocam/app/camera/CameraGLRenderer.kt',
        'android/app/src/main/kotlin/com/retrocam/app/camera/CaptureGLProcessor.kt',
        'android/app/src/main/kotlin/com/retrocam/app/camera/CameraPlugin.kt',
        'ios/Runner/Camera/CameraShaders.metal',
        'ios/Runner/Camera/CapturePipeline.metal',
        'ios/Runner/Camera/MetalRenderer.swift',
      ];

      for (final path in retainedFiles) {
        expect(
          File(path).existsSync(),
          isTrue,
          reason: '$path 应保留（通用 Native Shader）',
        );
      }
    });
  });

  group('Regression: Phase 2 渲染逻辑下沉', () {
    test('PreviewRenderParams.toJson 应包含所有 Native Shader 需要的参数', () {
      final params = PreviewRenderParams(
        defaultLook: const DefaultLook(
          temperature: -15,
          contrast: 1.2,
          saturation: 1.1,
          vignette: 0.3,
          distortion: -0.02,
          chromaticAberration: 0.005,
          bloom: 0.15,
          flare: 0.0,
          tint: 5,
          highlights: -10,
          shadows: 15,
          whites: 5,
          blacks: -5,
          clarity: 10,
          vibrance: 20,
          colorBiasR: 0.022,
          colorBiasG: 0.005,
          colorBiasB: -0.015,
          grain: 0.08,
          halation: 0.1,
          highlightRolloff: 0.2,
          paperTexture: 0.05,
          edgeFalloff: 0.035,
          cornerWarmShift: 0.5,
          centerGain: 0.03,
          chemicalIrregularity: 0.02,
        ),
      );

      final json = params.toJson();

      // 核心色彩参数
      expect(json.containsKey('temperatureShift'), isTrue);
      expect(json.containsKey('tintShift'), isTrue);
      expect(json.containsKey('contrast'), isTrue);
      expect(json.containsKey('saturation'), isTrue);
      expect(json.containsKey('highlights'), isTrue);
      expect(json.containsKey('shadows'), isTrue);
      expect(json.containsKey('whites'), isTrue);
      expect(json.containsKey('blacks'), isTrue);
      expect(json.containsKey('clarity'), isTrue);
      expect(json.containsKey('vibrance'), isTrue);

      // RGB 通道偏移
      expect(json.containsKey('colorBiasR'), isTrue);
      expect(json.containsKey('colorBiasG'), isTrue);
      expect(json.containsKey('colorBiasB'), isTrue);

      // 特效参数
      expect(json.containsKey('grainAmount'), isTrue);
      expect(json.containsKey('vignetteAmount'), isTrue);
      expect(json.containsKey('chromaticAberration'), isTrue);
      expect(json.containsKey('bloomAmount'), isTrue);
      expect(json.containsKey('halationAmount'), isTrue);

      // 成片专属参数
      expect(json.containsKey('highlightRolloff'), isTrue);
      expect(json.containsKey('paperTexture'), isTrue);
      expect(json.containsKey('edgeFalloff'), isTrue);
      expect(json.containsKey('cornerWarmShift'), isTrue);
      expect(json.containsKey('centerGain'), isTrue);
      expect(json.containsKey('chemicalIrregularity'), isTrue);

      // 新增参数（之前 toJson 中缺失的）
      expect(json.containsKey('exposureOffset'), isTrue);
      expect(json.containsKey('softFocus'), isTrue);
      expect(json.containsKey('distortion'), isTrue);
      expect(json.containsKey('lensVignette'), isTrue);

      // 肤色保护参数
      expect(json.containsKey('skinHueProtect'), isTrue);
      expect(json.containsKey('skinSatProtect'), isTrue);
      expect(json.containsKey('skinLumaSoften'), isTrue);
      expect(json.containsKey('skinRedLimit'), isTrue);
    });

    test('toJson 中的 temperatureShift 值应与 effectiveTemperature 一致', () {
      final params = PreviewRenderParams(
        defaultLook: const DefaultLook(
          temperature: -15,
          contrast: 1.0,
          saturation: 1.0,
          vignette: 0,
          distortion: 0,
          chromaticAberration: 0,
          bloom: 0,
          flare: 0,
        ),
        temperatureOffset: 5,
      );

      final json = params.toJson();
      // V3 起 temperature 会叠加场景自适应与设备校准偏移，断言与 effectiveTemperature 对齐。
      expect(
        json['temperatureShift'],
        closeTo(params.effectiveTemperature, 0.01),
      );
    });

    test('preview_renderer.dart 不应包含 buildColorMatrix 或 Widget 特效类', () {
      final file = File('lib/features/camera/preview_renderer.dart');
      if (!file.existsSync()) return;

      final content = file.readAsStringSync();

      // 不应包含 Flutter ColorFilter 矩阵逻辑
      expect(content.contains('buildColorMatrix'), isFalse,
          reason: 'buildColorMatrix 应已删除（Phase 2 下沉）');
      expect(content.contains('computeColorMatrix'), isFalse,
          reason: 'computeColorMatrix 应已删除（Phase 2 下沉）');

      // 不应包含 Widget 层特效类
      expect(content.contains('_ChromaticAberrationLayer'), isFalse,
          reason: '_ChromaticAberrationLayer 应已删除（Phase 2 下沉）');
      expect(content.contains('_BloomLayer'), isFalse,
          reason: '_BloomLayer 应已删除（Phase 2 下沉）');
      expect(content.contains('_HalationLayer'), isFalse,
          reason: '_HalationLayer 应已删除（Phase 2 下沉）');
      expect(content.contains('_PaperTextureLayer'), isFalse,
          reason: '_PaperTextureLayer 应已删除（Phase 2 下沉）');
      expect(content.contains('_VignetteLayer'), isFalse,
          reason: '_VignetteLayer 应已删除（Phase 2 下沉）');

      // 不应包含 ColorFilter.matrix
      expect(content.contains('ColorFilter.matrix'), isFalse,
          reason: 'ColorFilter.matrix 应已删除（Phase 2 下沉）');
    });
  });
}
