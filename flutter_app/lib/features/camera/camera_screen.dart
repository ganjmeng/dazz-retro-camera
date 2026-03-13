import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'camera_preview_widget.dart';
import 'preset_selector_widget.dart';
import 'camera_controls_widget.dart';
import '../../services/camera_service.dart';

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen> {
  @override
  void initState() {
    super.initState();
    // 延迟一帧初始化相机，确保 UI 已经挂载
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(cameraServiceProvider.notifier).initCamera();
    });
  }

  @override
  Widget build(BuildContext context) {
    final cameraState = ref.watch(cameraServiceProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // 1. 底层：相机实时预览 (Texture Widget)
            const Positioned.fill(
              child: CameraPreviewWidget(),
            ),
            
            // 2. 中层：相机控件（闪光灯、翻转镜头、快门等）
            const Positioned.fill(
              child: CameraControlsWidget(),
            ),
            
            // 3. 顶层：Preset 选择器（底部滑动列表）
            Positioned(
              bottom: 120, // 位于快门按钮上方
              left: 0,
              right: 0,
              height: 100,
              child: const PresetSelectorWidget(),
            ),
            
            // 状态遮罩 (加载中、错误提示等)
            if (cameraState.isLoading)
              const Center(child: CircularProgressIndicator()),
            if (cameraState.error != null)
              Center(
                child: Text(
                  cameraState.error!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
