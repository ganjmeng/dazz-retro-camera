// DAZZ 相机主界面 — 精细化 1:1 复刻版
//
// 设计规格（严格按照设计稿）：
// ┌─────────────────────────────────────────────────────────────────────────┐
// │  黑色背景 #000000                                                        │
// │  ┌──────────────────────────────────────────────────────────────────┐   │
// │  │ 顶部状态栏：● 绿点(左) │ 相机名(居中) │ 焦距(右)                  │   │
// │  ├──────────────────────────────────────────────────────────────────┤   │
// │  │ 取景框（圆角矩形，白色1.5px边框）                                  │   │
// │  │  ├── 实时预览（ColorFilter渲染）                                   │   │
// │  │  ├── 对焦框（白色圆角矩形）                                        │   │
// │  │  ├── 网格线（可选）                                               │   │
// │  │  ├── 右上角 ··· 菜单                                             │   │
// │  │  ├── 右侧竖向焦距文字                                             │   │
// │  │  └── 底部控制胶囊：[温度图标 48] [焦距] [☀ 0.0]                  │   │
// │  ├──────────────────────────────────────────────────────────────────┤   │
// │  │ 底部工具栏（5图标，无文字）：                                      │   │
// │  │  [导入] [边框] [计时器] [闪光灯] [翻转摄像头]                      │   │
// │  ├──────────────────────────────────────────────────────────────────┤   │
// │  │ 功能面板（深色，从底部滑出）                                       │   │
// │  ├──────────────────────────────────────────────────────────────────┤   │
// │  │ 快门行：[图库缩略图(蓝边)] [快门大圆] [相机切换按钮]               │   │
// │  └──────────────────────────────────────────────────────────────────┘   │
// └─────────────────────────────────────────────────────────────────────────┘

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
// 颜色常量（严格按设计稿）
// ─────────────────────────────────────────────────────────────────────────────
const _kBg = Color(0xFF000000);
const _kPanelBg = Color(0xFF1C1C1E);        // iOS 深色面板
const _kCardBg = Color(0xFF2C2C2E);         // 卡片/按钮背景
const _kCardBg2 = Color(0xFF3A3A3C);        // 稍亮的卡片
const _kTextPrimary = Color(0xFFFFFFFF);
const _kTextSecondary = Color(0xFF8E8E93);
const _kAccentRed = Color(0xFFFF3B30);      // iOS 红
const _kAccentBlue = Color(0xFF007AFF);     // iOS 蓝
const _kGreenDot = Color(0xFF34C759);       // 绿色指示灯

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

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _kBg,
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
                    _buildBottomToolbar(appState),
                    if (appState.activePanel != null)
                      _buildActivePanel(appState),
                    _buildShutterRow(appState),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
              // 拍照白色闪光
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
              // 顶部 ··· 菜单浮层
              if (appState.showTopMenu)
                _buildTopMenuOverlay(appState),
              // 相机切换浮层
              if (appState.showCameraManager)
                _buildCameraPickerSheet(appState),
            ],
          ),
        ),
      ),
    );
  }

  // ── 顶部状态栏 ──────────────────────────────────────────────────────────────
  // 设计稿：绿点(左) | 相机名(居中) | 焦距(右)

  Widget _buildTopBar(CameraAppState st) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Row(
        children: [
          // 绿色指示灯
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: _kGreenDot,
            ),
          ),
          const Spacer(),
          // 相机名（居中）
          if (st.camera != null)
            Text(
              st.camera!.name,
              style: const TextStyle(
                color: _kTextPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.3,
              ),
            ),
          const Spacer(),
          // 焦距（右）
          if (st.camera?.focalLengthLabel != null)
            Text(
              st.camera!.focalLengthLabel!,
              style: const TextStyle(
                color: _kTextSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w400,
              ),
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }

  // ── 取景框 ──────────────────────────────────────────────────────────────────
  // 设计稿：圆角矩形 + 白色1.5px边框 + 右侧竖向焦距 + 底部控制胶囊

  Widget _buildViewfinder(CameraAppState appState, CameraState cameraState) {
    final aspectRatio = appState.previewAspectRatio;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withAlpha(60), width: 1.5),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12.5),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 相机预览
                if (cameraState.isReady && cameraState.textureId != null)
                  _buildRenderedPreview(appState, cameraState.textureId!)
                else
                  _buildPreviewPlaceholder(cameraState),

                // 网格叠加
                if (appState.gridEnabled)
                  CustomPaint(painter: _GridPainter()),

                // 右上角 ··· 菜单
                Positioned(
                  top: 10,
                  right: 10,
                  child: GestureDetector(
                    onTap: () => ref.read(cameraAppProvider.notifier).toggleTopMenu(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(100),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        '···',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          letterSpacing: 3,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                ),

                // 右侧竖向焦距文字（设计稿特征）
                if (appState.camera?.focalLengthLabel != null)
                  Positioned(
                    right: 10,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: RotatedBox(
                        quarterTurns: 1,
                        child: Text(
                          appState.camera!.focalLengthLabel!,
                          style: TextStyle(
                            color: Colors.white.withAlpha(100),
                            fontSize: 10,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.w300,
                          ),
                        ),
                      ),
                    ),
                  ),

                // 曝光拖拽圆圈
                if (_showExposureSlider)
                  Positioned(
                    right: 50,
                    bottom: 50,
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
                        ),
                      ),
                    ),
                  ),

                // 底部控制胶囊（单个胶囊内：温度 | 焦距 | 曝光）
                Positioned(
                  bottom: 12,
                  left: 0,
                  right: 0,
                  child: Center(child: _buildControlCapsule(appState)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 单个胶囊：[🌡 48] [48mm] [☀ 0.0]
  Widget _buildControlCapsule(CameraAppState st) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(160),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 温度
          GestureDetector(
            onTap: () {
              final cur = st.temperatureOffset;
              final next = cur <= -60 ? 0.0 : cur - 20.0;
              ref.read(cameraAppProvider.notifier).setTemperature(next);
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.thermostat_outlined, color: Colors.white, size: 13),
                const SizedBox(width: 3),
                Text(
                  '${(st.temperatureOffset + 48).round()}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          // 分隔线
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 10),
            width: 1,
            height: 14,
            color: Colors.white24,
          ),
          // 焦距/镜头
          GestureDetector(
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
          // 分隔线
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 10),
            width: 1,
            height: 14,
            color: Colors.white24,
          ),
          // 曝光
          GestureDetector(
            onTap: () => setState(() => _showExposureSlider = !_showExposureSlider),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.wb_sunny_outlined,
                  color: st.exposureValue != 0 ? Colors.amber : Colors.white,
                  size: 13,
                ),
                const SizedBox(width: 3),
                Text(
                  st.exposureValue == 0
                      ? '0'
                      : (st.exposureValue > 0
                          ? '+${st.exposureValue.toStringAsFixed(1)}'
                          : st.exposureValue.toStringAsFixed(1)),
                  style: TextStyle(
                    color: st.exposureValue != 0 ? Colors.amber : Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRenderedPreview(CameraAppState appState, int textureId) {
    final params = appState.renderParams;
    if (params == null) return Texture(textureId: textureId);
    return PreviewFilterWidget(
      textureId: textureId,
      params: params,
      aspectRatio: appState.previewAspectRatio,
    );
  }

  Widget _buildPreviewPlaceholder(CameraState cameraState) {
    if (cameraState.isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white24, strokeWidth: 1.5),
      );
    }
    if (cameraState.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.camera_alt_outlined, color: Colors.white24, size: 40),
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

  // ── 底部工具栏（5个图标，无文字标签）──────────────────────────────────────
  // 设计稿：[导入照片] [边框/样式] [计时器] [闪光灯] [翻转摄像头]

  Widget _buildBottomToolbar(CameraAppState st) {
    return Container(
      color: _kBg,
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 导入照片
          _ToolbarIcon(
            icon: Icons.add_photo_alternate_outlined,
            onTap: () => context.push(AppRoutes.gallery),
          ),
          // 边框/样式（打开配置面板）
          _ToolbarIcon(
            icon: Icons.filter_frames_outlined,
            isActive: appState.activePanel != null,
            onTap: () => ref.read(cameraAppProvider.notifier).togglePanel('config'),
          ),
          // 计时器
          _ToolbarIcon(
            icon: st.timerSeconds == 0
                ? Icons.timer_outlined
                : (st.timerSeconds == 3 ? Icons.timer_3_outlined : Icons.timer_10_outlined),
            isActive: st.timerSeconds > 0,
            onTap: () => ref.read(cameraAppProvider.notifier).cycleTimer(),
          ),
          // 闪光灯
          _ToolbarIcon(
            icon: _flashIcon(st.flashMode),
            isActive: st.flashMode != 'off',
            hasRedLine: st.flashMode == 'off',
            onTap: () => ref.read(cameraAppProvider.notifier).cycleFlash(),
          ),
          // 翻转摄像头
          _ToolbarIcon(
            icon: Icons.flip_camera_ios_outlined,
            onTap: () => ref.read(cameraServiceProvider.notifier).switchCamera(),
          ),
        ],
      ),
    );
  }

  // 获取 appState（用于底部工具栏）
  CameraAppState get appState => ref.read(cameraAppProvider);

  IconData _flashIcon(String mode) {
    switch (mode) {
      case 'on': return Icons.flash_on;
      case 'auto': return Icons.flash_auto;
      default: return Icons.flash_off;
    }
  }

  // ── 功能配置面板（深色主题，从底部滑出）──────────────────────────────────

  Widget _buildActivePanel(CameraAppState st) {
    final camera = st.camera;
    if (camera == null) return const SizedBox.shrink();

    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      child: switch (st.activePanel) {
        'config' => _ConfigSheet(
            appState: st,
            onSelectFilter: (id) => ref.read(cameraAppProvider.notifier).selectFilter(id),
            onSelectRatio: (id) => ref.read(cameraAppProvider.notifier).selectRatio(id),
            onSelectFrame: (id) => ref.read(cameraAppProvider.notifier).selectFrame(id),
            onSelectWatermark: (id) => ref.read(cameraAppProvider.notifier).selectWatermark(id),
            onSelectLens: (id) => ref.read(cameraAppProvider.notifier).selectLens(id),
          ),
        'lens' => _DarkPanel(
            title: '镜头',
            child: _LensRow(
              lenses: camera.modules.lenses,
              activeId: st.activeLensId,
              onSelect: (id) => ref.read(cameraAppProvider.notifier).selectLens(id),
            ),
          ),
        'filter' => _DarkPanel(
            title: '色彩配置',
            child: _FilterRow(
              filters: camera.modules.filters,
              activeId: st.activeFilterId,
              onSelect: (id) => ref.read(cameraAppProvider.notifier).selectFilter(id),
            ),
          ),
        'ratio' => _DarkPanel(
            title: '比例',
            child: _RatioRow(
              ratios: camera.modules.ratios,
              activeId: st.activeRatioId,
              onSelect: (id) => ref.read(cameraAppProvider.notifier).selectRatio(id),
            ),
          ),
        'frame' => _DarkPanel(
            title: '边框',
            child: _FrameColorGrid(
              frames: camera.modules.frames,
              activeId: st.activeFrameId,
              onSelect: (id) => ref.read(cameraAppProvider.notifier).selectFrame(id),
            ),
          ),
        'watermark' => _DarkPanel(
            title: '时间水印',
            child: _WatermarkRow(
              presets: camera.modules.watermarks.presets,
              activeId: st.activeWatermarkId,
              onSelect: (id) => ref.read(cameraAppProvider.notifier).selectWatermark(id),
            ),
          ),
        _ => const SizedBox.shrink(),
      },
    );
  }

  // ── 快门行 ──────────────────────────────────────────────────────────────────
  // 设计稿：[图库缩略图(蓝边)] [快门大圆] [相机切换按钮]

  Widget _buildShutterRow(CameraAppState st) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 左：图库缩略图（蓝色边框）
          _GalleryThumb(
            thumb: _latestThumb,
            onTap: () => context.push(AppRoutes.gallery),
          ),
          // 中：快门按钮
          _ShutterButton(
            isTaking: st.isTakingPhoto,
            countdown: _timerCountdown,
            onTap: _handleShutter,
          ),
          // 右：相机切换按钮（深灰圆角矩形）
          _CameraSwitchButton(
            onTap: () => ref.read(cameraAppProvider.notifier).toggleCameraManager(),
          ),
        ],
      ),
    );
  }

  // ── 顶部 ··· 菜单浮层 ────────────────────────────────────────────────────
  // 设计稿：3x2 网格，深灰半透明圆角矩形

  Widget _buildTopMenuOverlay(CameraAppState st) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 52, 12, 0),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E).withAlpha(245),
              borderRadius: BorderRadius.circular(18),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _TopMenuItem(
                      icon: st.gridEnabled ? Icons.grid_on : Icons.grid_off,
                      label: '辅助线',
                      isActive: st.gridEnabled,
                      onTap: () => ref.read(cameraAppProvider.notifier).toggleGrid(),
                    ),
                    _TopMenuItem(
                      icon: Icons.exposure,
                      label: '曝光补偿',
                      onTap: () {},
                    ),
                    _TopMenuItem(
                      icon: Icons.crop_free,
                      label: '裁剪',
                      onTap: () {},
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _TopMenuItem(
                      icon: Icons.text_fields_outlined,
                      label: '变焦模式',
                      onTap: () {},
                    ),
                    _TopMenuItem(
                      icon: Icons.settings_outlined,
                      label: '设置',
                      onTap: () => context.push(AppRoutes.settings),
                    ),
                    const SizedBox(width: 56),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── 相机切换浮层（底部弹出）──────────────────────────────────────────────
  // 设计稿：Dazz Pro 横幅 + 两行相机列表（视频类/胶片类）

  Widget _buildCameraPickerSheet(CameraAppState st) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        top: false,
        child: Container(
          decoration: const BoxDecoration(
            color: Color(0xFF1C1C1E),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 拖拽指示条
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 4),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Dazz Pro 横幅
              _buildDazzProBanner(),
              const SizedBox(height: 12),
              // 相机列表（两行）
              _buildCameraRows(st),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  // Dazz Pro 横幅（蓝→红渐变）
  Widget _buildDazzProBanner() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF1A6FE0), Color(0xFFC0392B)],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const SizedBox(width: 16),
            // Dazz 文字 logo
            const Text(
              'Dazz',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                '解锁所有相机和配件。',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white, size: 20),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }

  // 两行相机列表
  Widget _buildCameraRows(CameraAppState st) {
    // 按分类分组
    final videoGroup = kAllCameras.where((c) => c.category == 'video' || c.category == 'digital').toList();
    final filmGroup = kAllCameras.where((c) => c.category == 'film' || c.category == 'ccd').toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (videoGroup.isNotEmpty) ...[
          _buildCameraRow(videoGroup, st),
          const SizedBox(height: 4),
        ],
        if (filmGroup.isNotEmpty)
          _buildCameraRow(filmGroup, st),
      ],
    );
  }

  Widget _buildCameraRow(List<CameraEntry> cameras, CameraAppState st) {
    return SizedBox(
      height: 96,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: cameras.length,
        itemBuilder: (_, i) {
          final entry = cameras[i];
          return Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _CameraPickerItem(
              entry: entry,
              isActive: st.activeCameraId == entry.id,
              onTap: () => ref.read(cameraAppProvider.notifier).switchToCamera(entry.id),
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 相机选择器项目
// ─────────────────────────────────────────────────────────────────────────────

class _CameraPickerItem extends StatelessWidget {
  final CameraEntry entry;
  final bool isActive;
  final VoidCallback onTap;

  const _CameraPickerItem({
    required this.entry,
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
          // 相机图标容器
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: _kCardBg,
              borderRadius: BorderRadius.circular(14),
              border: isActive
                  ? Border.all(color: Colors.white, width: 2)
                  : null,
            ),
            child: Stack(
              children: [
                Center(
                  child: Icon(
                    Icons.camera_alt_outlined,
                    color: isActive ? Colors.white : _kTextSecondary,
                    size: 26,
                  ),
                ),
                // 选中勾
                if (isActive)
                  Positioned(
                    bottom: 4,
                    right: 4,
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                      ),
                      child: const Icon(Icons.check, color: Colors.black, size: 10),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          // 相机名称
          Text(
            entry.name,
            style: TextStyle(
              color: isActive ? Colors.white : _kTextSecondary,
              fontSize: 11,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 底部工具栏图标按钮（无文字）
// ─────────────────────────────────────────────────────────────────────────────

class _ToolbarIcon extends StatelessWidget {
  final IconData icon;
  final bool isActive;
  final bool hasRedLine;
  final VoidCallback onTap;

  const _ToolbarIcon({
    required this.icon,
    required this.onTap,
    this.isActive = false,
    this.hasRedLine = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                icon,
                color: isActive ? Colors.white : Colors.white70,
                size: 26,
              ),
              // 红色斜线（闪光灯关闭状态）
              if (hasRedLine)
                Positioned.fill(
                  child: CustomPaint(painter: _RedLinePainter()),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// 红色斜线画笔（闪光灯关闭）
class _RedLinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFFF3B30)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(size.width * 0.2, size.height * 0.8),
      Offset(size.width * 0.8, size.height * 0.2),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ─────────────────────────────────────────────────────────────────────────────
// 快门按钮（大白圆）
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
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.transparent,
          border: Border.all(color: Colors.white54, width: 3),
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
                  width: 62,
                  height: 62,
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
// 图库缩略图（蓝色边框）
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
          border: Border.all(color: const Color(0xFF007AFF), width: 2.5),
          color: _kCardBg,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(5.5),
          child: thumb != null
              ? Image.memory(thumb!, fit: BoxFit.cover)
              : const Icon(Icons.photo_outlined, color: Colors.white24, size: 24),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 相机切换按钮（深灰圆角矩形，右下角）
// ─────────────────────────────────────────────────────────────────────────────

class _CameraSwitchButton extends StatelessWidget {
  final VoidCallback onTap;

  const _CameraSwitchButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: _kCardBg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(
          child: Icon(Icons.camera_alt_outlined, color: Colors.white70, size: 24),
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
  final bool isActive;
  final VoidCallback onTap;

  const _TopMenuItem({
    required this.icon,
    required this.label,
    this.isActive = false,
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
              color: isActive
                  ? Colors.white.withAlpha(30)
                  : Colors.white.withAlpha(12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          const SizedBox(height: 5),
          Text(
            label,
            style: const TextStyle(color: _kTextSecondary, fontSize: 10),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 深色面板容器（通用）
// ─────────────────────────────────────────────────────────────────────────────

class _DarkPanel extends StatelessWidget {
  final String title;
  final Widget child;
  final String? rightAction;
  final VoidCallback? onRightAction;

  const _DarkPanel({
    required this.title,
    required this.child,
    this.rightAction,
    this.onRightAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: _kPanelBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 拖拽指示条
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 8, bottom: 2),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 16, 0),
            child: Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: _kTextPrimary,
                  ),
                ),
                const Spacer(),
                if (rightAction != null)
                  GestureDetector(
                    onTap: onRightAction,
                    child: Text(
                      rightAction!,
                      style: const TextStyle(
                        color: _kAccentBlue,
                        fontSize: 15,
                        fontWeight: FontWeight.w400,
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
// 综合配置面板（config 模式）
// 包含：比例 / 色彩配置 / 随机漏光 / 时间水印 / 边框 / 齿孔 / 角度抖动 / 光晕
// ─────────────────────────────────────────────────────────────────────────────

class _ConfigSheet extends StatelessWidget {
  final CameraAppState appState;
  final void Function(String) onSelectFilter;
  final void Function(String) onSelectRatio;
  final void Function(String) onSelectFrame;
  final void Function(String) onSelectWatermark;
  final void Function(String) onSelectLens;

  const _ConfigSheet({
    required this.appState,
    required this.onSelectFilter,
    required this.onSelectRatio,
    required this.onSelectFrame,
    required this.onSelectWatermark,
    required this.onSelectLens,
  });

  @override
  Widget build(BuildContext context) {
    final camera = appState.camera;
    if (camera == null) return const SizedBox.shrink();

    return Container(
      decoration: const BoxDecoration(
        color: _kPanelBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 拖拽指示条
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 8, bottom: 2),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // 可滚动内容
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.65,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 比例
                  if (camera.uiCapabilities.enableRatio) ...[
                    _ConfigSection(
                      title: '比例',
                      child: _RatioRow(
                        ratios: camera.modules.ratios,
                        activeId: appState.activeRatioId,
                        onSelect: onSelectRatio,
                      ),
                    ),
                    _Divider(),
                  ],
                  // 色彩配置（滤镜）
                  if (camera.uiCapabilities.enableFilter) ...[
                    _ConfigSection(
                      title: '色彩配置',
                      child: _FilterRow(
                        filters: camera.modules.filters,
                        activeId: appState.activeFilterId,
                        onSelect: onSelectFilter,
                      ),
                    ),
                    _Divider(),
                  ],
                  // 时间水印
                  if (camera.uiCapabilities.enableWatermark) ...[
                    _ConfigSection(
                      title: '时间水印',
                      child: _WatermarkRow(
                        presets: camera.modules.watermarks.presets,
                        activeId: appState.activeWatermarkId,
                        onSelect: onSelectWatermark,
                      ),
                    ),
                    _Divider(),
                  ],
                  // 边框
                  if (camera.uiCapabilities.enableFrame) ...[
                    _ConfigSection(
                      title: '边框',
                      child: _FrameColorGrid(
                        frames: camera.modules.frames,
                        activeId: appState.activeFrameId,
                        onSelect: onSelectFrame,
                      ),
                    ),
                    _Divider(),
                  ],
                  // 镜头
                  if (camera.uiCapabilities.enableLens) ...[
                    _ConfigSection(
                      title: '镜头',
                      child: _LensRow(
                        lenses: camera.modules.lenses,
                        activeId: appState.activeLensId,
                        onSelect: onSelectLens,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConfigSection extends StatelessWidget {
  final String title;
  final Widget child;

  const _ConfigSection({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(
            title,
            style: const TextStyle(
              color: _kTextPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 0.5,
      margin: const EdgeInsets.symmetric(horizontal: 20),
      color: Colors.white12,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 比例选择行（圆角矩形选项卡，深色）
// ─────────────────────────────────────────────────────────────────────────────

class _RatioRow extends StatelessWidget {
  final List ratios;
  final String? activeId;
  final void Function(String) onSelect;

  const _RatioRow({required this.ratios, required this.activeId, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Row(
        children: [
          for (final r in ratios)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: _RatioChip(
                ratio: r,
                isActive: r.id == activeId,
                onTap: () => onSelect(r.id as String),
              ),
            ),
        ],
      ),
    );
  }
}

class _RatioChip extends StatelessWidget {
  final dynamic ratio;
  final bool isActive;
  final VoidCallback onTap;

  const _RatioChip({required this.ratio, required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final w = (ratio.width as int).toDouble();
    final h = (ratio.height as int).toDouble();
    const maxH = 44.0;
    const maxW = 44.0;
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
      child: Stack(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: isActive ? _kCardBg2 : _kCardBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Container(
                width: rw,
                height: rh,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isActive ? Colors.white : Colors.white38,
                    width: isActive ? 2 : 1.5,
                  ),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
          // 选中勾（右下角）
          if (isActive)
            Positioned(
              bottom: 5,
              right: 5,
              child: Container(
                width: 16,
                height: 16,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                ),
                child: const Icon(Icons.check, color: Colors.black, size: 10),
              ),
            ),
          // 标签
          Positioned(
            bottom: 6,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                ratio.label as String,
                style: TextStyle(
                  fontSize: 10,
                  color: isActive ? Colors.white : _kTextSecondary,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 色彩配置（滤镜）选择行
// ─────────────────────────────────────────────────────────────────────────────

class _FilterRow extends StatelessWidget {
  final List filters;
  final String? activeId;
  final void Function(String) onSelect;

  const _FilterRow({required this.filters, required this.activeId, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Row(
        children: [
          for (final f in filters)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: _FilterChip(
                filter: f,
                isActive: f.id == activeId,
                onTap: () => onSelect(f.id as String),
              ),
            ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final dynamic filter;
  final bool isActive;
  final VoidCallback onTap;

  const _FilterChip({required this.filter, required this.isActive, required this.onTap});

  // 每个滤镜的预览色（模拟胶片色调）
  List<Color> _filterColors(String id) {
    if (id.contains('high_contrast')) {
      return [const Color(0xFF1A1A2E), const Color(0xFF16213E)];
    }
    if (id.contains('faded')) {
      return [const Color(0xFFB8A898), const Color(0xFFC8B8A8)];
    }
    if (id.contains('retro')) {
      return [const Color(0xFF8A6A4A), const Color(0xFFA07850)];
    }
    if (id.contains('warm')) {
      return [const Color(0xFFD4843A), const Color(0xFFE89A50)];
    }
    if (id.contains('cool')) {
      return [const Color(0xFF4A6A9A), const Color(0xFF6080B0)];
    }
    return [const Color(0xFF4A5568), const Color(0xFF5A6578)];
  }

  @override
  Widget build(BuildContext context) {
    final colors = _filterColors(filter.id as String);
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: colors,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
              border: isActive
                  ? Border.all(color: Colors.white, width: 2)
                  : null,
            ),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                child: Text(
                  filter.name as String,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 2,
                ),
              ),
            ),
          ),
          if (isActive)
            Positioned(
              bottom: 5,
              right: 5,
              child: Container(
                width: 16,
                height: 16,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                ),
                child: const Icon(Icons.check, color: Colors.black, size: 10),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 时间水印选择行
// ─────────────────────────────────────────────────────────────────────────────

class _WatermarkRow extends StatelessWidget {
  final List presets;
  final String? activeId;
  final void Function(String) onSelect;

  const _WatermarkRow({required this.presets, required this.activeId, required this.onSelect});

  String _currentDateString() {
    final now = DateTime.now();
    return "${now.month} ${now.day.toString().padLeft(2, '0')} '${now.year.toString().substring(2)}";
  }

  Color? _parseColor(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    try {
      return Color(int.parse('FF${hex.replaceAll('#', '')}', radix: 16));
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 水印预览
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Container(
            width: double.infinity,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Text(
                _currentDateString(),
                style: TextStyle(
                  color: _activeColor(),
                  fontSize: 22,
                  fontFamily: 'monospace',
                  letterSpacing: 2,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
        // 选项行
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Row(
            children: [
              // 无水印
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: _WatermarkChip(
                  id: 'none',
                  isActive: activeId == null || activeId == 'none',
                  onTap: () => onSelect('none'),
                  child: const Icon(Icons.block, color: _kTextSecondary, size: 24),
                ),
              ),
              for (final preset in presets)
                if (!(preset.isNone as bool))
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: _WatermarkChip(
                      id: preset.id as String,
                      isActive: preset.id == activeId,
                      onTap: () => onSelect(preset.id as String),
                      child: Text(
                        _currentDateString(),
                        style: TextStyle(
                          color: _parseColor(preset.color as String?) ?? _kAccentRed,
                          fontSize: 7,
                          fontFamily: 'monospace',
                          letterSpacing: 0.5,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }

  Color _activeColor() {
    if (activeId == null || activeId == 'none') return _kAccentRed;
    for (final p in presets) {
      if (p.id == activeId) {
        final c = _parseColor(p.color as String?);
        if (c != null) return c;
      }
    }
    return _kAccentRed;
  }
}

class _WatermarkChip extends StatelessWidget {
  final String id;
  final bool isActive;
  final VoidCallback onTap;
  final Widget child;

  const _WatermarkChip({
    required this.id,
    required this.isActive,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          Container(
            width: 72,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(8),
              border: isActive
                  ? Border.all(color: Colors.white, width: 2)
                  : Border.all(color: Colors.white12, width: 1),
            ),
            child: Center(child: child),
          ),
          if (isActive)
            Positioned(
              bottom: 3,
              right: 3,
              child: Container(
                width: 14,
                height: 14,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                ),
                child: const Icon(Icons.check, color: Colors.black, size: 9),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 边框颜色网格（5列）
// ─────────────────────────────────────────────────────────────────────────────

class _FrameColorGrid extends StatelessWidget {
  final List frames;
  final String? activeId;
  final void Function(String) onSelect;

  const _FrameColorGrid({required this.frames, required this.activeId, required this.onSelect});

  // 从 frame 名称推断颜色
  Color _frameColor(dynamic frame) {
    final name = (frame.name as String).toLowerCase();
    if (name.contains('white') || name.contains('白')) return Colors.white;
    if (name.contains('black') || name.contains('黑')) return const Color(0xFF1A1A1A);
    if (name.contains('cream') || name.contains('奶')) return const Color(0xFFF5F0E8);
    if (name.contains('pink') || name.contains('粉')) return const Color(0xFFFFB3C6);
    if (name.contains('orange') || name.contains('橙')) return const Color(0xFFFF8C42);
    if (name.contains('yellow') || name.contains('黄')) return const Color(0xFFFFD700);
    if (name.contains('green') || name.contains('绿')) return const Color(0xFF4CAF50);
    if (name.contains('blue') || name.contains('蓝')) return const Color(0xFF2196F3);
    if (name.contains('purple') || name.contains('紫')) return const Color(0xFF9C27B0);
    if (name.contains('gray') || name.contains('grey') || name.contains('灰')) {
      return const Color(0xFF4A4A4A);
    }
    return const Color(0xFFE0D8C8);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 边框颜色标题
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              '边框颜色',
              style: TextStyle(
                color: _kTextSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
          // 网格（5列）
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              // 无边框
              _FrameColorItem(
                isActive: activeId == null || activeId == 'frame_none',
                onTap: () => onSelect('frame_none'),
                child: const Icon(Icons.block, color: _kTextSecondary, size: 24),
              ),
              for (final f in frames)
                _FrameColorItem(
                  isActive: f.id == activeId,
                  onTap: () => onSelect(f.id as String),
                  child: Container(
                    decoration: BoxDecoration(
                      color: _frameColor(f),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FrameColorItem extends StatelessWidget {
  final bool isActive;
  final VoidCallback onTap;
  final Widget child;

  const _FrameColorItem({
    required this.isActive,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: _kCardBg,
              borderRadius: BorderRadius.circular(10),
              border: isActive
                  ? Border.all(color: Colors.white, width: 2)
                  : Border.all(color: Colors.white12, width: 1),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: child,
            ),
          ),
          if (isActive)
            Positioned(
              bottom: 3,
              right: 3,
              child: Container(
                width: 14,
                height: 14,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                ),
                child: const Icon(Icons.check, color: Colors.black, size: 9),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 镜头选择行
// ─────────────────────────────────────────────────────────────────────────────

class _LensRow extends StatelessWidget {
  final List lenses;
  final String? activeId;
  final void Function(String) onSelect;

  const _LensRow({required this.lenses, required this.activeId, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Row(
        children: [
          for (final l in lenses)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: _LensChip(
                lens: l,
                isActive: l.id == activeId,
                onTap: () => onSelect(l.id as String),
              ),
            ),
        ],
      ),
    );
  }
}

class _LensChip extends StatelessWidget {
  final dynamic lens;
  final bool isActive;
  final VoidCallback onTap;

  const _LensChip({required this.lens, required this.isActive, required this.onTap});

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
    final color = _lensColor(lens.id as String);
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
                  color: color.withAlpha(50),
                  border: isActive
                      ? Border.all(color: Colors.white, width: 2)
                      : Border.all(color: color.withAlpha(100), width: 1.5),
                ),
                child: Center(
                  child: Text(
                    (lens.nameEn as String).substring(0, 1).toUpperCase(),
                    style: TextStyle(
                      color: isActive ? Colors.white : color,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              if (isActive)
                Positioned(
                  bottom: 2,
                  right: 2,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                    ),
                    child: const Icon(Icons.check, color: Colors.black, size: 10),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            lens.name as String,
            style: TextStyle(
              fontSize: 11,
              color: isActive ? Colors.white : _kTextSecondary,
              fontWeight: isActive ? FontWeight.w500 : FontWeight.w400,
            ),
          ),
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
      ..color = Colors.white.withAlpha(50)
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
