// camera_screen.dart
// GRD R 相机主界面 — 精细复刻参考截图 UI
// 集成 GrdCameraNotifier + PreviewFilterWidget 实时渲染管线
//
// UI 结构：
//   黑色背景
//   ├── 顶部状态区（绿点指示灯 + ··· 菜单）
//   ├── 取景框（圆角矩形，内含实时渲染预览 + 悬浮控件）
//   │     ├── 预览渲染（ColorFilter 色彩矩阵 + 暗角 + 色差）
//   │     ├── 网格叠加
//   │     ├── 右上角 ··· 菜单按钮
//   │     └── 底部悬浮控件条（温度 | 焦距 | 曝光）
//   ├── 模式切换栏（照片 | 视频 | 样图 | 管理）
//   ├── 底部功能面板（滑出式：滤镜/镜头/比例/边框/水印）
//   └── 快门区（图库缩略图 | 快门按钮 | 相机切换）

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../services/camera_service.dart';
import '../../router/app_router.dart';
import 'grd_camera_notifier.dart';
import 'preview_renderer.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CameraScreen
// ─────────────────────────────────────────────────────────────────────────────

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});
  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen>
    with TickerProviderStateMixin {

  // ignore: unused_field
  AssetEntity? _latestAsset;
  Uint8List? _latestThumb;
  int _timerCountdown = 0;
  Timer? _countdownTimer;

  // 曝光拖拽
  bool _showExposureSlider = false;
  double _dragStartY = 0;
  double _dragStartExposure = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(grdCameraProvider.notifier).initialize();
      await ref.read(cameraServiceProvider.notifier).initCamera();
      _loadLatestDazzPhoto();
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadLatestDazzPhoto() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.isAuth) return;
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      filterOption: FilterOptionGroup(
        orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
      ),
    );
    AssetPathEntity? dazzPath;
    for (final p in paths) {
      if (p.name.toUpperCase().contains('DAZZ')) {
        dazzPath = p;
        break;
      }
    }
    final targetPath = dazzPath ?? (paths.isNotEmpty ? paths.first : null);
    if (targetPath == null) return;
    final assets = await targetPath.getAssetListPaged(page: 0, size: 1);
    if (assets.isNotEmpty && mounted) {
      final thumb = await assets.first.thumbnailDataWithSize(
        const ThumbnailSize(120, 120),
      );
      setState(() {
        _latestAsset = assets.first;
        _latestThumb = thumb;
      });
    }
  }

  Future<void> _handleShutter() async {
    final notifier = ref.read(grdCameraProvider.notifier);
    final st = ref.read(grdCameraProvider);
    if (st.isTakingPhoto) return;

    if (st.timerSeconds > 0) {
      setState(() => _timerCountdown = st.timerSeconds);
      _countdownTimer?.cancel();
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        setState(() {
          _timerCountdown--;
          if (_timerCountdown <= 0) {
            t.cancel();
            _timerCountdown = 0;
            _doTakePhoto(notifier);
          }
        });
      });
    } else {
      _doTakePhoto(notifier);
    }
  }

  Future<void> _doTakePhoto(GrdCameraNotifier notifier) async {
    final path = await notifier.takePhoto();
    if (path != null && mounted) {
      _loadLatestDazzPhoto();
    }
  }

  @override
  Widget build(BuildContext context) {
    final grdState = ref.watch(grdCameraProvider);
    final cameraState = ref.watch(cameraServiceProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () {
          ref.read(grdCameraProvider.notifier).closeAllPanels();
          setState(() => _showExposureSlider = false);
        },
        behavior: HitTestBehavior.translucent,
        child: Stack(
          children: [
            SafeArea(
              child: Column(
                children: [
                  _buildTopBar(grdState),
                  Expanded(
                    child: _buildViewfinder(grdState, cameraState),
                  ),
                  _buildModeBar(grdState),
                  if (grdState.activePanel != null)
                    _buildActivePanel(grdState)
                  else
                    const SizedBox(height: 8),
                  _buildShutterRow(grdState),
                  const SizedBox(height: 16),
                ],
              ),
            ),
            // 拍照闪光
            if (grdState.showCaptureFlash)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(color: Colors.white.withAlpha(200)),
                ),
              ),
            // 倒计时数字
            if (_timerCountdown > 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: Text(
                      '$_timerCountdown',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 96,
                        fontWeight: FontWeight.w100,
                      ),
                    ),
                  ),
                ),
              ),
            // 顶部菜单浮层
            if (grdState.showTopMenu)
              _buildTopMenuOverlay(grdState),
          ],
        ),
      ),
    );
  }

  // ── 顶部状态栏 ──────────────────────────────────────────────────────────────

  Widget _buildTopBar(GrdCameraState st) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Row(
        children: [
          // 绿色录制指示灯
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF00E676),
            ),
          ),
          const Spacer(),
          // 相机名称
          if (st.camera != null)
            Text(
              st.camera!.name,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 13,
                letterSpacing: 1.2,
              ),
            ),
          const Spacer(),
          // 焦距标签
          if (st.camera?.focalLengthLabel != null)
            Text(
              st.camera!.focalLengthLabel!,
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 12,
              ),
            ),
        ],
      ),
    );
  }

  // ── 取景框 ──────────────────────────────────────────────────────────────────

  Widget _buildViewfinder(GrdCameraState grdState, CameraState cameraState) {
    final aspectRatio = grdState.previewAspectRatio;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: Container(
            color: const Color(0xFF0A0A0A),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 相机预览 + 渲染管线
                if (cameraState.isReady && cameraState.textureId != null)
                  _buildRenderedPreview(grdState, cameraState.textureId!)
                else
                  _buildPreviewPlaceholder(cameraState),

                // 网格叠加
                if (grdState.gridEnabled)
                  CustomPaint(painter: _GridPainter()),

                // 右上角 ··· 菜单
                Positioned(
                  top: 12,
                  right: 12,
                  child: GestureDetector(
                    onTap: () {
                      ref.read(grdCameraProvider.notifier).toggleTopMenu();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(120),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Text(
                        '···',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          letterSpacing: 3,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                ),

                // 曝光拖拽圆圈（参考截图 13001）
                if (_showExposureSlider)
                  Positioned(
                    right: 60,
                    bottom: 60,
                    child: GestureDetector(
                      onVerticalDragStart: (d) {
                        _dragStartY = d.globalPosition.dy;
                        _dragStartExposure = grdState.exposureValue;
                      },
                      onVerticalDragUpdate: (d) {
                        final delta = (_dragStartY - d.globalPosition.dy) / 150;
                        final newVal = (_dragStartExposure + delta).clamp(-2.0, 2.0);
                        ref.read(grdCameraProvider.notifier).setExposure(newVal);
                      },
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white60, width: 1.5),
                          color: Colors.transparent,
                        ),
                      ),
                    ),
                  ),

                // 底部悬浮控件条（温度 | 焦距 | 曝光）
                Positioned(
                  bottom: 14,
                  left: 16,
                  right: 16,
                  child: _buildViewfinderControls(grdState),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRenderedPreview(GrdCameraState grdState, int textureId) {
    final params = grdState.renderParams;
    if (params == null) {
      return Texture(textureId: textureId);
    }
    return PreviewFilterWidget(
      textureId: textureId,
      params: params,
      aspectRatio: grdState.previewAspectRatio,
    );
  }

  Widget _buildPreviewPlaceholder(CameraState cameraState) {
    if (cameraState.isLoading) {
      return const Center(
        child: CircularProgressIndicator(
          color: Colors.white24,
          strokeWidth: 1.5,
        ),
      );
    }
    if (cameraState.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.camera_alt_outlined,
                color: Colors.white24, size: 40),
            const SizedBox(height: 8),
            Text(
              cameraState.error!,
              style: const TextStyle(color: Colors.white24, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    return Container(color: const Color(0xFF0D0D0D));
  }

  // ── 取景框内悬浮控件条 ──────────────────────────────────────────────────────

  Widget _buildViewfinderControls(GrdCameraState st) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // 温度按钮
        _ViewfinderPill(
          onTap: () {
            // 弹出温度调节（简单循环）
            final cur = st.temperatureOffset;
            final next = cur <= -60 ? 0.0 : cur - 20.0;
            ref.read(grdCameraProvider.notifier).setTemperature(next);
          },
          child: const Icon(Icons.thermostat_outlined,
              color: Colors.white, size: 15),
        ),
        const SizedBox(width: 10),
        // 焦距/镜头标签
        _ViewfinderPill(
          onTap: () => ref.read(grdCameraProvider.notifier).togglePanel('lens'),
          child: Text(
            st.lensLabel,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 10),
        // 曝光值
        _ViewfinderPill(
          onTap: () {
            setState(() => _showExposureSlider = !_showExposureSlider);
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wb_sunny_outlined,
                  color: Colors.white, size: 13),
              const SizedBox(width: 4),
              Text(
                st.exposureValue == 0
                    ? '0.0'
                    : st.exposureValue.toStringAsFixed(1),
                style: TextStyle(
                  color: st.exposureValue != 0
                      ? Colors.white
                      : Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          isActive: st.exposureValue != 0,
        ),
      ],
    );
  }

  // ── 模式切换栏（照片 | 视频 | 样图 | 管理）──────────────────────────────────

  Widget _buildModeBar(GrdCameraState st) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          const SizedBox(width: 16),
          _ModeTab(label: '照片', isActive: true),
          const SizedBox(width: 20),
          _ModeTab(label: '视频', isActive: false),
          const Spacer(),
          // 样图按钮
          _TopRoundButton(
            icon: Icons.landscape_outlined,
            label: '样图',
            onTap: () {},
          ),
          const SizedBox(width: 8),
          // 管理按钮
          _TopRoundButton(
            icon: Icons.camera_outlined,
            label: '管理',
            onTap: () {},
          ),
          const SizedBox(width: 16),
        ],
      ),
    );
  }

  // ── 底部功能面板（滑出式）──────────────────────────────────────────────────

  Widget _buildActivePanel(GrdCameraState st) {
    final camera = st.camera;
    if (camera == null) return const SizedBox.shrink();

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      color: const Color(0xFFF2F2F2),
      child: switch (st.activePanel) {
        'filter' => _FilterPanel(
            filters: camera.modules.filters,
            activeId: st.activeFilterId,
            onSelect: (id) =>
                ref.read(grdCameraProvider.notifier).selectFilter(id),
          ),
        'lens' => _LensPanel(
            lenses: camera.modules.lenses,
            activeId: st.activeLensId,
            onSelect: (id) =>
                ref.read(grdCameraProvider.notifier).selectLens(id),
          ),
        'ratio' => _RatioPanel(
            ratios: camera.modules.ratios,
            activeId: st.activeRatioId,
            onSelect: (id) =>
                ref.read(grdCameraProvider.notifier).selectRatio(id),
          ),
        'frame' => _FramePanel(
            frames: camera.modules.frames,
            activeId: st.activeFrameId,
            activeRatioId: st.activeRatioId,
            onSelect: (id) =>
                ref.read(grdCameraProvider.notifier).selectFrame(id),
          ),
        'watermark' => _WatermarkPanel(
            presets: camera.modules.watermarks.presets,
            activeId: st.activeWatermarkId,
            onSelect: (id) =>
                ref.read(grdCameraProvider.notifier).selectWatermark(id),
          ),
        _ => const SizedBox.shrink(),
      },
    );
  }

  // ── 快门区 ──────────────────────────────────────────────────────────────────

  Widget _buildShutterRow(GrdCameraState st) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 左侧：图库缩略图
          _GalleryThumb(
            thumb: _latestThumb,
            onTap: () => context.push(AppRoutes.gallery),
          ),
          // 中间：快门按钮
          _ShutterButton(
            isTaking: st.isTakingPhoto,
            countdown: _timerCountdown,
            onTap: _handleShutter,
          ),
          // 右侧：相机切换（GRD R 图标）
          _CameraSwitchButton(
            isFront: st.isFrontCamera,
            onTap: () => ref.read(grdCameraProvider.notifier).switchCamera(),
          ),
        ],
      ),
    );
  }

  // ── 顶部菜单浮层 ────────────────────────────────────────────────────────────

  Widget _buildTopMenuOverlay(GrdCameraState st) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 60, 12, 0),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A).withAlpha(240),
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _TopMenuItem(
                      icon: st.gridEnabled
                          ? Icons.grid_on
                          : Icons.grid_off,
                      label: st.gridEnabled ? '网格线开启' : '网格线关闭',
                      onTap: () {
                        ref.read(grdCameraProvider.notifier).toggleGrid();
                      },
                    ),
                    _TopMenuItem(
                      icon: Icons.tune,
                      label: '清晰度',
                      onTap: () {},
                    ),
                    _TopMenuItem(
                      icon: Icons.crop_free,
                      label: '小框模式关闭',
                      onTap: () {},
                    ),
                    _TopMenuItem(
                      icon: Icons.filter_none,
                      label: '双重曝光关闭',
                      onTap: () {},
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _TopMenuItem(
                      icon: Icons.burst_mode_outlined,
                      label: '连拍关闭',
                      onTap: () {},
                    ),
                    _TopMenuItem(
                      icon: Icons.settings_outlined,
                      label: '设置',
                      onTap: () => context.push(AppRoutes.settings),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 取景框内悬浮药丸按钮
// ─────────────────────────────────────────────────────────────────────────────

class _ViewfinderPill extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  final bool isActive;

  const _ViewfinderPill({
    required this.child,
    required this.onTap,
    this.isActive = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: isActive
              ? Colors.white.withAlpha(220)
              : Colors.black.withAlpha(140),
          borderRadius: BorderRadius.circular(20),
        ),
        child: DefaultTextStyle(
          style: TextStyle(
            color: isActive ? Colors.black : Colors.white,
          ),
          child: child,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 模式标签
// ─────────────────────────────────────────────────────────────────────────────

class _ModeTab extends StatelessWidget {
  final String label;
  final bool isActive;

  const _ModeTab({required this.label, required this.isActive});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        color: isActive ? Colors.white : Colors.white38,
        fontSize: 16,
        fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 顶部圆角按钮（样图/管理）
// ─────────────────────────────────────────────────────────────────────────────

class _TopRoundButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _TopRoundButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white24),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white60, size: 14),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 快门按钮
// ─────────────────────────────────────────────────────────────────────────────

class _ShutterButton extends StatelessWidget {
  final bool isTaking;
  final int countdown;
  final VoidCallback onTap;

  const _ShutterButton({
    required this.isTaking,
    required this.countdown,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
        ),
        child: Center(
          child: isTaking
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                )
              : Container(
                  width: 58,
                  height: 58,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                  ),
                ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 图库缩略图
// ─────────────────────────────────────────────────────────────────────────────

class _GalleryThumb extends StatelessWidget {
  final Uint8List? thumb;
  final VoidCallback onTap;

  const _GalleryThumb({this.thumb, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFD4A017), width: 2.5),
          color: const Color(0xFF1A1A1A),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: thumb != null
              ? Image.memory(thumb!, fit: BoxFit.cover)
              : const Icon(Icons.photo_outlined,
                  color: Colors.white24, size: 24),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 相机切换按钮（GRD R 相机图标）
// ─────────────────────────────────────────────────────────────────────────────

class _CameraSwitchButton extends StatelessWidget {
  final bool isFront;
  final VoidCallback onTap;

  const _CameraSwitchButton({required this.isFront, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white24,
            width: 1,
            style: BorderStyle.solid,
          ),
        ),
        child: ClipOval(
          child: Container(
            color: const Color(0xFF111111),
            child: const Icon(
              Icons.cameraswitch_outlined,
              color: Colors.white60,
              size: 24,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 顶部菜单项
// ─────────────────────────────────────────────────────────────────────────────

class _TopMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _TopMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(color: Colors.white60, fontSize: 10),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 滤镜面板
// ─────────────────────────────────────────────────────────────────────────────

class _FilterPanel extends StatelessWidget {
  final List filters;
  final String? activeId;
  final void Function(String) onSelect;

  const _FilterPanel({
    required this.filters,
    required this.activeId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return _PanelContainer(
      title: '滤镜',
      rightAction: activeId != null ? '无滤镜' : null,
      onRightAction: activeId != null ? () => onSelect('none') : null,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            for (final f in filters)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: _FilterItem(
                  filter: f,
                  isActive: f.id == activeId,
                  onTap: () => onSelect(f.id),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FilterItem extends StatelessWidget {
  final dynamic filter;
  final bool isActive;
  final VoidCallback onTap;

  const _FilterItem({
    required this.filter,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: const Color(0xFFE0E0E0),
                  border: isActive
                      ? Border.all(color: Colors.black, width: 2.5)
                      : null,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    color: filter.id == 'grd_high_contrast'
                        ? const Color(0xFF2A2A2A)
                        : const Color(0xFF8A9BA8),
                  ),
                ),
              ),
              if (isActive)
                Positioned(
                  bottom: 4,
                  right: 4,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black,
                    ),
                    child: const Icon(Icons.check,
                        color: Colors.white, size: 12),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            filter.name as String,
            style: const TextStyle(fontSize: 11, color: Colors.black87),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 镜头面板（5个镜头）
// ─────────────────────────────────────────────────────────────────────────────

class _LensPanel extends StatelessWidget {
  final List lenses;
  final String? activeId;
  final void Function(String) onSelect;

  const _LensPanel({
    required this.lenses,
    required this.activeId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return _PanelContainer(
      title: '镜头',
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            for (final l in lenses)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: _LensItem(
                  lens: l,
                  isActive: l.id == activeId,
                  onTap: () => onSelect(l.id),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LensItem extends StatelessWidget {
  final dynamic lens;
  final bool isActive;
  final VoidCallback onTap;

  const _LensItem({
    required this.lens,
    required this.isActive,
    required this.onTap,
  });

  // 镜头特效颜色
  Color _lensColor(String id) {
    switch (id) {
      case 'wide': return const Color(0xFF4A90D9);
      case 'vintage': return const Color(0xFF8B6914);
      case 'dream': return const Color(0xFFD4A0C8);
      case 'prism': return const Color(0xFF6A4FC8);
      default: return const Color(0xFF4A4A4A);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _lensColor(lens.id as String),
                  border: isActive
                      ? Border.all(color: Colors.black, width: 2.5)
                      : Border.all(color: Colors.transparent, width: 2.5),
                ),
                child: Center(
                  child: Text(
                    (lens.nameEn as String).substring(0, 1).toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              if (isActive)
                Positioned(
                  bottom: 2,
                  right: 2,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black,
                    ),
                    child: const Icon(Icons.check,
                        color: Colors.white, size: 12),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            lens.name as String,
            style: const TextStyle(fontSize: 11, color: Colors.black87),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 比例面板
// ─────────────────────────────────────────────────────────────────────────────

class _RatioPanel extends StatelessWidget {
  final List ratios;
  final String? activeId;
  final void Function(String) onSelect;

  const _RatioPanel({
    required this.ratios,
    required this.activeId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return _PanelContainer(
      title: '比例',
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            for (final r in ratios)
              Padding(
                padding: const EdgeInsets.only(right: 20),
                child: _RatioItem(
                  ratio: r,
                  isActive: r.id == activeId,
                  onTap: () => onSelect(r.id),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RatioItem extends StatelessWidget {
  final dynamic ratio;
  final bool isActive;
  final VoidCallback onTap;

  const _RatioItem({
    required this.ratio,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final w = (ratio.width as int).toDouble();
    final h = (ratio.height as int).toDouble();
    final maxH = 56.0;
    final maxW = 56.0;
    double rw, rh;
    if (w / h > 1) {
      rw = maxW;
      rh = maxW * h / w;
    } else {
      rh = maxH;
      rw = maxH * w / h;
    }

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 64,
            height: 64,
            child: Center(
              child: Container(
                width: rw,
                height: rh,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isActive ? Colors.black : Colors.black38,
                    width: isActive ? 2.5 : 1.5,
                  ),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            ratio.label as String,
            style: TextStyle(
              fontSize: 12,
              color: isActive ? Colors.black : Colors.black54,
              fontWeight:
                  isActive ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 边框面板
// ─────────────────────────────────────────────────────────────────────────────

class _FramePanel extends StatelessWidget {
  final List frames;
  final String? activeId;
  final String? activeRatioId;
  final void Function(String) onSelect;

  const _FramePanel({
    required this.frames,
    required this.activeId,
    required this.activeRatioId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return _PanelContainer(
      title: '边框',
      rightAction: '无边框',
      onRightAction: () => onSelect('frame_none'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 样式 tab
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                _FrameTabLabel(label: '样式', isActive: true),
                const SizedBox(width: 20),
                _FrameTabLabel(label: '背景', isActive: false),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                // 随机/无边框
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: _FrameItem(
                    id: 'frame_none',
                    label: '无',
                    isActive: activeId == null || activeId == 'frame_none',
                    onTap: () => onSelect('frame_none'),
                    child: const Icon(Icons.shuffle, size: 28, color: Colors.black54),
                  ),
                ),
                for (final f in frames)
                  if (f.id != 'frame_none')
                    Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: _FrameItem(
                        id: f.id,
                        label: f.name,
                        isActive: f.id == activeId,
                        onTap: () => onSelect(f.id),
                        child: Container(
                          color: const Color(0xFFF5F2EA),
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Container(
                              color: const Color(0xFFD0C8B8),
                            ),
                          ),
                        ),
                      ),
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FrameTabLabel extends StatelessWidget {
  final String label;
  final bool isActive;
  const _FrameTabLabel({required this.label, required this.isActive});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            color: isActive ? Colors.black : Colors.black38,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        if (isActive)
          Container(
            margin: const EdgeInsets.only(top: 2),
            height: 2,
            width: 24,
            color: Colors.black,
          ),
      ],
    );
  }
}

class _FrameItem extends StatelessWidget {
  final String id;
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  final Widget child;

  const _FrameItem({
    required this.id,
    required this.label,
    required this.isActive,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: isActive
                      ? Border.all(color: Colors.black, width: 2.5)
                      : Border.all(color: Colors.black12, width: 1),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: child,
                ),
              ),
              if (isActive)
                Positioned(
                  bottom: 4,
                  right: 4,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black,
                    ),
                    child: const Icon(Icons.check,
                        color: Colors.white, size: 12),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(label,
              style: const TextStyle(fontSize: 11, color: Colors.black87)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 水印面板
// ─────────────────────────────────────────────────────────────────────────────

class _WatermarkPanel extends StatelessWidget {
  final List presets;
  final String? activeId;
  final void Function(String) onSelect;

  const _WatermarkPanel({
    required this.presets,
    required this.activeId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return _PanelContainer(
      title: '时间水印',
      rightAction: '无水印',
      onRightAction: () => onSelect('none'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 颜色 tab 行
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                _FrameTabLabel(label: '颜色', isActive: true),
                const SizedBox(width: 20),
                _FrameTabLabel(label: '样式', isActive: false),
                const SizedBox(width: 20),
                _FrameTabLabel(label: '位置', isActive: false),
                const SizedBox(width: 20),
                _FrameTabLabel(label: '方向', isActive: false),
                const SizedBox(width: 20),
                _FrameTabLabel(label: '大小', isActive: false),
              ],
            ),
          ),
          // 水印预览
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Container(
              width: double.infinity,
              height: 60,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: Text(
                  _currentDateString(),
                  style: TextStyle(
                    color: _activeColor(activeId),
                    fontSize: 22,
                    fontFamily: 'monospace',
                    letterSpacing: 2,
                  ),
                ),
              ),
            ),
          ),
          // 颜色选择行
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                // 彩虹渐变
                _ColorDot(
                  color: null,
                  isActive: false,
                  onTap: () {},
                  isRainbow: true,
                ),
                for (final color in _watermarkColors)
                  _ColorDot(
                    color: color,
                    isActive: _isColorActive(activeId, color),
                    onTap: () => _selectByColor(color, onSelect, presets),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static const List<Color> _watermarkColors = [
    Color(0xFF4CAF50),
    Color(0xFFFFEB3B),
    Color(0xFFFF9800),
    Color(0xFFFF8A3D), // date_orange
    Color(0xFFF44336),
    Color(0xFFE91E63),
    Color(0xFF2196F3),
    Colors.black,
    Colors.white,
  ];

  Color _activeColor(String? id) {
    if (id == 'date_orange') return const Color(0xFFFF8A3D);
    if (id == 'date_white') return Colors.white;
    return const Color(0xFFFF8A3D);
  }

  bool _isColorActive(String? activeId, Color color) {
    if (activeId == 'date_orange' &&
        color == const Color(0xFFFF8A3D)) return true;
    if (activeId == 'date_white' && color == Colors.white) return true;
    return false;
  }

  void _selectByColor(
      Color color, void Function(String) onSelect, List presets) {
    if (color == const Color(0xFFFF8A3D)) {
      onSelect('date_orange');
    } else if (color == Colors.white) {
      onSelect('date_white');
    } else {
      onSelect('date_orange');
    }
  }

  String _currentDateString() {
    final now = DateTime.now();
    return '${now.month} ${now.day.toString().padLeft(2, '0')} \'${now.year.toString().substring(2)}';
  }
}

class _ColorDot extends StatelessWidget {
  final Color? color;
  final bool isActive;
  final VoidCallback onTap;
  final bool isRainbow;

  const _ColorDot({
    this.color,
    required this.isActive,
    required this.onTap,
    this.isRainbow = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 10),
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: isRainbow
              ? const SweepGradient(colors: [
                  Colors.red,
                  Colors.orange,
                  Colors.yellow,
                  Colors.green,
                  Colors.blue,
                  Colors.purple,
                  Colors.red,
                ])
              : null,
          color: isRainbow ? null : color,
          border: isActive
              ? Border.all(color: Colors.black, width: 2.5)
              : Border.all(color: Colors.black12, width: 1),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 面板容器（通用）
// ─────────────────────────────────────────────────────────────────────────────

class _PanelContainer extends StatelessWidget {
  final String title;
  final String? rightAction;
  final VoidCallback? onRightAction;
  final Widget child;

  const _PanelContainer({
    required this.title,
    this.rightAction,
    this.onRightAction,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF2F2F2),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 拖拽指示条
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.black12,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // 标题行
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 16, 0),
            child: Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.black,
                  ),
                ),
                const Spacer(),
                if (rightAction != null)
                  GestureDetector(
                    onTap: onRightAction,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        rightAction!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 网格画笔
// ─────────────────────────────────────────────────────────────────────────────

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withAlpha(60)
      ..strokeWidth = 0.5;
    // 三等分线
    for (int i = 1; i < 3; i++) {
      final x = size.width * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
