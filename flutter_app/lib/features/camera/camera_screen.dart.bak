import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../services/camera_service.dart';
import '../../services/preset_repository.dart';
import '../../router/app_router.dart';

/// 相机主屏幕 — 对齐参考截图 UI
class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen> {
  bool _gridEnabled = false;
  bool _smallFrameEnabled = false;
  bool _doubleExposureEnabled = false;
  bool _burstEnabled = false;
  String _sharpness = '中';
  bool _isFlashOn = false;
  bool _isFrontCamera = false;
  int _timerSeconds = 0;
  bool _showTopMenu = false;
  bool _showCameraSelector = false;
  double _exposureValue = 0.0;
  double _zoomLevel = 1.0;
  AssetEntity? _latestAsset;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(cameraServiceProvider.notifier).initCamera();
    });
    _loadLatestAsset();
  }

  Future<void> _loadLatestAsset() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.isAuth) return;
    final paths = await PhotoManager.getAssetPathList(type: RequestType.image);
    if (paths.isEmpty) return;
    final assets = await paths.first.getAssetListPaged(page: 0, size: 1);
    if (assets.isNotEmpty && mounted) {
      setState(() => _latestAsset = assets.first);
    }
  }

  Future<void> _takePhoto() async {
    final path = await ref.read(cameraServiceProvider.notifier).takePhoto();
    if (path != null) await _loadLatestAsset();
  }

  void _toggleFlash() => setState(() => _isFlashOn = !_isFlashOn);

  void _cycleTimer() {
    setState(() {
      if (_timerSeconds == 0) _timerSeconds = 3;
      else if (_timerSeconds == 3) _timerSeconds = 10;
      else _timerSeconds = 0;
    });
  }

  void _switchCamera() {
    setState(() => _isFrontCamera = !_isFrontCamera);
    ref.read(cameraServiceProvider.notifier).switchLens();
  }

  void _cycleSharpness() {
    setState(() {
      if (_sharpness == '低') _sharpness = '中';
      else if (_sharpness == '中') _sharpness = '高';
      else _sharpness = '低';
    });
  }

  @override
  Widget build(BuildContext context) {
    final cameraState = ref.watch(cameraServiceProvider);
    final screenWidth = MediaQuery.of(context).size.width;
    final previewSize = screenWidth - 32;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: GestureDetector(
          onTap: () {
            if (_showTopMenu || _showCameraSelector) {
              setState(() {
                _showTopMenu = false;
                _showCameraSelector = false;
              });
            }
          },
          child: Stack(
            children: [
              Column(
                children: [
                  _buildTopBar(),
                  _buildPreviewArea(cameraState, previewSize),
                  const SizedBox(height: 16),
                  _buildQuickActions(),
                  const Spacer(),
                  _buildBottomBar(),
                  const SizedBox(height: 12),
                ],
              ),
              if (_showTopMenu) _buildTopMenuOverlay(),
              if (_showCameraSelector) _buildCameraSelectorSheet(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          GestureDetector(
            onTap: () => setState(() {
              _showTopMenu = !_showTopMenu;
              _showCameraSelector = false;
            }),
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                '• • •',
                style: TextStyle(color: Colors.white, fontSize: 18, letterSpacing: 3),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewArea(CameraState cameraState, double size) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: size,
          height: size,
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (cameraState.isReady && cameraState.textureId != null)
                Texture(textureId: cameraState.textureId!)
              else
                Container(color: const Color(0xFF111111)),
              if (_gridEnabled) CustomPaint(painter: _GridPainter()),
              if (cameraState.isLoading)
                const Center(child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
              if (cameraState.error != null)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(cameraState.error!, style: const TextStyle(color: Colors.redAccent, fontSize: 11), textAlign: TextAlign.center),
                  ),
                ),
              Positioned(
                bottom: 14,
                left: 0,
                right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _ControlPill(icon: Icons.thermostat_outlined, label: '', onTap: () {}),
                    const SizedBox(width: 8),
                    _ControlPill(
                      label: 'x${_zoomLevel.toStringAsFixed(0)}',
                      onTap: () => setState(() => _zoomLevel = _zoomLevel == 1.0 ? 2.0 : 1.0),
                    ),
                    const SizedBox(width: 8),
                    _ControlPill(
                      icon: Icons.wb_sunny_outlined,
                      label: _exposureValue.toStringAsFixed(1),
                      isHighlighted: true,
                      onTap: _showExposureSlider,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showExposureSlider() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: Colors.grey[900], borderRadius: BorderRadius.circular(16)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('曝光', style: TextStyle(color: Colors.white, fontSize: 14)),
            StatefulBuilder(
              builder: (ctx, setS) => Slider(
                value: _exposureValue,
                min: -3.0,
                max: 3.0,
                divisions: 60,
                activeColor: Colors.white,
                inactiveColor: Colors.grey,
                onChanged: (v) { setS(() {}); setState(() => _exposureValue = v); },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickActions() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _QuickActionButton(icon: Icons.add_photo_alternate_outlined, label: '导入图片', onTap: () {}),
          _QuickActionButton(
            icon: Icons.timer_outlined,
            label: _timerSeconds == 0 ? '倒计时' : '${_timerSeconds}s',
            onTap: _cycleTimer,
          ),
          _QuickActionButton(
            icon: _isFlashOn ? Icons.flash_on : Icons.flash_off,
            label: '闪光灯',
            onTap: _toggleFlash,
          ),
          _QuickActionButton(
            icon: Icons.flip_camera_android_outlined,
            label: _isFrontCamera ? '前置' : '后置',
            onTap: _switchCamera,
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 左下：相册缩略图
          GestureDetector(
            onTap: () => context.push(AppRoutes.gallery),
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: Colors.grey[850],
                border: Border.all(color: Colors.grey[700]!, width: 1),
              ),
              child: _latestAsset != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(9),
                      child: FutureBuilder<Uint8List?>(
                        future: _latestAsset!.thumbnailDataWithSize(const ThumbnailSize(112, 112)),
                        builder: (ctx, snap) {
                          if (snap.hasData && snap.data != null) {
                            return Image.memory(snap.data!, fit: BoxFit.cover);
                          }
                          return Container(color: Colors.grey[800]);
                        },
                      ),
                    )
                  : const Icon(Icons.photo_library_outlined, color: Colors.grey, size: 26),
            ),
          ),

          // 中间：拍照按钮
          GestureDetector(
            onTap: _takePhoto,
            child: Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
                color: Colors.white,
              ),
            ),
          ),

          // 右下：相机选择
          GestureDetector(
            onTap: () => setState(() {
              _showCameraSelector = !_showCameraSelector;
              _showTopMenu = false;
            }),
            child: Consumer(
              builder: (context, ref, _) {
                final current = ref.watch(cameraServiceProvider).currentPreset;
                return Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: Colors.grey[850],
                    border: Border.all(color: Colors.grey[700]!, width: 1),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.camera_alt, color: Colors.white, size: 22),
                      if (current != null)
                        Text(
                          current.name,
                          style: const TextStyle(color: Colors.white70, fontSize: 8),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopMenuOverlay() {
    return Positioned(
      top: 44,
      right: 12,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 256,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.black.withAlpha(210),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _MenuToggle(icon: Icons.grid_on, label: _gridEnabled ? '网格线开启' : '网格线关闭', active: _gridEnabled, onTap: () => setState(() => _gridEnabled = !_gridEnabled)),
                  _MenuToggle(icon: Icons.tune, label: '清晰度', active: true, badge: _sharpness, onTap: _cycleSharpness),
                  _MenuToggle(icon: Icons.crop_square, label: _smallFrameEnabled ? '小框模式开启' : '小框模式关闭', active: _smallFrameEnabled, onTap: () => setState(() => _smallFrameEnabled = !_smallFrameEnabled)),
                  _MenuToggle(icon: Icons.layers_outlined, label: _doubleExposureEnabled ? '双重曝光开启' : '双重曝光关闭', active: _doubleExposureEnabled, onTap: () => setState(() => _doubleExposureEnabled = !_doubleExposureEnabled)),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _MenuToggle(icon: Icons.burst_mode_outlined, label: _burstEnabled ? '连拍开启' : '连拍关闭', active: _burstEnabled, onTap: () => setState(() => _burstEnabled = !_burstEnabled)),
                  const SizedBox(width: 14),
                  _MenuToggle(
                    icon: Icons.settings_outlined,
                    label: '设置',
                    active: false,
                    onTap: () {
                      setState(() => _showTopMenu = false);
                      context.push(AppRoutes.settings);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCameraSelectorSheet() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Material(
        color: Colors.transparent,
        child: Container(
          decoration: const BoxDecoration(
            color: Color(0xFF1C1C1C),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 8),
                width: 36,
                height: 4,
                decoration: BoxDecoration(color: Colors.grey[600], borderRadius: BorderRadius.circular(2)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    const Text('照片', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 16),
                    Text('视频', style: TextStyle(color: Colors.grey[500], fontSize: 16)),
                    const Spacer(),
                    _OutlineButton(label: '样图', icon: Icons.landscape_outlined, onTap: () {}),
                    const SizedBox(width: 8),
                    _OutlineButton(
                      label: '管理',
                      icon: Icons.camera_alt_outlined,
                      onTap: () {
                        setState(() => _showCameraSelector = false);
                        context.push(AppRoutes.settings);
                      },
                    ),
                  ],
                ),
              ),
              Consumer(
                builder: (context, ref, _) {
                  final presetsAsync = ref.watch(presetListProvider);
                  return presetsAsync.when(
                    data: (presets) {
                      final current = ref.watch(cameraServiceProvider).currentPreset;
                      return SizedBox(
                        height: 96,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          itemCount: presets.length,
                          itemBuilder: (context, index) {
                            final preset = presets[index];
                            final isSelected = current?.id == preset.id;
                            return GestureDetector(
                              onTap: () {
                                ref.read(cameraServiceProvider.notifier).setPreset(preset);
                                setState(() => _showCameraSelector = false);
                              },
                              child: Container(
                                width: 70,
                                margin: const EdgeInsets.only(right: 8),
                                child: Column(
                                  children: [
                                    Container(
                                      width: 62,
                                      height: 62,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: isSelected ? Colors.white : Colors.transparent, width: 2),
                                        color: Colors.grey[800],
                                      ),
                                      child: const Icon(Icons.camera_alt, color: Colors.white, size: 26),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      preset.name,
                                      style: TextStyle(color: isSelected ? Colors.white : Colors.grey[400], fontSize: 10),
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      );
                    },
                    loading: () => const SizedBox(height: 96, child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))),
                    error: (_, __) => const SizedBox(height: 96),
                  );
                },
              ),
              _buildFilterRow(),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilterRow() {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          _FilterDot(icon: Icons.access_time, color: Colors.orange, active: true),
          _FilterDot(icon: Icons.crop_square, color: Colors.grey),
          _FilterDot(icon: Icons.circle_outlined, color: Colors.grey),
          _FilterDot(icon: Icons.camera, color: Colors.grey),
          _FilterDot(icon: Icons.lens, color: Colors.grey),
          _FilterDot(icon: Icons.blur_circular, color: Colors.grey),
          _FilterDot(icon: Icons.blur_on, color: Colors.grey),
          _FilterDot(icon: Icons.circle, color: Colors.deepOrange),
          _FilterDot(icon: Icons.brightness_1, color: Colors.purple),
        ],
      ),
    );
  }
}

class _ControlPill extends StatelessWidget {
  final IconData? icon;
  final String label;
  final bool isHighlighted;
  final VoidCallback onTap;
  const _ControlPill({this.icon, required this.label, this.isHighlighted = false, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isHighlighted ? Colors.white.withAlpha(51) : Colors.black.withAlpha(153),
          borderRadius: BorderRadius.circular(20),
          border: isHighlighted ? Border.all(color: Colors.white38) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) Icon(icon, color: Colors.white, size: 13),
            if (icon != null && label.isNotEmpty) const SizedBox(width: 3),
            if (label.isNotEmpty) Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

class _QuickActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _QuickActionButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 26),
          const SizedBox(height: 3),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
        ],
      ),
    );
  }
}

class _MenuToggle extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final String? badge;
  final VoidCallback onTap;
  const _MenuToggle({required this.icon, required this.label, required this.active, this.badge, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? Colors.white24 : Colors.white12,
              border: Border.all(color: active ? Colors.white54 : Colors.white24),
            ),
            child: badge != null
                ? Center(child: Text(badge!, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)))
                : Icon(icon, color: Colors.white, size: 20),
          ),
          const SizedBox(height: 3),
          SizedBox(
            width: 54,
            child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 9), textAlign: TextAlign.center, maxLines: 2),
          ),
        ],
      ),
    );
  }
}

class _OutlineButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _OutlineButton({required this.label, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.grey[600]!),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 13),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _FilterDot extends StatelessWidget {
  final IconData icon;
  final Color color;
  final bool active;
  const _FilterDot({required this.icon, required this.color, this.active = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      margin: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? color.withAlpha(40) : Colors.grey[800],
        border: active ? Border.all(color: color, width: 2) : null,
      ),
      child: Icon(icon, color: Colors.white, size: 18),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white24..strokeWidth = 0.5;
    final w = size.width;
    final h = size.height;
    canvas.drawLine(Offset(w / 3, 0), Offset(w / 3, h), paint);
    canvas.drawLine(Offset(w * 2 / 3, 0), Offset(w * 2 / 3, h), paint);
    canvas.drawLine(Offset(0, h / 3), Offset(w, h / 3), paint);
    canvas.drawLine(Offset(0, h * 2 / 3), Offset(w, h * 2 / 3), paint);
  }

  @override
  bool shouldRepaint(_GridPainter oldDelegate) => false;
}
