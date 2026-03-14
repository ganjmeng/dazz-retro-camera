// ─────────────────────────────────────────────────────────────────────────────
// DAZZ Camera Screen — 1:1 复刻截图设计
// ─────────────────────────────────────────────────────────────────────────────
// 设计规格（来自截图）:
// ┌─ 主界面 ──────────────────────────────────────────────────────────────────┐
// │  背景: 纯黑 #000000                                                       │
// │  顶部: 绿点(左) + 相机名(居中) + "..."菜单(右上角，在取景框内)              │
// │  取景框: 圆角矩形，白色1px边框，上方居中"35mm"焦距文字                      │
// │  控制胶囊: 取景框下方 [🌡温度] [数值] [☀曝光] [数值]                       │
// │  工具栏: 5图标 [导入/边框/计时器/闪光灯/翻转]                               │
// │  快门行: [缩略图(蓝边)] [快门大圆] [相机图标]                               │
// │  右下角: 黑色"—"胶囊按钮 → 打开Options全屏弹框                             │
// └──────────────────────────────────────────────────────────────────────────┘

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../models/camera_definition.dart';
import '../../services/camera_service.dart';
import 'camera_notifier.dart';
import 'preview_renderer.dart';
import '../gallery/gallery_screen.dart';
import 'camera_config_sheet.dart';

// ─── 颜色常量 ─────────────────────────────────────────────────────────────────
const _kBlack = Color(0xFF000000);
const _kDarkGray = Color(0xFF1C1C1E);
const _kLightGray = Color(0xFF3A3A3C);
const _kWhite = Colors.white;
const _kBlue = Color(0xFF007AFF);
const _kRed = Color(0xFFFF3B30);

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen>
    with TickerProviderStateMixin {

  Uint8List? _latestThumb;
  AssetEntity? _latestAsset; // 最新照片 entity（长按直接打开详情用）
  int _timerCountdown = 0;
  Timer? _countdownTimer;

  // 曝光拖拽
  double _exposureDragStart = 0;
  double _exposureAtDragStart = 0;
  // 温度拖拽
  double _tempDragStart = 0;
  double _tempAtDragStart = 0;

  // Options 弹框控制器
  late AnimationController _optionsAnim;
  late Animation<Offset> _optionsSlide;

  @override
  void initState() {
    super.initState();
    _optionsAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _optionsSlide = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _optionsAnim, curve: Curves.easeOutCubic));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(cameraAppProvider.notifier).initialize();
      _loadLatestThumb();
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _optionsAnim.dispose();
    super.dispose();
  }

  Future<void> _loadLatestThumb() async {
    final perm = await PhotoManager.requestPermissionExtend();
    if (!perm.isAuth) return;
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      filterOption: FilterOptionGroup(
        orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
      ),
    );
    if (albums.isEmpty) return;
    final assets = await albums.first.getAssetListRange(start: 0, end: 1);
    if (assets.isNotEmpty && mounted) {
      final thumb = await assets.first.thumbnailDataWithSize(
        const ThumbnailSize(120, 120),
      );
      if (mounted) setState(() {
        _latestThumb = thumb;
        _latestAsset = assets.first;
      });
    }
  }

  Future<void> _handleShutter() async {
    final st = ref.read(cameraAppProvider);
    final timer = st.timerSeconds;
    if (timer > 0) {
      setState(() => _timerCountdown = timer);
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        setState(() => _timerCountdown--);
        if (_timerCountdown <= 0) {
          t.cancel();
          _doTakePhoto();
        }
      });
    } else {
      _doTakePhoto();
    }
  }

  Future<void> _doTakePhoto() async {
    final path = await ref.read(cameraAppProvider.notifier).takePhoto();
    if (path != null && mounted) {
      _loadLatestThumb();
    }
  }

  void _openOptions() {
    ref.read(cameraAppProvider.notifier).closeAllPanels();
    _optionsAnim.forward();
  }

  void _closeOptions() {
    _optionsAnim.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(cameraAppProvider);
    final camSvc = ref.watch(cameraServiceProvider);
    final mq = MediaQuery.of(context);
    // 底部面板高度：工具栏(60) + 快门行(80) + 间距(40) + 底部安全区 ≈ 220px
    const kBottomPanelH = 220.0;
    // 取景框区域高度 = 屏幕高度 - 状态栏 - 底部面板
    final topAreaH = mq.size.height - mq.padding.top - kBottomPanelH;

    return Scaffold(
      backgroundColor: _kBlack,
      body: Stack(
        children: [
          // ── 主内容（两段式布局）──
          Column(
            children: [
              // 上段：取景框区域（黑色背景）
              SizedBox(
                height: mq.padding.top + topAreaH,
                child: SafeArea(
                  bottom: false,
                  child: _buildViewfinderArea(st, camSvc, topAreaH, mq.size.width),
                ),
              ),
              // 下段：底部面板（深灰色圆角）
              Expanded(
                child: _buildBottomPanel(st),
              ),
            ],
          ),
          // ── 右上角菜单弹框 ──
          if (st.showTopMenu) _buildTopMenuOverlay(st),
          // ── 倒计时遮罩 ──
          if (_timerCountdown > 0) _buildCountdownOverlay(),
          // ── 拍摄闪光 ──
          if (st.showCaptureFlash)
            Container(color: Colors.white.withAlpha(200)),
          // ── Options 全屏弹框 ──
          AnimatedBuilder(
            animation: _optionsAnim,
            builder: (ctx, child) {
              final isHidden = _optionsAnim.value == 0;
              return IgnorePointer(
                ignoring: isHidden,
                child: SlideTransition(
                  position: _optionsSlide,
                  child: child,
                ),
              );
            },
            child: _OptionsSheet(
              onClose: _closeOptions,
            ),
          ),
        ],
      ),
    );
  }

  // ── 取景框区域（上段）──────────────────────────────────────────────────────
  // 布局：黑色背景，右上角 "•••" 按钮，取景框（含焦距文字+预览+控制胶囊）
  Widget _buildViewfinderArea(CameraAppState st, CameraState camSvc, double areaH, double screenW) {
    // 截图精确复刻：预览全屏铺满，无边框，无圆角，无焦距文字
    // 右上角 "•••" 按钮浮在预览上方黑色区域
    return Stack(
      fit: StackFit.expand,
      children: [
        // 预览全屏铺满（无边框无圆角）
        Positioned.fill(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 相机预览
              _buildPreview(st, camSvc),
              // 三等分网格线
              if (st.gridEnabled) _buildGrid(),
              // 取景框内底部：控制胶囊（3个独立圆形按钮）
              Positioned(
                bottom: 20,
                left: 0,
                right: 0,
                child: Center(child: _buildControlCapsule(st)),
              ),
              // 拍摄中指示
              if (st.isTakingPhoto)
                Container(
                  color: Colors.black.withAlpha(80),
                  child: const Center(
                    child: CircularProgressIndicator(color: _kWhite, strokeWidth: 2),
                  ),
                ),
            ],
          ),
        ),
        // 右上角 "•••" 按钮（浮在预览上方，在状态栏下方黑色区域）
        Positioned(
          top: 8,
          right: 16,
          child: GestureDetector(
            onTap: () => ref.read(cameraAppProvider.notifier).toggleTopMenu(),
            child: const SizedBox(
              width: 44,
              height: 44,
              child: Center(
                child: Text(
                  '•••',
                  style: TextStyle(
                    color: _kWhite,
                    fontSize: 18,
                    letterSpacing: 4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
  // ── 底部面板（下段）──────────────────────────────────────────────────────────
  // 布局：深灰色圆角面板，[照片/视频 tab] + [样图/管理] → 相机列表 → 工具栏 → 快门行
  Widget _buildBottomPanel(CameraAppState st) {
    // 截图精确复刻：纯黑背景，无圆角，无 Tab 行，无相机列表
    return Container(
      color: _kBlack,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 16),
          // 工具图标行（4个图标+文字标签）
          _buildToolbar(st),
          const SizedBox(height: 16),
          // 快门行
          _buildShutterRow(st),
          // 底部安全区域
          SizedBox(height: MediaQuery.of(context).padding.bottom + 4),
        ],
      ),
    );
  }

  // ── Tab 行 ─────────────────────────────────────────────────────────────────
  Widget _buildTabRow(CameraAppState st) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          // 照片 tab（激活）
          GestureDetector(
            onTap: () {},
            child: const Text(
              '照片',
              style: TextStyle(
                color: _kWhite,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 24),
          // 视频 tab
          GestureDetector(
            onTap: () {},
            child: const Text(
              '视频',
              style: TextStyle(
                color: Colors.grey,
                fontSize: 17,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
          const Spacer(),
          // 样图按钮
          GestureDetector(
            onTap: () {},
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF3A3A3C),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.image_outlined, color: _kWhite, size: 14),
                  SizedBox(width: 4),
                  Text('样图', style: TextStyle(color: _kWhite, fontSize: 13)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 管理按钮
          GestureDetector(
            onTap: () {},
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF3A3A3C),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.photo_camera_outlined, color: _kWhite, size: 14),
                  SizedBox(width: 4),
                  Text('管理', style: TextStyle(color: _kWhite, fontSize: 13)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 相机列表（横向滚动）──────────────────────────────────────────────────────
  Widget _buildCameraList(CameraAppState st) {
    return SizedBox(
      height: 88,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: _kPhotoCameras.map((cam) {
          final isActive = st.activeCameraId == cam.id;
          return GestureDetector(
            onTap: () => ref.read(cameraAppProvider.notifier).switchToCamera(cam.id),
            child: Container(
              width: 76,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2C2C2E),
                      borderRadius: BorderRadius.circular(14),
                      border: isActive
                          ? Border.all(color: _kWhite, width: 2)
                          : null,
                    ),
                    child: Center(
                      child: Text(cam.emoji, style: const TextStyle(fontSize: 30)),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        cam.name,
                        style: TextStyle(
                          color: isActive ? _kWhite : Colors.grey,
                          fontSize: 10,
                          fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      if (cam.hasR)
                        const Text(' R', style: TextStyle(color: _kRed, fontSize: 10, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildPreview(CameraAppState st, CameraState camSvc) {
    if (camSvc.isLoading) {
      return Container(
        color: Colors.black,
        child: const Center(child: CircularProgressIndicator(color: _kWhite, strokeWidth: 2)),
      );
    }
    if (camSvc.error != null) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Text(
            camSvc.error!,
            style: const TextStyle(color: Colors.red, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (camSvc.textureId != null && st.renderParams != null) {
      return PreviewFilterWidget(
        textureId: camSvc.textureId!,
        params: st.renderParams!,
        aspectRatio: st.previewAspectRatio,
      );
    }
    return Container(color: Colors.black);
  }

  Widget _buildGrid() {
    return CustomPaint(
      painter: _GridPainter(),
    );
  }

  // ── 控制胶囊 ──────────────────────────────────────────────────────────────
  // 截图精确复刻：深色半透明背景，白色文字，[🌡] [x1] [☀ 0.0]
  Widget _buildControlCapsule(CameraAppState st) {
    // 截图精确复刻：3个独立圆形/胶囊按钮 [🌡] [x1] [☀ 0.0]
    final lens = st.activeLens;
    final zoomFactor = lens?.zoomFactor ?? 1.0;
    final zoomLabel = zoomFactor == zoomFactor.roundToDouble()
        ? 'x${zoomFactor.toInt()}'
        : 'x${zoomFactor.toStringAsFixed(1)}';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 温度按钮（圆形，左滑动调整）
        GestureDetector(
          onHorizontalDragStart: (d) {
            _tempDragStart = d.localPosition.dx;
            _tempAtDragStart = st.temperatureOffset;
          },
          onHorizontalDragUpdate: (d) {
            final delta = d.localPosition.dx - _tempDragStart;
            final newTemp = (_tempAtDragStart + delta * 0.8).clamp(-100.0, 100.0);
            ref.read(cameraAppProvider.notifier).setTemperature(newTemp);
          },
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withAlpha(160),
            ),
            child: const Center(
              child: Icon(Icons.thermostat_outlined, size: 20, color: _kWhite),
            ),
          ),
        ),
        const SizedBox(width: 10),
        // 倍率按钮（胶囊形，中间）
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            color: Colors.black.withAlpha(160),
          ),
          child: Center(
            child: Text(
              zoomLabel,
              style: const TextStyle(
                color: _kWhite,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        // 曝光按钮（胶囊形，上下滑动调整）
        GestureDetector(
          onVerticalDragStart: (d) {
            _exposureDragStart = d.localPosition.dy;
            _exposureAtDragStart = st.exposureValue;
          },
          onVerticalDragUpdate: (d) {
            final delta = d.localPosition.dy - _exposureDragStart;
            final newExp = (_exposureAtDragStart - delta * 0.02).clamp(-2.0, 2.0);
            ref.read(cameraAppProvider.notifier).setExposure(newExp);
          },
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              color: Colors.black.withAlpha(160),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.wb_sunny_outlined, size: 16, color: _kWhite),
                const SizedBox(width: 6),
                Text(
                  st.exposureValue == 0 ? '0.0' : st.exposureValue.toStringAsFixed(1),
                  style: const TextStyle(
                    color: _kWhite,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
  // ── 工具栏（5个图标）────────────────────────────────────────────────────────
  Widget _buildToolbar(CameraAppState st) {
    return SizedBox(
      height: 60,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // 1. 导入图片
          _ToolbarBtn(
            icon: Icons.add_photo_alternate_outlined,
            label: '导入图片',
            onTap: () {},
          ),
          // 2. 倒计时
          _ToolbarBtn(
            icon: Icons.timer_outlined,
            label: '倒计时',
            badge: st.timerSeconds > 0 ? '${st.timerSeconds}s' : null,
            onTap: () => ref.read(cameraAppProvider.notifier).cycleTimer(),
          ),
          // 3. 闪光灯
          _FlashBtn(
            mode: st.flashMode,
            label: '闪光灯',
            onTap: () => ref.read(cameraAppProvider.notifier).cycleFlash(),
          ),
          // 4. 前置/后置切换
          _ToolbarBtn(
            icon: Icons.flip_camera_ios_outlined,
            label: '后置',
            onTap: () => ref.read(cameraAppProvider.notifier).flipCamera(),
          ),
        ],
      ),
    );
  }

  // ── 快门行 ──────────────────────────────────────────────────────────────────
  Widget _buildShutterRow(CameraAppState st) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 左侧: 图库缩略图（单击→相册列表，长按→直接打开最新相片详情）
          GestureDetector(
            onTap: _openGallery,
            onLongPress: _openLatestPhotoDetail,
            child: Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: _kDarkGray,
              ),
              child: _latestThumb != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(_latestThumb!, fit: BoxFit.cover),
                    )
                  : const Icon(Icons.photo_outlined, color: Colors.grey, size: 28),
            ),
          ),
          // 中间: 快门按鈕（大圆，白色，外圈深色）
          GestureDetector(
            onTap: st.isTakingPhoto ? null : _handleShutter,
            child: Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.transparent,
                border: Border.all(color: _kWhite, width: 3),
              ),
              child: Center(
                child: Container(
                  width: 62,
                  height: 62,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: _kWhite,
                  ),
                ),
              ),
            ),
          ),
          // 右侧: 相机切换图标（虚线圆圈背景，点击打开相机配置菜单）
          GestureDetector(
            onTap: () => showCameraConfigSheet(context),
            child: SizedBox(
              width: 70,
              height: 70,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 虚线圆圈背景
                  CustomPaint(
                    size: const Size(70, 70),
                    painter: _DashedCirclePainter(),
                  ),
                  // 复古相机图标
                  const Icon(Icons.photo_camera_outlined, color: _kWhite, size: 32),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 右上角菜单弹框（"..."展开）──────────────────────────────────────────────
  Widget _buildTopMenuOverlay(CameraAppState st) {
    final mq = MediaQuery.of(context);
    // 菜单覆盖在取景框内部上方（截图中菜单从取景框顶部开始）
    final menuTop = mq.padding.top + 50.0; // 截图：菜单从预览顶部展开
    return GestureDetector(
      onTap: () => ref.read(cameraAppProvider.notifier).toggleTopMenu(),
      child: Container(
        color: Colors.transparent,
        child: Stack(
          children: [
            Positioned(
              top: menuTop,
              left: 16,
              right: 16,
              child: GestureDetector(
                onTap: () {}, // 阻止穿透
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: const BoxDecoration(
                    color: Color(0xCC000000),
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(14),
                      topRight: Radius.circular(14),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 第一行: 4个图标
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _MenuGridBtn(
                            icon: Icons.grid_off,
                            label: '网格线关闭',
                            isActive: st.gridEnabled,
                            onTap: () => ref.read(cameraAppProvider.notifier).toggleGrid(),
                          ),
                          _MenuGridBtn(
                            icon: Icons.hd_outlined,
                            label: '清晰度',
                            onTap: () {},
                          ),
                          _MenuGridBtn(
                            icon: Icons.crop_square_outlined,
                            label: '小框模式开启',
                            isActive: st.smallFrameMode,
                            onTap: () => ref.read(cameraAppProvider.notifier).toggleSmallFrame(),
                          ),
                          _MenuGridBtn(
                            icon: Icons.exposure,
                            label: '双重曝光关闭',
                            onTap: () {},
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      // 第二行: 2个图标 + 2个占位穿位
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _MenuGridBtn(
                            icon: Icons.burst_mode_outlined,
                            label: '连拍关闭',
                            onTap: () {},
                          ),
                          _MenuGridBtn(
                            icon: Icons.settings_outlined,
                            label: '设置',
                            onTap: () {},
                          ),
                          const SizedBox(width: 60),
                          const SizedBox(width: 60),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 单击：打开相册列表页 ─────────────────────────────────────────────────
  void _openGallery() {
    HapticFeedback.selectionClick();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const GalleryScreen(),
      ),
    );
  }

  // ── 长按：直接打开最新相片详情，返回后回到相册列表 ─────────────────────────
  void _openLatestPhotoDetail() {
    if (_latestAsset == null) {
      // 没有照片时，单纯打开相册
      _openGallery();
      return;
    }
    HapticFeedback.mediumImpact();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GalleryScreen(initialAsset: _latestAsset),
      ),
    );
  }

  // ── 保留旧方法名以防其他地方引用 ─────────────────────────────────────────
  void _showGallerySheet() => _openGallery();

  // ── 倒计时遮罩 ──────────────────────────────────────────────────────────────
  Widget _buildCountdownOverlay() {
    return Container(
      color: Colors.black.withAlpha(180),
      child: Center(
        child: Text(
          '$_timerCountdown',
          style: const TextStyle(
            color: _kWhite,
            fontSize: 96,
            fontWeight: FontWeight.w200,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Options 全屏弹框（从底部滑入）
// ─────────────────────────────────────────────────────────────────────────────
class _OptionsSheet extends ConsumerWidget {
  final VoidCallback onClose;

  const _OptionsSheet({required this.onClose});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(cameraAppProvider);
    final camera = st.camera;

    return Container(
      color: _kBlack,
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 16),
            // Dazz Pro 横幅
            _buildProBanner(),
            const SizedBox(height: 24),
            // 相机列表（Video + Photo 两行）
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildCameraSection(context, ref, st, 'Video', _kVideoCameras),
                    const SizedBox(height: 8),
                    _buildCameraSection(context, ref, st, 'Photo', _kPhotoCameras),
                    const SizedBox(height: 16),
                    // Option 行
                    _buildOptionRow(context, ref, st, camera),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
            // 关闭按钮
            GestureDetector(
              onTap: onClose,
              child: Container(
                width: 48,
                height: 48,
                margin: const EdgeInsets.only(bottom: 8),
                decoration: const BoxDecoration(
                  color: _kDarkGray,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.keyboard_arrow_down, color: _kWhite, size: 28),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildProBanner() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF1A6FE0), Color(0xFF6B3FA0), Color(0xFFE03030)],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            // Dazz Logo
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(30),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(
                child: Text('D', style: TextStyle(color: _kWhite, fontSize: 20, fontWeight: FontWeight.w900)),
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Dazz Pro', style: TextStyle(color: _kWhite, fontSize: 17, fontWeight: FontWeight.w700)),
                  Text('解锁所有相机和配件。', style: TextStyle(color: Colors.white70, fontSize: 13)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: _kWhite, size: 22),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraSection(BuildContext context, WidgetRef ref, CameraAppState st, String label, List<_CameraItem> cameras) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _kBlue,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(label, style: const TextStyle(color: _kWhite, fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ),
        SizedBox(
          height: 110,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: cameras.length,
            itemBuilder: (ctx, i) {
              final cam = cameras[i];
              final isActive = st.activeCameraId == cam.id;
              return GestureDetector(
                onTap: () {
                  ref.read(cameraAppProvider.notifier).switchToCamera(cam.id);
                  onClose();
                },
                child: Container(
                  width: 80,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  child: Column(
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: _kDarkGray,
                          borderRadius: BorderRadius.circular(14),
                          border: isActive
                              ? Border.all(color: _kWhite, width: 2)
                              : null,
                        ),
                        child: Center(
                          child: Text(cam.emoji, style: const TextStyle(fontSize: 36)),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            cam.name,
                            style: TextStyle(
                              color: isActive ? _kWhite : Colors.grey,
                              fontSize: 11,
                              fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                          if (cam.hasR)
                            const Text(' R', style: TextStyle(color: _kRed, fontSize: 11, fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildOptionRow(BuildContext context, WidgetRef ref, CameraAppState st, CameraDefinition? camera) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _kBlue,
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text('Option', style: TextStyle(color: _kWhite, fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ),
        SizedBox(
          height: 72,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              // 漏光/随机效果
              _OptionIconBtn(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFFCC2200),
                  ),
                ),
                label: '漏光',
                onTap: () {},
              ),
              // 颗粒
              _OptionIconBtn(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [Color(0xFF9B59B6), Color(0xFF1A1A2E)],
                    ),
                  ),
                ),
                label: '颗粒',
                onTap: () {},
              ),
              // 暗角
              _OptionIconBtn(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [Color(0xFF333333), Color(0xFF000000)],
                    ),
                  ),
                ),
                label: '暗角',
                onTap: () {},
              ),
              // 边框
              _OptionIconBtn(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _kDarkGray,
                    border: Border.all(color: Colors.white54, width: 2),
                  ),
                  child: const Icon(Icons.crop_square, color: _kWhite, size: 22),
                ),
                label: '边框',
                onTap: () {
                  onClose();
                  // 打开边框面板
                  ref.read(cameraAppProvider.notifier).togglePanel('frame');
                },
              ),
              // 色彩
              _OptionIconBtn(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(shape: BoxShape.circle),
                  child: CustomPaint(painter: _ColorWheelPainter()),
                ),
                label: '色彩',
                onTap: () {
                  onClose();
                  ref.read(cameraAppProvider.notifier).togglePanel('filter');
                },
              ),
              // 计时器
              _OptionIconBtn(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _kDarkGray,
                  ),
                  child: Center(
                    child: Text(
                      st.timerSeconds > 0 ? '${st.timerSeconds}' : '10',
                      style: const TextStyle(color: _kWhite, fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                label: '计时',
                onTap: () => ref.read(cameraAppProvider.notifier).cycleTimer(),
              ),
              // 比例
              _OptionIconBtn(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _kDarkGray,
                  ),
                  child: Center(
                    child: Text(
                      camera?.ratioById(st.activeRatioId)?.label ?? '3:4',
                      style: const TextStyle(color: _kWhite, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                label: '比例',
                onTap: () {
                  onClose();
                  ref.read(cameraAppProvider.notifier).togglePanel('ratio');
                },
              ),
              // 水印
              _OptionIconBtn(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _kDarkGray,
                  ),
                  child: const Icon(Icons.access_time, color: _kWhite, size: 22),
                ),
                label: '水印',
                onTap: () {
                  onClose();
                  ref.read(cameraAppProvider.notifier).togglePanel('watermark');
                },
              ),
            ],
          ),
        ),
        // 子面板（比例/滤镜/边框/水印）
        if (st.activePanel != null && camera != null)
          _buildSubPanel(context, ref, st, camera),
      ],
    );
  }

  Widget _buildSubPanel(BuildContext context, WidgetRef ref, CameraAppState st, CameraDefinition camera) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _kDarkGray,
        borderRadius: BorderRadius.circular(16),
      ),
      child: switch (st.activePanel) {
        'ratio' => _RatioRow(
            ratios: camera.modules.ratios,
            activeId: st.activeRatioId,
            onSelect: (id) => ref.read(cameraAppProvider.notifier).selectRatio(id),
          ),
        'filter' => _FilterRow(
            filters: camera.modules.filters,
            activeId: st.activeFilterId,
            onSelect: (id) => ref.read(cameraAppProvider.notifier).selectFilter(id),
          ),
        'frame' => _FrameGrid(
            frames: camera.modules.frames,
            activeId: st.activeFrameId,
            onSelect: (id) => ref.read(cameraAppProvider.notifier).selectFrame(id),
          ),
        'watermark' => _WatermarkRow(
            presets: camera.modules.watermarks.presets,
            activeId: st.activeWatermarkId,
            onSelect: (id) => ref.read(cameraAppProvider.notifier).selectWatermark(id),
          ),
        _ => const SizedBox.shrink(),
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 相册弹框（左下角缩略图点击）
// ─────────────────────────────────────────────────────────────────────────────
class _GallerySheet extends StatefulWidget {
  const _GallerySheet();
  @override
  State<_GallerySheet> createState() => _GallerySheetState();
}
class _GallerySheetState extends State<_GallerySheet> {
  List<AssetEntity> _allPhotos = [];
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _loadPhotos();
  }
  Future<void> _loadPhotos() async {
    final perm = await PhotoManager.requestPermissionExtend();
    if (!perm.isAuth) { if (mounted) setState(() => _loading = false); return; }
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      filterOption: FilterOptionGroup(
        orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
      ),
    );
    if (albums.isNotEmpty) {
      final assets = await albums.first.getAssetListRange(start: 0, end: 200);
      if (mounted) setState(() { _allPhotos = assets; _loading = false; });
    } else {
      if (mounted) setState(() => _loading = false);
    }
  }
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 半透明黑色背景
        GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Container(color: Colors.black54),
        ),
        // 居中弹框
        Center(
          child: Container(
            width: MediaQuery.of(context).size.width * 0.85,
            padding: const EdgeInsets.only(top: 0, bottom: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E).withAlpha(240),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 顶部按鈕行
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: const BoxDecoration(
                          color: Color(0xFF3A3A3C),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.settings_outlined, color: _kWhite, size: 22),
                      ),
                      Container(
                        width: 40,
                        height: 40,
                        decoration: const BoxDecoration(
                          color: Color(0xFF3A3A3C),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.check_box_outlined, color: _kWhite, size: 22),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12, height: 1),
                GestureDetector(
                  onTap: () {
                    Navigator.of(context).pop();
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => _PhotoGridPage(photos: _allPhotos),
                    ));
                  },
                  child: _GalleryItem(
                    icon: Icons.grid_view,
                    label: '全部照片',
                    count: _loading ? 0 : _allPhotos.length,
                  ),
                ),
                _GalleryItem(icon: Icons.favorite_outline, label: '喜好项目', count: 0),
                _GalleryItem(icon: Icons.video_file_outlined, label: '底片', count: 0),
              ],
            ),
          ),
        ),
        // 左下角相机按鈕
        Positioned(
          bottom: 40,
          left: 24,
          child: GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Container(
              width: 52,
              height: 52,
              decoration: const BoxDecoration(
                color: Color(0xFF3A3A3C),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.photo_camera_outlined, color: _kWhite, size: 26),
            ),
          ),
        ),
      ],
    );
  }
}
// ─────────────────────────────────────────────────────────────────────────────
// Asset Thumbnail Widget
// ─────────────────────────────────────────────────────────────────────────────
class _AssetThumb extends StatefulWidget {
  final AssetEntity asset;
  const _AssetThumb({required this.asset});
  @override
  State<_AssetThumb> createState() => _AssetThumbState();
}
class _AssetThumbState extends State<_AssetThumb> {
  Uint8List? _thumb;
  @override
  void initState() {
    super.initState();
    _load();
  }
  Future<void> _load() async {
    final data = await widget.asset.thumbnailDataWithSize(const ThumbnailSize(300, 300));
    if (mounted && data != null) setState(() => _thumb = data);
  }
  @override
  Widget build(BuildContext context) {
    if (_thumb == null) {
      return Container(color: const Color(0xFF1C1C1E));
    }
    return Image.memory(_thumb!, fit: BoxFit.cover);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Photo Grid Page
// ─────────────────────────────────────────────────────────────────────────────
class _PhotoGridPage extends StatelessWidget {
  final List<AssetEntity> photos;
  const _PhotoGridPage({required this.photos});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBlack,
      appBar: AppBar(
        backgroundColor: _kBlack,
        foregroundColor: _kWhite,
        title: const Text('全部照片', style: TextStyle(color: _kWhite, fontSize: 17, fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: _kWhite),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: photos.isEmpty
          ? const Center(child: Text('暂无照片', style: TextStyle(color: Colors.white54)))
          : GridView.builder(
              padding: const EdgeInsets.all(2),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 2,
                mainAxisSpacing: 2,
              ),
              itemCount: photos.length,
              itemBuilder: (ctx, i) {
                return GestureDetector(
                  onTap: () {
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => _PhotoDetailPage(asset: photos[i]),
                    ));
                  },
                  child: _AssetThumb(asset: photos[i]),
                );
              },
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Photo Detail Page
// ─────────────────────────────────────────────────────────────────────────────
class _PhotoDetailPage extends StatefulWidget {
  final AssetEntity asset;
  const _PhotoDetailPage({required this.asset});
  @override
  State<_PhotoDetailPage> createState() => _PhotoDetailPageState();
}
class _PhotoDetailPageState extends State<_PhotoDetailPage> {
  Uint8List? _fullData;
  @override
  void initState() {
    super.initState();
    _load();
  }
  Future<void> _load() async {
    final data = await widget.asset.originBytes;
    if (mounted && data != null) setState(() => _fullData = data);
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: _fullData == null
                ? const CircularProgressIndicator(color: Colors.white)
                : Image.memory(_fullData!, fit: BoxFit.contain),
          ),
          // Bottom toolbar
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              color: const Color(0xFF1C1C1E),
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).padding.bottom + 8,
                top: 12,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    icon: const Icon(Icons.ios_share, color: _kWhite),
                    onPressed: () {},
                  ),
                  IconButton(
                    icon: const Icon(Icons.nightlight_round, color: _kWhite),
                    onPressed: () {},
                  ),
                  IconButton(
                    icon: const Icon(Icons.movie_outlined, color: _kWhite),
                    onPressed: () {},
                  ),
                  IconButton(
                    icon: const Icon(Icons.favorite_border, color: _kWhite),
                    onPressed: () {},
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: _kWhite),
                    onPressed: () async {
                      await PhotoManager.editor.deleteWithIds([widget.asset.id]);
                      if (context.mounted) Navigator.of(context).pop();
                    },
                  ),
                ],
              ),
            ),
          ),
          // Top back button
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 16,
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  '#${widget.asset.title ?? "Photo"}',
                  style: const TextStyle(color: _kWhite, fontSize: 13),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GalleryItem extends StatelessWidget {
  final IconData? icon;
  final Widget? customIcon;
  final String label;
  final int count;

  const _GalleryItem({this.icon, this.customIcon, required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          customIcon ?? Icon(icon, color: Colors.white70, size: 24),
          const SizedBox(width: 16),
          Expanded(
            child: Text(label, style: const TextStyle(color: _kWhite, fontSize: 16)),
          ),
          Text('$count', style: const TextStyle(color: Colors.grey, fontSize: 16)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 子面板组件
// ─────────────────────────────────────────────────────────────────────────────

// 比例选择
class _RatioRow extends StatelessWidget {
  final List<RatioDefinition> ratios;
  final String? activeId;
  final ValueChanged<String> onSelect;

  const _RatioRow({required this.ratios, this.activeId, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: ratios.length,
        itemBuilder: (ctx, i) {
          final r = ratios[i];
          final isActive = r.id == activeId;
          return GestureDetector(
            onTap: () => onSelect(r.id),
            child: Container(
              margin: const EdgeInsets.only(right: 12),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: isActive ? _kWhite : _kLightGray,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Text(
                r.label,
                style: TextStyle(
                  color: isActive ? _kBlack : _kWhite,
                  fontSize: 14,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// 滤镜选择
class _FilterRow extends StatelessWidget {
  final List<FilterDefinition> filters;
  final String? activeId;
  final ValueChanged<String> onSelect;

  const _FilterRow({required this.filters, this.activeId, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 72,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: filters.length,
        itemBuilder: (ctx, i) {
          final f = filters[i];
          final isActive = f.id == activeId;
          return GestureDetector(
            onTap: () => onSelect(f.id),
            child: Container(
              width: 60,
              margin: const EdgeInsets.only(right: 10),
              child: Column(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: _kLightGray,
                      borderRadius: BorderRadius.circular(8),
                      border: isActive ? Border.all(color: _kBlue, width: 2) : null,
                    ),
                    child: const Icon(Icons.filter_vintage_outlined, color: Colors.white54, size: 24),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    f.nameEn,
                    style: TextStyle(
                      color: isActive ? _kWhite : Colors.grey,
                      fontSize: 10,
                    ),
                    maxLines: 1,
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
  }
}

// 边框选择
class _FrameGrid extends StatelessWidget {
  final List<FrameDefinition> frames;
  final String? activeId;
  final ValueChanged<String> onSelect;

  const _FrameGrid({required this.frames, this.activeId, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    // 加上"无边框"选项
    final allFrames = [
      const _FrameOption(id: 'none', name: '无', color: Colors.transparent),
      ...frames.map((f) {
        Color c = const Color(0xFFF5F2EA);
        try {
          final hex = f.backgroundColor.replaceAll('#', '');
          c = Color(int.parse('FF$hex', radix: 16));
        } catch (_) {}
        return _FrameOption(id: f.id, name: f.nameEn, color: c);
      }),
    ];

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: allFrames.map((opt) {
        final isActive = opt.id == (activeId ?? 'none');
        return GestureDetector(
          onTap: () => onSelect(opt.id),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: opt.color == Colors.transparent ? _kLightGray : opt.color,
                  border: isActive
                      ? Border.all(color: _kBlue, width: 2.5)
                      : Border.all(color: Colors.white24, width: 1),
                ),
                child: opt.color == Colors.transparent
                    ? const Icon(Icons.block, color: Colors.white54, size: 20)
                    : isActive
                        ? const Icon(Icons.check, color: _kBlue, size: 20)
                        : null,
              ),
              const SizedBox(height: 4),
              Text(opt.name, style: const TextStyle(color: Colors.grey, fontSize: 10)),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _FrameOption {
  final String id;
  final String name;
  final Color color;
  const _FrameOption({required this.id, required this.name, required this.color});
}

// 水印选择
class _WatermarkRow extends StatelessWidget {
  final List<WatermarkPreset> presets;
  final String? activeId;
  final ValueChanged<String> onSelect;

  const _WatermarkRow({required this.presets, this.activeId, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 72,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: presets.length,
        itemBuilder: (ctx, i) {
          final wm = presets[i];
          final isActive = wm.id == activeId;
          Color dotColor = const Color(0xFFFF8C00);
          if (wm.color != null && wm.color!.isNotEmpty) {
            try {
              final hex = wm.color!.replaceAll('#', '');
              dotColor = Color(int.parse('FF$hex', radix: 16));
            } catch (_) {}
          }
          return GestureDetector(
            onTap: () => onSelect(wm.id),
            child: Container(
              width: 64,
              margin: const EdgeInsets.only(right: 10),
              child: Column(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: _kLightGray,
                      borderRadius: BorderRadius.circular(8),
                      border: isActive ? Border.all(color: _kBlue, width: 2) : null,
                    ),
                    child: Center(
                          child: wm.isNone
                              ? const Icon(Icons.block, color: Colors.white54, size: 20)
                              : Container(
                                  width: 16,
                                  height: 16,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: dotColor,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        wm.name,
                    style: TextStyle(
                      color: isActive ? _kWhite : Colors.grey,
                      fontSize: 10,
                    ),
                    maxLines: 1,
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
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 小组件
// ─────────────────────────────────────────────────────────────────────────────

class _ToolbarBtn extends StatelessWidget {
  final IconData icon;
  final String? label;   // 文字标签（显示在图标下方）
  final String? badge;   // 小徽章（显示在图标右下角）
  final VoidCallback onTap;

  const _ToolbarBtn({required this.icon, this.label, this.badge, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(icon, color: _kWhite, size: 26),
                if (badge != null)
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                      decoration: BoxDecoration(
                        color: _kBlue,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(badge!, style: const TextStyle(color: _kWhite, fontSize: 8, fontWeight: FontWeight.w700)),
                    ),
                  ),
              ],
            ),
          ),
          if (label != null) ...[  
            const SizedBox(height: 4),
            Text(label!, style: const TextStyle(color: Colors.white70, fontSize: 10)),
          ],
        ],
      ),
    );
  }
}

class _FlashBtn extends StatelessWidget {
  final String mode;
  final String? label;
  final VoidCallback onTap;

  const _FlashBtn({required this.mode, this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isOff = mode == 'off';
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  Icons.flash_on,
                  color: isOff ? _kWhite : _kRed,
                  size: 26,
                ),
                if (isOff)
                  CustomPaint(
                    size: const Size(26, 26),
                    painter: _StrikethroughPainter(),
                  ),
              ],
            ),
          ),
          if (label != null) ...[  
            const SizedBox(height: 4),
            Text(label!, style: const TextStyle(color: Colors.white70, fontSize: 10)),
          ],
        ],
      ),
    );
  }
}

class _MenuGridBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _MenuGridBtn({
    required this.icon,
    required this.label,
    this.isActive = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 60,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: isActive ? Colors.white24 : const Color(0xFF3A3A3C),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: _kWhite, size: 22),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 10),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionIconBtn extends StatelessWidget {
  final Widget child;
  final String label;
  final VoidCallback onTap;

  const _OptionIconBtn({required this.child, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 64,
        margin: const EdgeInsets.only(right: 8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            child,
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(color: Colors.grey, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 相机数据
// ─────────────────────────────────────────────────────────────────────────────
class _CameraItem {
  final String id;
  final String name;
  final String emoji;
  final bool hasR;
  const _CameraItem({required this.id, required this.name, required this.emoji, this.hasR = false});
}

const _kVideoCameras = [
  _CameraItem(id: 'vhs', name: 'VHS', emoji: '📼'),
  _CameraItem(id: '8mm', name: '8mm', emoji: '🎥'),
  _CameraItem(id: 'original_v', name: 'Original V', emoji: '📹'),
  _CameraItem(id: 'v_classic', name: 'V Classic', emoji: '🎞'),
];

const _kPhotoCameras = [
  _CameraItem(id: 'fxn_r', name: 'FXN', emoji: '📷', hasR: true),
  _CameraItem(id: 'grd_r', name: 'GRD', emoji: '📷', hasR: true),
  _CameraItem(id: 'ccd_r', name: 'CCD', emoji: '📸', hasR: true),
  _CameraItem(id: 'inst_sqc', name: 'Inst SQC', emoji: '🎞'),
];

// ─────────────────────────────────────────────────────────────────────────────
// 自定义 Painter
// ─────────────────────────────────────────────────────────────────────────────

class _DashedCirclePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white54
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - 4) / 2;
    // 绘制虚线圆圈
    const dashCount = 20;
    const dashAngle = 3.14159 * 2 / dashCount;
    const gapRatio = 0.4; // 间隙占比
    for (int i = 0; i < dashCount; i++) {
      final startAngle = i * dashAngle;
      final sweepAngle = dashAngle * (1 - gapRatio);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DashedCirclePainter old) => false;
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withAlpha(60)
      ..strokeWidth = 0.5;
    canvas.drawLine(Offset(size.width / 3, 0), Offset(size.width / 3, size.height), paint);
    canvas.drawLine(Offset(size.width * 2 / 3, 0), Offset(size.width * 2 / 3, size.height), paint);
    canvas.drawLine(Offset(0, size.height / 3), Offset(size.width, size.height / 3), paint);
    canvas.drawLine(Offset(0, size.height * 2 / 3), Offset(size.width, size.height * 2 / 3), paint);
  }

  @override
  bool shouldRepaint(_GridPainter old) => false;
}

class _StrikethroughPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = _kRed
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(size.width * 0.2, size.height * 0.8),
      Offset(size.width * 0.8, size.height * 0.2),
      paint,
    );
  }

  @override
  bool shouldRepaint(_StrikethroughPainter old) => false;
}

class _ColorWheelPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final colors = [
      Colors.red,
      Colors.orange,
      Colors.yellow,
      Colors.green,
      Colors.cyan,
      Colors.blue,
      Colors.purple,
      Colors.red,
    ];
    final paint = Paint()
      ..shader = SweepGradient(colors: colors).createShader(
        Rect.fromCircle(center: center, radius: radius),
      );
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(_ColorWheelPainter old) => false;
}
