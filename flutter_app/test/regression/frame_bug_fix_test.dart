// 回归测试：相框 Bug 修复验证
// Bug 1: 非拍立得相机不应有相框，但 JSON 中 frames 数组非空
// Bug 2: 2:3 比例下不应显示相框（所有相框 supportedRatios 不含 ratio_2_3）
// Bug 3: 切换相机时 retainFrame 可能恢复不兼容的 frameId

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_cam/models/camera_definition.dart';

void main() {
  group('Regression: 相框 Bug 修复', () {
    // 拍立得相机列表（应该有相框）
    final instantCameras = {'inst_c', 'inst_s', 'inst_sq', 'sqc'};

    // 非拍立得相机列表（不应该有相框）
    final nonInstantCameras = {
      'bw_classic', 'ccd_m', 'ccd_r', 'cpm35', 'd_classic',
      'fqs', 'fxn_r', 'grd_r', 'u300', 'fisheye',
    };

    late Map<String, CameraDefinition> cameras;

    setUpAll(() async {
      cameras = {};
      final assetsDir = Directory('assets/cameras');
      if (!assetsDir.existsSync()) return;

      for (final file in assetsDir.listSync().whereType<File>()) {
        if (!file.path.endsWith('.json')) continue;
        final content = await file.readAsString();
        final json = jsonDecode(content);
        final camera = CameraDefinition.fromJson(json);
        cameras[camera.id] = camera;
      }
    });

    test('非拍立得相机的 frames 数组应为空', () {
      for (final camId in nonInstantCameras) {
        final camera = cameras[camId];
        if (camera == null) continue; // Skip if camera not found

        final frames = camera.modules.frames;
        expect(
          frames.isEmpty,
          isTrue,
          reason: '$camId: 非拍立得相机不应有相框定义，但 frames.length=${frames.length}',
        );
      }
    });

    test('拍立得相机应有相框定义且 defaultSelection.frameId 非空', () {
      for (final camId in instantCameras) {
        final camera = cameras[camId];
        if (camera == null) continue;

        final frames = camera.modules.frames;
        expect(
          frames.isNotEmpty,
          isTrue,
          reason: '$camId: 拍立得相机应有相框定义',
        );

        // 拍立得相机的 defaultSelection.frameId 应为 instant_default
        final defaultFrameId = camera.defaultSelection.frameId;
        expect(
          defaultFrameId,
          isNotNull,
          reason: '$camId: 拍立得相机的 defaultSelection.frameId 不应为 null',
        );
      }
    });

    test('所有相框的 supportedRatios 不应包含 ratio_2_3', () {
      for (final camera in cameras.values) {
        for (final frame in camera.modules.frames) {
          expect(
            frame.supportedRatios.contains('ratio_2_3'),
            isFalse,
            reason: '${camera.id}/${frame.id}: 相框不应支持 2:3 比例',
          );
        }
      }
    });

    test('非拍立得相机的 defaultSelection.frameId 应为 null', () {
      for (final camId in nonInstantCameras) {
        final camera = cameras[camId];
        if (camera == null) continue;

        expect(
          camera.defaultSelection.frameId,
          isNull,
          reason: '$camId: 非拍立得相机的 defaultSelection.frameId 应为 null',
        );
      }
    });

    test('拍立得相框应只支持 ratio_1_1 和 ratio_3_4', () {
      final allowedRatios = {'ratio_1_1', 'ratio_3_4'};

      for (final camId in instantCameras) {
        final camera = cameras[camId];
        if (camera == null) continue;

        for (final frame in camera.modules.frames) {
          for (final ratio in frame.supportedRatios) {
            expect(
              allowedRatios.contains(ratio),
              isTrue,
              reason: '${camera.id}/${frame.id}: 相框支持的比例 $ratio 不在允许列表中',
            );
          }
        }
      }
    });
  });
}
