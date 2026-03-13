import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/camera_service.dart';

/// 封装 Flutter Texture Widget，承载原生相机的实时渲染输出
class CameraPreviewWidget extends ConsumerWidget {
  const CameraPreviewWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cameraState = ref.watch(cameraServiceProvider);

    if (!cameraState.isReady || cameraState.textureId == null) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 默认 4:3 画幅，居中显示
        final previewWidth = constraints.maxWidth;
        final previewHeight = previewWidth * (4 / 3);

        return Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: previewWidth,
              height: previewHeight,
              // Texture Widget 直接渲染原生层输出的纹理
              child: Texture(textureId: cameraState.textureId!),
            ),
          ),
        );
      },
    );
  }
}
