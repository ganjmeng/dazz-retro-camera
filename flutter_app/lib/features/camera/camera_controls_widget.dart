import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../services/camera_service.dart';
import '../../router/app_router.dart';

/// 相机控制区：包含快门按钮、翻转摄像头、闪光灯、相册入口
class CameraControlsWidget extends ConsumerStatefulWidget {
  const CameraControlsWidget({super.key});

  @override
  ConsumerState<CameraControlsWidget> createState() => _CameraControlsWidgetState();
}

class _CameraControlsWidgetState extends ConsumerState<CameraControlsWidget> {
  bool _isCapturing = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        // 功能按钮行（导入图片、倒计时、闪光灯、切换摄像头）
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildIconButton(Icons.add_photo_alternate_outlined, '导入图片', () {}),
              _buildIconButton(Icons.timer_outlined, '倒计时', () {}),
              _buildIconButton(Icons.flash_off_outlined, '闪光灯', () {}),
              _buildIconButton(Icons.flip_camera_ios_outlined, '后置', () {
                ref.read(cameraServiceProvider.notifier).switchLens();
              }),
            ],
          ),
        ),
        
        // 快门行（相册缩略图 + 快门按钮 + 当前相机图标）
        Padding(
          padding: const EdgeInsets.only(left: 24, right: 24, bottom: 40),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // 最近一张照片的缩略图
              GestureDetector(
                onTap: () => context.push(AppRoutes.gallery),
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.grey[800],
                  ),
                  child: const Icon(Icons.photo_library_outlined, color: Colors.white),
                ),
              ),
              
              // 快门按钮
              GestureDetector(
                onTap: _isCapturing ? null : _onShutterPressed,
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    color: _isCapturing ? Colors.grey : Colors.white,
                  ),
                ),
              ),
              
              // 当前相机图标
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.grey[800],
                ),
                child: const Icon(Icons.camera_alt_outlined, color: Colors.white),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildIconButton(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 24),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 10)),
        ],
      ),
    );
  }

  Future<void> _onShutterPressed() async {
    setState(() => _isCapturing = true);
    await ref.read(cameraServiceProvider.notifier).takePhoto();
    setState(() => _isCapturing = false);
  }
}
