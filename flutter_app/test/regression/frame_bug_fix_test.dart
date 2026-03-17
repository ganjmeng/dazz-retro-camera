// 回归测试：相框 Bug 修复验证
// Bug 1: 非拍立得相机不应有相框，但 JSON 中 frames 数组非空
// Bug 2: 2:3 比例下不应显示相框（所有相框 supportedRatios 不含 ratio_2_3）
// Bug 3: 切换相机时 retainFrame 可能恢复不兼容的 frameId
//
// 2026-03-18 更新：ccd_r / cpm35 / d_classic / fqs / fxn_r / u300
// 已按产品需求添加拍立得相框（默认关闭，仅支持 1:1 和 3:4），
// 移入 extendedFrameCameras 分组，不再视为 bug。

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_cam/models/camera_definition.dart';

void main() {
  group('Regression: 相框 Bug 修复', () {
    // 拍立得相机列表（应该有相框，默认开启）
    final instantCameras = {'inst_c', 'inst_sqc'};

    // 扩展相框相机列表（有相框，但默认关闭，frameId 为 null）
    final extendedFrameCameras = {
      'ccd_r', 'cpm35', 'd_classic', 'fqs', 'fxn_r', 'u300',
    };

    // 无相框相机列表（不应该有相框）
    final noFrameCameras = {
      'bw_classic', 'grd_r', 'fisheye',
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

    test('无相框相机的 frames 数组应为空', () {
      for (final camId in noFrameCameras) {
        final camera = cameras[camId];
        if (camera == null) continue;

        final frames = camera.modules.frames;
        expect(
          frames.isEmpty,
          isTrue,
          reason: '$camId: 该相机不应有相框定义，但 frames.length=${frames.length}',
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

    test('扩展相框相机应有相框定义且 defaultSelection.frameId 为 null（默认关闭）', () {
      for (final camId in extendedFrameCameras) {
        final camera = cameras[camId];
        if (camera == null) continue;

        final frames = camera.modules.frames;
        expect(
          frames.isNotEmpty,
          isTrue,
          reason: '$camId: 扩展相框相机应有相框定义',
        );

        expect(
          camera.defaultSelection.frameId,
          isNull,
          reason: '$camId: 扩展相框相机默认应关闭相框（frameId 为 null）',
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

    test('无相框相机的 defaultSelection.frameId 应为 null', () {
      for (final camId in noFrameCameras) {
        final camera = cameras[camId];
        if (camera == null) continue;

        expect(
          camera.defaultSelection.frameId,
          isNull,
          reason: '$camId: 该相机的 defaultSelection.frameId 应为 null',
        );
      }
    });

    test('所有相框应只支持 ratio_1_1 和 ratio_3_4', () {
      final allowedRatios = {'ratio_1_1', 'ratio_3_4'};
      final allFrameCameras = {...instantCameras, ...extendedFrameCameras};

      for (final camId in allFrameCameras) {
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
