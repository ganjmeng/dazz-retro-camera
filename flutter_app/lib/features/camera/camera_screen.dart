// camera_screen.dart
// DAZZ 相机主界面 — 多相机支持版本
//
// UI 结构（对照截图）：
//   黑色背景
//   ├── 顶部状态区（绿点 + 相机名 + 焦距）
//   ├── 取景框（圆角矩形，内含实时渲染预览 + 悬浮控件）
//   │     ├── 预览渲染（ColorFilter 色彩矩阵 + 暗角 + 色差）
//   │     ├── 网格叠加
//   │     ├── 右上角 ··· 菜单按钮
//   │     └── 底部悬浮控件条（温度 | 焦距 | 曝光）
//   ├── 模式切换栏（照片 | 视频 | 样图 | 管理）
//   ├── 底部功能工具栏（时间水印 | 边框 | 比例 | 滤镜 | 镜头）
//   ├── 底部功能面板（滑出式）
//   └── 快门区（图库缩略图 | 快门按钮 | 相机管理按钮）

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../models/camera_registry.dart';
import '../../services/camera_service.dart';
import '../../router/app_router.dart';
import 'camera_notifier.dart';
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
      await ref.read(cameraAppProvider.notifier).initialize();
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
    final notifier = ref.read(cameraAppProvider.notifier);
    final st = ref.read(cameraAppProvider);
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

  Future<void> _doTakePhoto(CameraAppNotifier notifier) async {
    final path = await notifier.takePhoto();
    if (path != null && mounted) {
      _loadLatestDazzPhoto();
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(cameraAppProvider);
    final cameraState = ref.watch(cameraServiceProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () {
          ref.read(cameraAppProvider.notifier).closeAllPanels();
          setState(() => _showExposureSlider = false);
        },
        behavior: HitTestBehavior.translucent,
        child: Stack(
          children: [
            SafeArea(
              child: Column(
                children: [
                  _buildTopBar(appState),
                  Expanded(
                    child: _buildViewfinder(appState, cameraState),
                  ),
                  _buildModeBar(appState),
                  _buildBottomToolbar(appState),
                  if (appState.activePanel != null)
                    _buildActivePanel(appState)
                  else
                    const SizedBox(height: 4),
                  _buildShutterRow(appState),
                  const SizedBox(height: 16),
                ],
              ),
            ),
            // 拍照闪光
            if (appState.showCaptureFlash)
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
            if (appState.showTopMenu)
              _buildTopMenuOverlay(appState),
            // 相机管理浮层
            if (appState.showCameraManager)
              _buildCameraManagerOverlay(appState),
          ],
        ),
      ),
    );
  }

  // ── 顶部状态栏 ──────────────────────────────────────────────────────────────

  Widget _buildTopBar(CameraAppState st) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF00E676),
            ),
          ),
          const Spacer(),
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

  Widget _buildViewfinder(CameraAppState appState, CameraState cameraState) {
    final aspectRatio = appState.previewAspectRatio;

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
                  _buildRenderedPreview(appState, cameraState.textureId!)
                else
                  _buildPreviewPlaceholder(cameraState),

                // 网格叠加
                if (appState.gridEnabled)
                  CustomPaint(painter: _GridPainter()),

                // 右上角 ··· 菜单
                Positioned(
                  top: 12,
                  right: 12,
                  child: GestureDetector(
                    onTap: () {
                      ref.read(cameraAppProvider.notifier).toggleTopMenu();
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

                // 曝光拖拽圆圈
                if (_showExposureSlider)
                  Positioned(
                    right: 60,
                    bottom: 60,
                    child: GestureDetector(
                      onVerticalDragStart: (d) {
                        _dragStartY = d.globalPosition.dy;
                        _dragStartExposure = appState.exposureValue;
                      },
                      onVerticalDragUpdate: (d) {
                        final delta = (_dragStartY - d.globalPosition.dy) / 150;
                        final newVal = (_dragStartExposure + delta).clamp(-2.0, 2.0);
                        ref.read(cameraAppProvider.notifier).setExposure(newVal);
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
                  child: _buildViewfinderControls(appState),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRenderedPreview(CameraAppState appState, int textureId) {
    final params = appState.renderParams;
    if (params == null) {
      return Texture(textureId: textureId);
    }
    return PreviewFilterWidget(
      textureId: textureId,
      params: params,
      aspectRatio: appState.previewAspectRatio,
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

  Widget _buildViewfinderControls(CameraAppState st) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // 温度按钮
        _ViewfinderPill(
          onTap: () {
            final cur = st.temperatureOffset;
            final next = cur <= -60 ? 0.0 : cur - 20.0;
            ref.read(cameraAppProvider.notifier).setTemperature(next);
          },
          child: const Icon(Icons.thermostat_outlined,
              color: Colors.white, size: 15),
        ),
        const SizedBox(width: 10),
        // 焦距/镜头标签
        _ViewfinderPill(
          onTap: () => ref.read(cameraAppProvider.notifier).togglePanel('lens'),
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
                style: const TextStyle(
                  color: Colors.white,
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

  Widget _buildModeBar(CameraAppState st) {
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
          _TopRoundButton(
            icon: Icons.landscape_outlined,
            label: '样图',
            onTap: () {},
          ),
          const SizedBox(width: 8),
          _TopRoundButton(
            icon: Icons.camera_outlined,
            label: '管理',
            onTap: () => ref.read(cameraAppProvider.notifier).toggleCameraManager(),
          ),
          const SizedBox(width: 16),
        ],
      ),
    );
  }

  // ── 底部功能工具栏（5个按钮）──────────────────────────────────────────────

  Widget _buildBottomToolbar(CameraAppState st) {
    if (st.camera == null) return const SizedBox(height: 8);
    final caps = st.camera!.uiCapabilities;

    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // 时间水印
          if (caps.enableWatermark)
            _ToolbarButton(
              icon: Icons.access_time_outlined,
              label: '时间水印',
              isActive: st.activePanel == 'watermark',
              onTap: () => ref.read(cameraAppProvider.notifier).togglePanel('watermark'),
            ),
          // 边框
          if (caps.enableFrame)
            _ToolbarButton(
              icon: Icons.crop_free_outlined,
              label: '边框',
              isActive: st.activePanel == 'frame',
              hasSelection: st.activeFrameId != null,
              onTap: () => ref.read(cameraAppProvider.notifier).togglePanel('frame'),
            ),
          // 比例
          if (caps.enableRatio)
            _ToolbarButton(
              icon: Icons.aspect_ratio_outlined,
              label: '原比例',
              isActive: st.activePanel == 'ratio',
              onTap: () => ref.read(cameraAppProvider.notifier).togglePanel('ratio'),
            ),
          // 滤镜
          if (caps.enableFilter)
            _ToolbarButton(
              icon: Icons.filter_outlined,
              label: '滤镜',
              isActive: st.activePanel == 'filter',
              onTap: () => ref.read(cameraAppProvider.notifier).togglePanel('filter'),
            ),
          // 镜头
          if (caps.enableLens)
            _ToolbarButton(
              icon: Icons.lens_outlined,
              label: '镜头',
              isActive: st.activePanel == 'lens',
              onTap: () => ref.read(cameraAppProvider.notifier).togglePanel('lens'),
            ),
          // 闪光灯
          _ToolbarButton(
            icon: _flashIcon(st.flashMode),
            label: _flashLabel(st.flashMode),
            isActive: st.flashMode != 'off',
            onTap: () => ref.read(cameraAppProvider.notifier).cycleFlash(),
          ),
          // 倒计时
          _ToolbarButton(
            icon: Icons.timer_outlined,
            label: st.timerSeconds == 0 ? '倒计时' : '${st.timerSeconds}s',
            isActive: st.timerSeconds > 0,
            onTap: () => ref.read(cameraAppProvider.notifier).cycleTimer(),
          ),
        ],
      ),
    );
  }

  IconData _flashIcon(String mode) {
    switch (mode) {
      case 'on': return Icons.flash_on;
      case 'auto': return Icons.flash_auto;
      default: return Icons.flash_off;
    }
  }

  String _flashLabel(String mode) {
    switch (mode) {
      case 'on': return '闪光灯';
      case 'auto': return '自动';
      default: return '闪光灯';
    }
  }

  // ── 底部功能面板（滑出式）──────────────────────────────────────────────────

  Widget _buildActivePanel(CameraAppState st) {
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
                ref.read(cameraAppProvider.notifier).selectFilter(id),
          ),
        'lens' => _LensPanel(
            lenses: camera.modules.lenses,
            activeId: st.activeLensId,
            onSelect: (id) =>
                ref.read(cameraAppProvider.notifier).selectLens(id),
          ),
        'ratio' => _RatioPanel(
            ratios: camera.modules.ratios,
            activeId: st.activeRatioId,
            onSelect: (id) =>
                ref.read(cameraAppProvider.notifier).selectRatio(id),
          ),
        'frame' => _FramePanel(
            frames: camera.modules.frames,
            activeId: st.activeFrameId,
            onSelect: (id) =>
                ref.read(cameraAppProvider.notifier).selectFrame(id),
          ),
        'watermark' => _WatermarkPanel(
            presets: camera.modules.watermarks.presets,
            activeId: st.activeWatermarkId,
            onSelect: (id) =>
                ref.read(cameraAppProvider.notifier).selectWatermark(id),
          ),
        _ => const SizedBox.shrink(),
      },
    );
  }

  // ── 快门区 ──────────────────────────────────────────────────────────────────

  Widget _buildShutterRow(CameraAppState st) {
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
          // 右侧：相机管理按钮（打开相机切换列表）
          _CameraManagerButton(
            cameraName: st.camera?.name ?? 'GRD R',
            onTap: () => ref.read(cameraAppProvider.notifier).toggleCameraManager(),
          ),
        ],
      ),
    );
  }

  // ── 顶部菜单浮层 ────────────────────────────────────────────────────────────

  Widget _buildTopMenuOverlay(CameraAppState st) {
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
                      icon: st.gridEnabled ? Icons.grid_on : Icons.grid_off,
                      label: st.gridEnabled ? '网格线开启' : '网格线关闭',
                      onTap: () {
                        ref.read(cameraAppProvider.notifier).toggleGrid();
                      },
                    ),
                    _TopMenuItem(
                      icon: Icons.tune,
                      label: '清晰度',
                      onTap: () {},
                    ),
                    _TopMenuItem(
                      icon: Icons.crop_free,
                      label: '小框模式',
                      onTap: () {},
                    ),
                    _TopMenuItem(
                      icon: Icons.filter_none,
                      label: '双重曝光',
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
                      label: '连拍',
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

  // ── 相机管理浮层（切换相机）──────────────────────────────────────────────────

  Widget _buildCameraManagerOverlay(CameraAppState st) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        top: false,
        child: Container(
          decoration: const BoxDecoration(
            color: Color(0xFF111111),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 拖拽指示条
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                '选择相机',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              // 相机列表
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final entry in kAllCameras)
                      Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: _CameraCard(
                          entry: entry,
                          isActive: st.activeCameraId == entry.id,
                          onTap: () => ref
                              .read(cameraAppProvider.notifier)
                              .switchToCamera(entry.id),
                        ),
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
}

// ─────────────────────────────────────────────────────────────────────────────
// 相机卡片（相机管理列表中）
// ─────────────────────────────────────────────────────────────────────────────

class _CameraCard extends StatelessWidget {
  final CameraEntry entry;
  final bool isActive;
  final VoidCallback onTap;

  const _CameraCard({
    required this.entry,
    required this.isActive,
    required this.onTap,
  });

  Color _categoryColor(String cat) {
    switch (cat) {
      case 'ccd': return const Color(0xFF4A90D9);
      case 'film': return const Color(0xFFD4A017);
      case 'digital': return const Color(0xFF4CAF50);
      default: return const Color(0xFF666666);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _categoryColor(entry.category);
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: color.withAlpha(30),
              borderRadius: BorderRadius.circular(16),
              border: isActive
                  ? Border.all(color: color, width: 2.5)
                  : Border.all(color: Colors.white12, width: 1),
            ),
            child: Stack(
              children: [
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.camera_alt_outlined, color: color, size: 28),
                      if (entry.focalLengthLabel != null)
                        Text(
                          entry.focalLengthLabel!,
                          style: TextStyle(
                            color: color,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ),
                if (isActive)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: color,
                      ),
                      child: const Icon(Icons.check, color: Colors.white, size: 10),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            entry.name,
            style: TextStyle(
              color: isActive ? Colors.white : Colors.white60,
              fontSize: 12,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          Text(
            entry.category.toUpperCase(),
            style: TextStyle(
              color: color.withAlpha(180),
              fontSize: 9,
              letterSpacing: 1,
            ),
          ),
        ],
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
// 底部工具栏按钮
// ─────────────────────────────────────────────────────────────────────────────

class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final bool hasSelection;
  final VoidCallback onTap;

  const _ToolbarButton({
    required this.icon,
    required this.label,
    required this.isActive,
    this.hasSelection = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isActive ? Colors.white : Colors.white54;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(icon, color: color, size: 22),
              if (hasSelection)
                Positioned(
                  top: -2,
                  right: -2,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFFD4A017),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 9,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
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
// 相机管理按钮（右下角，打开相机切换列表）
// ─────────────────────────────────────────────────────────────────────────────

class _CameraManagerButton extends StatelessWidget {
  final String cameraName;
  final VoidCallback onTap;

  const _CameraManagerButton({required this.cameraName, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24, width: 1),
          color: const Color(0xFF111111),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.camera_alt_outlined, color: Colors.white70, size: 20),
            const SizedBox(height: 2),
            Text(
              cameraName,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 7,
                letterSpacing: 0.5,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ],
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
                  onTap: () => onSelect(f.id as String),
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

  Color _filterPreviewColor(String id) {
    // Visual preview color per filter
    if (id.contains('high_contrast')) return const Color(0xFF2A2A2A);
    if (id.contains('faded')) return const Color(0xFFB8A898);
    if (id.contains('retro')) return const Color(0xFF8A6A4A);
    return const Color(0xFF8A9BA8);
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
                  borderRadius: BorderRadius.circular(12),
                  color: _filterPreviewColor(filter.id as String),
                  border: isActive
                      ? Border.all(color: Colors.black, width: 2.5)
                      : null,
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
// 镜头面板
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
                  onTap: () => onSelect(l.id as String),
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

  Color _lensColor(String id) {
    switch (id) {
      case 'wide': return const Color(0xFF4A90D9);
      case 'vintage': return const Color(0xFF8B6914);
      case 'dream': return const Color(0xFFD4A0C8);
      case 'prism': return const Color(0xFF6A4FC8);
      case 'light_leak': return const Color(0xFFE8A040);
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
                  onTap: () => onSelect(r.id as String),
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
    const maxH = 56.0;
    const maxW = 56.0;
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
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
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
  final void Function(String) onSelect;

  const _FramePanel({
    required this.frames,
    required this.activeId,
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                _TabLabel(label: '样式', isActive: true),
                const SizedBox(width: 20),
                _TabLabel(label: '背景', isActive: false),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                // 无边框选项
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: _FrameItem(
                    id: 'frame_none',
                    label: '无',
                    isActive: activeId == null || activeId == 'frame_none',
                    onTap: () => onSelect('frame_none'),
                    child: const Icon(Icons.block, size: 28, color: Colors.black38),
                  ),
                ),
                for (final f in frames)
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: _FrameItem(
                      id: f.id as String,
                      label: f.name as String,
                      isActive: f.id == activeId,
                      onTap: () => onSelect(f.id as String),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                _TabLabel(label: '颜色', isActive: true),
                const SizedBox(width: 20),
                _TabLabel(label: '样式', isActive: false),
                const SizedBox(width: 20),
                _TabLabel(label: '位置', isActive: false),
                const SizedBox(width: 20),
                _TabLabel(label: '方向', isActive: false),
                const SizedBox(width: 20),
                _TabLabel(label: '大小', isActive: false),
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
                _ColorDot(
                  color: null,
                  isActive: false,
                  onTap: () {},
                  isRainbow: true,
                ),
                for (final preset in presets)
                  if (!(preset.isNone as bool))
                    _ColorDot(
                      color: _parseColor(preset.color as String?),
                      isActive: preset.id == activeId,
                      onTap: () => onSelect(preset.id as String),
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color? _parseColor(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    try {
      return Color(int.parse('FF${hex.replaceAll('#', '')}', radix: 16));
    } catch (_) {
      return null;
    }
  }

  Color _activeColor(String? id) {
    if (id == null) return const Color(0xFFFF8A3D);
    for (final p in presets) {
      if (p.id == id) {
        final c = _parseColor(p.color as String?);
        if (c != null) return c;
      }
    }
    return const Color(0xFFFF8A3D);
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
// 通用 Tab 标签
// ─────────────────────────────────────────────────────────────────────────────

class _TabLabel extends StatelessWidget {
  final String label;
  final bool isActive;
  const _TabLabel({required this.label, required this.isActive});
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
