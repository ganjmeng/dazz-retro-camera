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
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:go_router/go_router.dart';
import '../../models/camera_definition.dart';
import '../../models/camera_registry.dart';
import '../../services/camera_service.dart';
import '../../router/app_router.dart';
import 'camera_notifier.dart';
import 'preview_renderer.dart';
import '../gallery/gallery_screen.dart';
import 'camera_config_sheet.dart';
// ─── 颜色常量 ─────────────────────────────────────────────────────────────────────────────
const _kBlack = Color(0xFF000000);
const _kDarkGray = Color(0xFF1C1C1E);
const _kLightGray = Color(0xFF3A3A3C);
const _kWhite = Colors.white;
const _kBlue = Color(0xFF007AFF);
const _kRed = Color(0xFFFF3B30);

// ─── 布局常量（提升为顶层常量，供多个方法共享）─────────────────────────────────────────────────────────────────────────────
const kToolbarH = 64.0;
const kShutterH = 96.0;
const kBottomPanelTopPad = 16.0; // 工具栏上方间距
const kToolbarShutterGap = 28.0; // 工具栏和快门行间距
const kBottomPanelH = kBottomPanelTopPad + kToolbarH + kToolbarShutterGap + kShutterH;
const kCapsuleH = 48.0; // 胶囊高度（对应截图中的按钮高度）
const kCapsuleInsetBottom = 20.0; // 胶囊距取景框底部的内边距
const kSliderAreaH = 80.0; // 胶囊下方滑条展开区域预留高度
const kViewfinderHPadding = 16.0; // 取景框左右边距
const kTopBarH = 44.0;

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {

  Uint8List? _latestThumb;
  AssetEntity? _latestAsset; // 最新照片 entity（长按直接打开详情用）
  int _timerCountdown = 0;
  Timer? _countdownTimer;

  // 曝光拖拽（胶囊上的旧逻辑保留备用）
  double _exposureDragStart = 0;
  double _exposureAtDragStart = 0;
  // 温度拖拽
  double _tempDragStart = 0;
  double _tempAtDragStart = 0;

  // ── 对焦圈 + 曝光太阳（取景框内） ──────────────────────────────────────────
  // 对焦点（相对取景框的局部坐标）
  Offset? _focusPoint;
  // 曝光太阳在垂直轨道上的偏移量（像素，正=下=暗，负=上=亮）
  double _sunOffsetY = 0;
  // 拖拽太阳时的起始 Y
  double _sunDragStartY = 0;
  double _sunOffsetAtDragStart = 0;
  // 对焦圈淡出计时器
  Timer? _focusFadeTimer;
  // 对焦圈是否可见
  bool _showFocusRing = false;
  // 是否正在拖动太阳（控制竖轨道线显示）
  bool _isDraggingSun = false;
  // 取景框中央文字提示（闪光灯/倒计时切换时显示）
  String? _viewfinderHint;
  Timer? _hintTimer;
  // 曝光水平滑动条是否展开（点击胶囊触发）
  bool _showExposureSlider = false;
  // 色温面板是否展开（点击色温胶囊触发）
  bool _showWbPanel = false;
  // ── 捩合缩放 ────────────────────────────────────────────────────────────────────────
  // 捩合开始时的缩放值（用于计算相对缩放量）
  double _pinchStartZoom = 1.0;
  // 当前活跃触控点数（用于区分单指/双指）
  int _activePointers = 0;
  // 是否正在进行双指捩合操作（防止双指触发对焦）
  bool _isPinching = false;
  // 耗时操作过渡动画（换相机/切滤镜/切比例/切清晰度）
  bool _showTransition = false;
  Timer? _transitionTimer;

  // Options 弹框控制器
  late AnimationController _optionsAnim;
  late Animation<Offset> _optionsSlide;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _optionsAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _optionsSlide = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _optionsAnim, curve: Curves.easeOutCubic));

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 一次性请求所有权限（相机 + 相册），再初始化
      await _requestPermissions();
      if (mounted) {
        // 加载相机 JSON 配置
        ref.read(cameraAppProvider.notifier).initialize();
        // 初始化原生相机硬件（获取 textureId，开始预览）
        ref.read(cameraServiceProvider.notifier).initCamera();
        _loadLatestThumb();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _countdownTimer?.cancel();
    _focusFadeTimer?.cancel();
    _hintTimer?.cancel();
    _transitionTimer?.cancel();
    _optionsAnim.dispose();
    super.dispose();
  }

  /// App 生命周期监听：从后台切回前台时触发过渡动画
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // App 从后台切回前台：黑屏 + App Icon 淡入淡出
      _transitionTimer?.cancel();
      setState(() => _showTransition = true);
      _transitionTimer = Timer(const Duration(milliseconds: 600), () {
        if (mounted) setState(() => _showTransition = false);
      });
    }
  }

  /// 耗时操作过渡：黑屏 + App Icon 淡入，执行 [action]，然后淡出。
  /// [duration] 是黑屏持续时间（不含淡入淡出动画时间）。
  Future<void> _showCameraTransition(VoidCallback action, {Duration duration = const Duration(milliseconds: 400)}) async {
    _transitionTimer?.cancel();
    setState(() => _showTransition = true);
    // 等待淡入动画完成再执行操作
    await Future.delayed(const Duration(milliseconds: 200));
    action();
    // 持续黑屏一段时间，然后淡出
    _transitionTimer = Timer(duration, () {
      if (mounted) setState(() => _showTransition = false);
    });
  }

  // ── 取景框中央文字提示（1.5秒后自动消失）────────────────────────────────────
  void _showViewfinderHint(String text) {
    _hintTimer?.cancel();
    setState(() => _viewfinderHint = text);
    _hintTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _viewfinderHint = null);
    });
  }

  // ── 点击取景框：设置对焦点，显示对焦圈+曝光太阳 ────────────────────────
  void _onViewfinderTap(TapDownDetails d, double viewfinderH) {
    // 双指捩合期间不触发对焦
    if (_isPinching || _activePointers >= 2) return;
    // 关闭曝光水平滑动条
    if (_showExposureSlider) {
      setState(() => _showExposureSlider = false);
      return;
    }
    // 如果已有对焦点且点击的不是太阳区域（距太阳中心 > 40px），则太阳视觉复位到中间
    if (_showFocusRing && _focusPoint != null) {
      final sunCenterX = _focusPoint!.dx + 48.0;
      final sunCenterY = _focusPoint!.dy + _sunOffsetY;
      final dx = d.localPosition.dx - sunCenterX;
      final dy = d.localPosition.dy - sunCenterY;
      final dist = (dx * dx + dy * dy);
      if (dist > 40 * 40) {
        // 点击了太阳以外的地方：太阳视觉回到中间（sunOffsetY = 0）
        // 但曝光值不变，下次拖动从视觉中间出发继续调整
        setState(() {
          _focusPoint = d.localPosition;
          _sunOffsetY = 0; // 视觉归中，曝光值保留
        });
        _focusFadeTimer?.cancel();
        _focusFadeTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) setState(() => _showFocusRing = false);
        });
        return;
      }
    }
    setState(() {
      _focusPoint = d.localPosition;
      _showFocusRing = true;
      // 新对焦点时太阳视觉从中间开始（偏移清零），曝光值保留
      _sunOffsetY = 0;
    });
    // 3秒后淡出对焦圈
    _focusFadeTimer?.cancel();
    _focusFadeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showFocusRing = false);
    });
  }

  // ── 拖动曝光太阳：上下滑动调整曝光 ─────────────────────────────────────────
  void _onSunDragStart(DragStartDetails d, double viewfinderH) {
    // 拖动从当前位置开始（不重置到中间，保留已有偏移）
    _sunDragStartY = d.globalPosition.dy;
    _sunOffsetAtDragStart = _sunOffsetY;
    _focusFadeTimer?.cancel(); // 拖动时不淡出
    setState(() => _isDraggingSun = true);
  }

  void _onSunDragUpdate(DragUpdateDetails d, double viewfinderH) {
    final delta = d.globalPosition.dy - _sunDragStartY;
    final newOffset = (_sunOffsetAtDragStart + delta)
        .clamp(-viewfinderH * 0.35, viewfinderH * 0.35);
    setState(() => _sunOffsetY = newOffset);
    // 将像素偏移映射到曝光值 [-2, 2]：向上(负offset)=增加曝光
    final newExp = (-newOffset / (viewfinderH * 0.35) * 2.0).clamp(-2.0, 2.0);
    ref.read(cameraAppProvider.notifier).setExposure(newExp);
  }

  void _onSunDragEnd(DragEndDetails d, double viewfinderH) {
    setState(() => _isDraggingSun = false);
    // 拖动结束后 3 秒淡出
    _focusFadeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showFocusRing = false);
    });
  }

  /// 一次性请求所有权限（相机 + 相册，不含麦克风）
  Future<void> _requestPermissions() async {
    // 一次性弹出所有权限请求
    final statuses = await [
      Permission.camera,
      Permission.photos,   // Android 13+ / iOS
      Permission.storage,  // Android 12 及以下
    ].request();

    final cameraGranted = statuses[Permission.camera]?.isGranted == true;
    if (!cameraGranted && mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1C1C1E),
          title: const Text('需要相机权限', style: TextStyle(color: Colors.white)),
          content: const Text(
            '请在设置中开启相机权限以使用拍照功能',
            style: TextStyle(color: Colors.grey),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                openAppSettings();
              },
              child: const Text('去设置', style: TextStyle(color: Color(0xFFFF9500))),
            ),
          ],
        ),
      );
    }
  }

  /// App 启动时加载最新缩略图（不用于拍照后刷新）
  Future<void> _loadLatestThumb() async {
    final perm = await PhotoManager.requestPermissionExtend();
    if (!perm.hasAccess) return;
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      hasAll: true,
      onlyAll: false,
      filterOption: FilterOptionGroup(
        orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
      ),
    );
    if (albums.isEmpty) return;
    AssetPathEntity? target;
    for (final a in albums) {
      if (a.name.toUpperCase().contains('DAZZ')) { target = a; break; }
    }
    target ??= albums.firstWhere((a) => a.isAll, orElse: () => albums.first);
    final assets = await target.getAssetListRange(start: 0, end: 1);
    if (assets.isNotEmpty && mounted) {
      await _applyThumbFromAsset(assets.first);
    }
  }

  /// 拍照后直接用 MediaStore ID 查询资产，完全绕开相册查询
  Future<void> _loadThumbFromGalleryId(String assetId) async {
    final asset = await AssetEntity.fromId(assetId);
    if (asset != null && mounted) {
      await _applyThumbFromAsset(asset);
      debugPrint('[CameraScreen] _loadThumbFromGalleryId OK, id=$assetId');
    } else {
      debugPrint('[CameraScreen] _loadThumbFromGalleryId: asset not found for id=$assetId');
    }
  }

  /// 生成缩略图并更新状态
  Future<void> _applyThumbFromAsset(AssetEntity asset) async {
    final thumb = await asset.thumbnailDataWithSize(const ThumbnailSize(120, 120));
    if (mounted) {
      setState(() {
        _latestThumb = thumb;
        _latestAsset = asset;
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
    final st = ref.read(cameraAppProvider);
    // 小窗模式开启时，计算小窗在取景框内的归一化坐标
    Rect? minimapRect;
    if (st.minimapEnabled) {
      minimapRect = _MinimapOverlay.calcNormalizedRect(st.zoomLevel);
    }
    final result = await ref.read(cameraAppProvider.notifier).takePhoto(
      minimapNormalizedRect: minimapRect,
    );
    if (result != null && mounted) {
      // 优先用 galleryAssetId 直接查资产（绕开相册查询，100% 可靠）
      if (result.galleryAssetId != null) {
        _loadThumbFromGalleryId(result.galleryAssetId!);
      } else {
        // fallback: 相册查询（仅当 saveToGallery 未返回 URI 时）
        _loadLatestThumb();
      }
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
    final screenW = mq.size.width;
    final statusBarH = mq.padding.top;
    final bottomSafeH = mq.padding.bottom;
    // 底部面板常量已提升为顶层常量（文件顶部定义）
    // kToolbarH=64, kShutterH=96, kBottomPanelTopPad=12, kToolbarShutterGap=32
    // kBottomPanelH=204, kCapsuleH=40, kCapsuleBottomOffset=220
    // 取景框宽度：按比例决定
    // 对于 9:16（竖向比例 < 0.75），取景框宽度缩窄以居中显示
    // 对于 1:1、3:4、2:3，取景框宽度 = 全屏宽 - 边距
    // kSliderAreaH: 预留胶囊下方滑条区域（曝光/色温/缩放滑条展开时显示在此区域）
    final maxViewfinderH = mq.size.height - statusBarH - kTopBarH - kBottomPanelH - bottomSafeH - kSliderAreaH;
    final aspectRatio = st.previewAspectRatio; // width/height
    double viewfinderW;
    double viewfinderH;
    if (aspectRatio < 0.75) {
      // 竖向比例（如 9:16 = 0.5625）：高度撑满可用空间，宽度按比例缩窄
      viewfinderH = maxViewfinderH;
      viewfinderW = (viewfinderH * aspectRatio).clamp(0.0, screenW - kViewfinderHPadding * 2);
    } else {
      // 横向或方形比例（1:1, 3:4, 2:3）：宽度撑满，高度按比例
      viewfinderW = screenW - kViewfinderHPadding * 2;
      viewfinderH = (viewfinderW / aspectRatio).clamp(viewfinderW * 0.5, maxViewfinderH);
    }
    // 取景框在顶部栏和底部面板之间的可用空间内垂直居中
    final availableH = maxViewfinderH;
    final viewfinderTopOffset = statusBarH + kTopBarH + ((availableH - viewfinderH) / 2).clamp(0.0, 80.0);
    // 取景框水平居中
    final viewfinderLeft = (screenW - viewfinderW) / 2;

    return Scaffold(
      backgroundColor: _kBlack,
      body: Stack(
        children: [
          // ── 底部面板固定在屏幕底部（不随取景框高度变化）──
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildBottomPanel(st),
          ),
          // ── 顶部按钮行：状态栏下方的纯黑色区域，只有 "..." 按钮──
          Positioned(
            top: statusBarH,
            left: 0,
            right: 0,
            height: kTopBarH,
            child: Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                onTap: () => ref.read(cameraAppProvider.notifier).toggleTopMenu(),
                child: const SizedBox(
                  width: 56,
                  height: kTopBarH,
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
          ),
          // ── 取景框（圆角，垂直居中，水平居中）──
          Positioned(
            top: viewfinderTopOffset,
            left: viewfinderLeft,
            child: SizedBox(
              width: viewfinderW,
              height: viewfinderH,
              child: _buildViewfinderArea(st, camSvc, viewfinderH, viewfinderW),
            ),
          ),
          // ── 控制胶囊：固定在取景框底部内侧，不随取景框大小变化 ──
          // 位置 = 取景框底部 - 胶囊高度 - 内边距，与滤镜框无关
          Positioned(
            left: viewfinderLeft,
            right: viewfinderLeft,
            top: viewfinderTopOffset + viewfinderH - kCapsuleH - kCapsuleInsetBottom,
            height: kCapsuleH,
            child: Center(child: _buildControlCapsule(st)),
          ),

          // ── 三个拉条：固定在取景框底部和底部面板之间的 kSliderAreaH 区域内 ──
          // 使用固定高度 Positioned，避免 top/bottom 同时指定导致的 OVERFLOW 报错
          // 三者完全互斥：同一时刻只显示一个
          if (_showExposureSlider)
            Positioned(
              left: 0,
              right: 0,
              bottom: kBottomPanelH + bottomSafeH,
              height: kSliderAreaH,
              child: Center(
                child: _ExposureHorizontalSlider(
                  value: st.exposureValue,
                  onChanged: (v) =>
                      ref.read(cameraAppProvider.notifier).setExposure(v),
                  onReset: () {
                    ref.read(cameraAppProvider.notifier).setExposure(0);
                    setState(() => _sunOffsetY = 0);
                  },
                ),
              ),
            ),
          if (st.showZoomSlider && !_showExposureSlider && !_showWbPanel)
            Positioned(
              left: 0,
              right: 0,
              bottom: kBottomPanelH + bottomSafeH,
              height: kSliderAreaH,
              child: Center(
                child: _ZoomHorizontalSlider(
                  value: st.zoomLevel,
                  onChanged: (v) =>
                      ref.read(cameraAppProvider.notifier).setZoom(v),
                  onReset: () =>
                      ref.read(cameraAppProvider.notifier).setZoom(1.0),
                ),
              ),
            ),
          if (_showWbPanel && !_showExposureSlider)
            Positioned(
              left: 0,
              right: 0,
              bottom: kBottomPanelH + bottomSafeH,
              height: kSliderAreaH,
              child: Center(
                child: _WbControlPanel(
                  colorTempK: st.colorTempK,
                  wbMode: st.wbMode,
                  onTempChanged: (k) =>
                      ref.read(cameraAppProvider.notifier).setColorTempK(k),
                  onPreset: (mode) {
                    ref.read(cameraAppProvider.notifier).setWhiteBalance(mode);
                    final labels = {
                      'auto': '自动',
                      'daylight': '日光',
                      'incandescent': '白炎灯',
                    };
                    _showViewfinderHint(labels[mode] ?? mode);
                  },
                ),
              ),
            ),
          // ── 右上角菜单弹框 ── ──
          if (st.showTopMenu) _buildTopMenuOverlay(st),
          // ── 倒计时蒙层 ──
          if (_timerCountdown > 0) _buildCountdownOverlay(),
          // ── 拍摄闪光 ──
          if (st.showCaptureFlash)
            Container(color: Colors.white.withAlpha(200)),
          // ── 耗时操作过渡动画（换相机/切滤镜/切比例/切清晰度）──
          AnimatedOpacity(
            opacity: _showTransition ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOut,
            child: IgnorePointer(
              ignoring: !_showTransition,
              child: Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: AnimatedScale(
                  scale: _showTransition ? 1.0 : 0.85,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutBack,
                  child: Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A1A),
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withAlpha(120),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(28),
                      child: Image.asset(
                        'assets/images/app_icon.png',
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Center(
                          child: Icon(
                            Icons.camera_alt,
                            color: Colors.white,
                            size: 48,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
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
              onCameraTransition: _showCameraTransition,
            ),
          ),
        ],
      ),
    );
  }

  // ── 取景框区域（上段）──────────────────────────────────────────────────────────────
  // 布局：圆角取景框，内部只有预览画面和网格线（控制胶囊已移到取景框外部）
  Widget _buildViewfinderArea(CameraAppState st, CameraState camSvc, double areaH, double screenW) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 相机预览
          _buildPreview(st, camSvc),
          // 三等分网格线：小窗开启时网格移入小窗内部，小窗关闭时全局显示
          if (st.gridEnabled && !st.minimapEnabled) _buildGrid(),
          // 拍摄中黑色半透明蒙层
          if (st.isTakingPhoto)
            Container(
              color: Colors.black.withAlpha(80),
              child: const Center(
                child: CircularProgressIndicator(color: _kWhite, strokeWidth: 2),
              ),
            ),
          // ── 色温滤色叠加层（根据 colorTempK 叠加半透明暖/冷色调）──
          if (st.wbMode != 'auto')
            _WbColorOverlay(colorTempK: st.colorTempK),
          // ── 取景框手势：对焦 + 曝光 + 捩合缩放（完全分离）──
          // Listener 追踪活跃触控点数，确保双指不触发对焦
          Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) {
              _activePointers++;
              // 第二根手指放下时立即标记为捩合模式，并取消已有对焦圈
              if (_activePointers >= 2 && !_isPinching) {
                _isPinching = true;
                // 取消对焦圈，避免双指开始时显示对焦圈
                if (mounted) setState(() => _showFocusRing = false);
                _focusFadeTimer?.cancel();
              }
            },
            onPointerUp: (_) {
              _activePointers = (_activePointers - 1).clamp(0, 10);
              if (_activePointers < 2) {
                // 所有手指抬起后延迟重置，避免最后一根手指抬起时意外触发对焦
                Future.delayed(const Duration(milliseconds: 150), () {
                  if (mounted) _isPinching = false;
                });
              }
            },
            onPointerCancel: (_) {
              _activePointers = (_activePointers - 1).clamp(0, 10);
              if (_activePointers < 2) {
                Future.delayed(const Duration(milliseconds: 150), () {
                  if (mounted) _isPinching = false;
                });
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapDown: (d) => _onViewfinderTap(d, areaH),
              onScaleStart: (d) {
                if (d.pointerCount >= 2) {
                  // 双指捩合开始
                  _isPinching = true;
                  _pinchStartZoom = ref.read(cameraAppProvider).zoomLevel;
                  // 隐藏对焦圈，避免干扰
                  if (mounted) setState(() => _showFocusRing = false);
                  _focusFadeTimer?.cancel();
                }
              },
              onScaleUpdate: (d) {
                if (d.pointerCount < 2) return;
                final newZoom = (_pinchStartZoom * d.scale).clamp(0.6, 20.0);
                ref.read(cameraAppProvider.notifier).setZoom(newZoom);
              },
              onScaleEnd: (d) {
                // 捩合结束，延迟重置标志（等手指全部抬起）
                Future.delayed(const Duration(milliseconds: 200), () {
                  if (mounted) _isPinching = false;
                });
              },
            ),
          ),
          // ── 对焦圈 + 曝光太阳 overlay ──
          if (_showFocusRing && _focusPoint != null)
            _FocusExposureOverlay(
              focusPoint: _focusPoint!,
              sunOffsetY: _sunOffsetY,
              viewfinderH: areaH,
              isDragging: _isDraggingSun,
              onSunDragStart: (d) => _onSunDragStart(d, areaH),
              onSunDragUpdate: (d) => _onSunDragUpdate(d, areaH),
              onSunDragEnd: (d) => _onSunDragEnd(d, areaH),
            ),
          // ── 取景框中央文字提示（闪光灯/倒计时）──
          if (_viewfinderHint != null)
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: AnimatedOpacity(
                    opacity: _viewfinderHint != null ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(160),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        _viewfinderHint!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // ── 小窗 overlay（小窗模式开启时显示）──
          if (st.minimapEnabled)
            _MinimapOverlay(
              zoomLevel: st.zoomLevel,
              gridEnabled: st.gridEnabled,
              areaW: screenW,
              areaH: areaH,
            ),
        ],
      ),
    );
  } // ── 底部面板（下段）──────────────────────────────────────────────────────────────────
  // 布局：深灰色圆角面板，[照片/视频 tab] + [样图/管理] → 相机列表 → 工具栏 → 快门行
  Widget _buildBottomPanel(CameraAppState st) {
    // 底部面板：纯黑背景
    // 布局：工具栏 + 间距 + 快门行 + 底部安全区
    return Container(
      color: _kBlack,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: kBottomPanelTopPad),
          // 工具图标行（4个图标+文字标签）
          // 点击曝光胶囊或色温胶囊时隐藏工具栏
          AnimatedOpacity(
            opacity: (_showExposureSlider || _showWbPanel || st.showZoomSlider) ? 0.0 : 1.0,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(
              ignoring: _showExposureSlider || _showWbPanel || st.showZoomSlider,
              child: _buildToolbar(st),
            ),
          ),
          const SizedBox(height: kToolbarShutterGap),
          // 快门行
          _buildShutterRow(st),
          // 底部安全区域
          SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
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
            onTap: () => _showCameraTransition(
              () => ref.read(cameraAppProvider.notifier).switchToCamera(cam.id),
              duration: const Duration(milliseconds: 500),
            ),
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
    // 只要 textureId 就绪，即可显示预览；
    // renderParams 为 null 时（JSON 尚未加载）用默认空参数，避免黑屏
    if (camSvc.textureId != null) {
      final params = st.renderParams ?? const PreviewRenderParams();
      return PreviewFilterWidget(
        textureId: camSvc.textureId!,
        params: params,
        aspectRatio: st.previewAspectRatio,
      );
    }
    // 未初始化时显示占位提示
    return Container(
      color: Colors.black,
      child: const Center(
        child: Text(
          '相机初始化中...',
          style: TextStyle(color: Colors.white54, fontSize: 14),
        ),
      ),
    );
  }

  Widget _buildGrid() {
    return CustomPaint(
      painter: _GridPainter(),
    );
  }

  // ── 控制胶囊 ──────────────────────────────────────────────────────────────
  // 截图精确复刻：深色半透明背景，白色文字，[🌡] [x1] [☀ 0.0]
  Widget _buildControlCapsule(CameraAppState st) {
    // 截图精确复刻：3个独立圆形/胶囊按鈕 [🌡] [x1] [☀ 0.0]
    // 倒率按鈕显示实时 zoomLevel
    final zoom = st.zoomLevel;
    final zoomLabel = zoom == zoom.roundToDouble()
        ? 'x${zoom.toInt()}'
        : 'x${zoom.toStringAsFixed(1)}';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 色温按鈕（圆形，点击弹出色温面板）
        // 高亮条件：面板展开 OR 色温不为自动
        GestureDetector(
          onTap: () {
            setState(() {
              _showWbPanel = !_showWbPanel;
              if (_showWbPanel) _showExposureSlider = false; // 互斥
            });
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (_showWbPanel || st.wbMode != 'auto')
                  ? Colors.white.withAlpha(230)
                  : Colors.black.withAlpha(160),
            ),
            child: Center(
              child: Icon(
                // 展开时显示向下箭头，收起时显示温度计
                _showWbPanel ? Icons.keyboard_arrow_down : Icons.thermostat_outlined,
                size: 20,
                color: (_showWbPanel || st.wbMode != 'auto') ? Colors.black : _kWhite,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        // 倍率按鈕（胶囊形，中间）—— 点击展开/收起缩放滑动条
        GestureDetector(
          onTap: () {
            ref.read(cameraAppProvider.notifier).toggleZoomSlider();
            // 与曝光、色温互斥
            setState(() {
              _showExposureSlider = false;
              _showWbPanel = false;
            });
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              color: st.showZoomSlider
                  ? Colors.white.withAlpha(230)
                  : Colors.black.withAlpha(160),
            ),
            child: Center(
              child: Text(
                zoomLabel,
                style: TextStyle(
                  color: st.showZoomSlider ? Colors.black : _kWhite,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        // 曝光按钮（胶囊形，点击展开水平滑动条）
        // 高亮条件：面板展开 OR 曝光值不为 0
        GestureDetector(
          onTap: () {
            setState(() {
              _showExposureSlider = !_showExposureSlider;
              if (_showExposureSlider) _showWbPanel = false; // 与色温面板互斥
            });
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              color: (_showExposureSlider || st.exposureValue != 0)
                  ? Colors.white.withAlpha(230)
                  : Colors.black.withAlpha(160),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  // 展开时显示向下箭头，收起时显示太阳
                  _showExposureSlider ? Icons.keyboard_arrow_down : Icons.wb_sunny_outlined,
                  size: 16,
                  color: (_showExposureSlider || st.exposureValue != 0) ? Colors.black : _kWhite,
                ),
                const SizedBox(width: 6),
                Text(
                  st.exposureValue == 0
                      ? '0.0'
                      : (st.exposureValue > 0 ? '+' : '') +
                          st.exposureValue.toStringAsFixed(1),
                  style: TextStyle(
                    color: (_showExposureSlider || st.exposureValue != 0) ? Colors.black : _kWhite,
                    fontSize: 15,
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
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
              onTap: () {
                // 先读当前状态，计算切换后的值，再执行切换
                final cur = ref.read(cameraAppProvider).timerSeconds;
                final options = [0, 3, 10];
                final next = options[(options.indexOf(cur) + 1) % options.length];
                ref.read(cameraAppProvider.notifier).cycleTimer();
                if (next == 0) {
                  _showViewfinderHint('倒计时关闭');
                } else {
                  _showViewfinderHint('倒计时 ${next}s');
                }
              },
            ),
            // 3. 闪光灯
            _FlashBtn(
              mode: st.flashMode,
              label: '闪光灯',
              onTap: () {
                // 先读当前状态，计算切换后的值，再执行切换
                final cur = ref.read(cameraAppProvider).flashMode;
                final modes = ['off', 'on', 'auto'];
                final next = modes[(modes.indexOf(cur) + 1) % modes.length];
                ref.read(cameraAppProvider.notifier).cycleFlash();
                if (next == 'off') {
                  _showViewfinderHint('闪光灯已关闭');
                } else if (next == 'on') {
                  _showViewfinderHint('闪光灯已开启');
                } else {
                  _showViewfinderHint('闪光灯自动');
                }
              },
            ),
            // 4. 前置/后置切换
            _ToolbarBtn(
              icon: Icons.flip_camera_ios_outlined,
              label: '后置',
              onTap: () => _showCameraTransition(
                () => ref.read(cameraAppProvider.notifier).flipCamera(),
                duration: const Duration(milliseconds: 500),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 快门行 ──────────────────────────────────────────────────────────────────
  // 截图布局：[缩略图 72×72] [快门 88×88] [相机图标 72×72]
  Widget _buildShutterRow(CameraAppState st) {
    return SizedBox(
      height: 96,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 左侧: 图库缩略图（单击→相册列表，长按→直接打开最新相片详情）
            GestureDetector(
              onTap: _openGallery,
              onLongPress: _openLatestPhotoDetail,
              child: Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: _kDarkGray,
                ),
                child: _latestThumb != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.memory(_latestThumb!, fit: BoxFit.cover),
                      )
                    : const Icon(Icons.photo_outlined, color: Colors.grey, size: 26),
              ),
            ),
            // 中间: 快门按钮（外圈白色线圈，内圆白色实心）
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
            // 右侧: 相机图标（虚线圆圈背景，点击打开相机配置）
            GestureDetector(
              onTap: () => showCameraConfigSheet(context),
              child: SizedBox(
                width: 60,
                height: 60,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // 虚线圆圈背景
                    CustomPaint(
                      size: const Size(60, 60),
                      painter: _DashedCirclePainter(),
                    ),
                    // 相机图标 + 名称
                    Builder(builder: (ctx) {
                      final entry = kAllCameras.firstWhere(
                        (e) => e.id == st.activeCameraId,
                        orElse: () => kAllCameras.first,
                      );
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 优先使用真实相机图标，如果没有则用系统图标
                          if (entry.iconPath != null)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.asset(
                                entry.iconPath!,
                                width: 32,
                                height: 32,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) =>
                                    const Icon(Icons.photo_camera_outlined, color: _kWhite, size: 24),
                              ),
                            )
                          else
                            const Icon(Icons.photo_camera_outlined, color: _kWhite, size: 24),
                          const SizedBox(height: 3),
                          Text(
                            entry.name,
                            style: const TextStyle(
                              color: _kWhite,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      );
                    }),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 右上角菜单弹框（"..."展开）──────────────────────────────────────────────
  Widget _buildTopMenuOverlay(CameraAppState st) {
    final mq = MediaQuery.of(context);
    // 复刻截图样式：图标直接浮在顶部栏正下方，无卡片容器背景
    final menuTop = mq.padding.top + kTopBarH;
    final sharpenLabels = ['低', '中', '高'];
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => ref.read(cameraAppProvider.notifier).toggleTopMenu(),
      child: SizedBox.expand(
        child: Stack(
          children: [
            Positioned(
              top: menuTop,
              left: 0,
              right: 0,
              child: GestureDetector(
                onTap: () {}, // 阻止穿透
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 第一行: 4个图标（等宽分布）
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // 1. 网格线
                          _TopMenuBtn(
                            icon: st.gridEnabled ? Icons.grid_on : Icons.grid_off,
                            label: st.gridEnabled ? '网格线开启' : '网格线关闭',
                            onTap: () => ref.read(cameraAppProvider.notifier).toggleGrid(),
                          ),
                          // 2. 清晰度（循环切换 低/中/高）
                          _TopMenuBtn(
                            customIcon: Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.white, width: 1.5),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Center(
                                child: Text(
                                  sharpenLabels[st.sharpenLevel],
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    height: 1,
                                  ),
                                ),
                              ),
                            ),
                            label: '清晰度',
                            onTap: () => _showCameraTransition(
                              () => ref.read(cameraAppProvider.notifier).cycleSharpen(),
                              duration: const Duration(milliseconds: 350),
                            ),
                          ),
                          // 3. 小窗模式
                          _TopMenuBtn(
                            icon: st.minimapEnabled
                                ? Icons.picture_in_picture
                                : Icons.picture_in_picture_outlined,
                            label: st.minimapEnabled ? '小窗开启' : '小窗关闭',
                            onTap: () {
                              final willEnable = !st.minimapEnabled;
                              ref.read(cameraAppProvider.notifier).toggleMinimap();
                              ref.read(cameraAppProvider.notifier).toggleTopMenu();
                              _showViewfinderHint(willEnable ? '小窗模式已开启' : '小窗模式已关闭');
                            },
                          ),
                          // 4. 双重曝光
                          _TopMenuBtn(
                            icon: Icons.exposure,
                            label: '双重曝光关闭',
                            onTap: () {},
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      // 第二行: 2个图标 + 2个占位（保持对齐）
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // 5. 连拍
                          _TopMenuBtn(
                            icon: Icons.burst_mode_outlined,
                            label: '连拍关闭',
                            onTap: () {},
                          ),
                          // 6. 设置
                          _TopMenuBtn(
                            icon: Icons.settings_outlined,
                            label: '设置',
                            onTap: () {
                              // 先关闭顶部菜单，再跳转设置界面
                              ref.read(cameraAppProvider.notifier).toggleTopMenu();
                              context.push(AppRoutes.settings);
                            },
                          ),
                          // 占位空白（保持对齐）
                          const SizedBox(width: 56),
                          const SizedBox(width: 56),
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
  final void Function(VoidCallback action, {Duration duration}) onCameraTransition;

  const _OptionsSheet({
    required this.onClose,
    required this.onCameraTransition,
  });

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
                  onCameraTransition(
                    () => ref.read(cameraAppProvider.notifier).switchToCamera(cam.id),
                    duration: const Duration(milliseconds: 500),
                  );
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
            onSelect: (id) => onCameraTransition(
              () => ref.read(cameraAppProvider.notifier).selectRatio(id),
              duration: const Duration(milliseconds: 400),
            ),
          ),
        'filter' => _FilterRow(
            filters: camera.modules.filters,
            activeId: st.activeFilterId,
            onSelect: (id) => onCameraTransition(
              () => ref.read(cameraAppProvider.notifier).selectFilter(id),
              duration: const Duration(milliseconds: 400),
            ),
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
    if (!perm.hasAccess) { if (mounted) setState(() => _loading = false); return; }
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
            width: 36,
            height: 36,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(icon, color: _kWhite, size: 28),
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
            Text(label!, style: const TextStyle(color: Colors.white70, fontSize: 11)),
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
            width: 36,
            height: 36,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  Icons.flash_on,
                  color: isOff ? _kWhite : _kRed,
                  size: 28,
                ),
                if (isOff)
                  CustomPaint(
                    size: const Size(28, 28),
                    painter: _StrikethroughPainter(),
                  ),
              ],
            ),
          ),
          if (label != null) ...[  
            const SizedBox(height: 4),
            Text(label!, style: const TextStyle(color: Colors.white70, fontSize: 11)),
          ],
        ],
      ),
    );
  }
}

// 复刻截图样式的顶部菜单按鈕：图标直接显示，无背景容器，白色线条风格
class _TopMenuBtn extends StatelessWidget {
  final IconData? icon;
  final Widget? customIcon;
  final String label;
  final VoidCallback onTap;

  const _TopMenuBtn({
    this.icon,
    this.customIcon,
    required this.label,
    required this.onTap,
  }) : assert(icon != null || customIcon != null);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 56,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: customIcon ?? Icon(icon!, color: _kWhite, size: 28),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w400,
              ),
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
  _CameraItem(id: 'bw_classic', name: 'BW', emoji: '⬛'),
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

// ─── 对焦圈 + 曝光太阳 Overlay ─────────────────────────────────────────────────
// 复刻截图：白色圆形对焦圈（左），垂直白线轨道（右），太阳图标可上下拖动
class _FocusExposureOverlay extends StatelessWidget {
  final Offset focusPoint;
  final double sunOffsetY;
  final double viewfinderH;
  final bool isDragging;
  final GestureDragStartCallback onSunDragStart;
  final GestureDragUpdateCallback onSunDragUpdate;
  final GestureDragEndCallback onSunDragEnd;

  const _FocusExposureOverlay({
    required this.focusPoint,
    required this.sunOffsetY,
    required this.viewfinderH,
    required this.isDragging,
    required this.onSunDragStart,
    required this.onSunDragUpdate,
    required this.onSunDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    // 对焦圈半径
    const ringR = 36.0;
    // 太阳图标尺寸
    const sunSize = 28.0;
    // 太阳距对焦圈右侧的水平偏移（固定，不随 Y 变化）
    const sunOffsetX = 48.0;
    // 轨道高度：固定 160px，对齐参考截图中的短竖条
    const trackH = 160.0;
    // 太阳中心 Y（相对取景框）= 对焦点 Y + sunOffsetY（随拖动移动）
    final sunCenterY = focusPoint.dy + sunOffsetY;
    // 太阳中心 X：固定在对焦点右侧
    final sunCenterX = focusPoint.dx + sunOffsetX;
    // 轨道线的 X：与太阳同一列，但 top 固定在对焦点附近（不随太阳 Y 移动）
    final trackTop = focusPoint.dy - trackH / 2;

    return Stack(
      fit: StackFit.expand,
      children: [
        // 垂直轨道线：拖动时才显示，位置固定在对焦点右侧（不随太阳移动）
        if (isDragging)
          Positioned(
            left: sunCenterX - 0.5,
            top: trackTop,
            child: Container(
              width: 1,
              height: trackH,
              color: Colors.white.withAlpha(200),
            ),
          ),
        // 对焦圈（白色空心圆，点击位置居中）
        Positioned(
          left: focusPoint.dx - ringR,
          top: focusPoint.dy - ringR,
          child: Container(
            width: ringR * 2,
            height: ringR * 2,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5),
            ),
          ),
        ),
        // 曝光太阳（可拖动，拖动时高亮）
        Positioned(
          left: sunCenterX - sunSize / 2,
          top: sunCenterY - sunSize / 2,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: onSunDragStart,
            onVerticalDragUpdate: onSunDragUpdate,
            onVerticalDragEnd: onSunDragEnd,
            child: SizedBox(
              width: sunSize,
              height: sunSize,
              child: Icon(
                Icons.wb_sunny_outlined,
                // 拖动时太阳图标变为黄色，对齐参考截图
                color: isDragging ? const Color(0xFFFFD60A) : Colors.white,
                size: sunSize,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── 曝光水平滑动条（点击曝光胶囊后弹出）─────────────────────────────────────
// 复刻截图：左侧圆形重置按钮 + 右侧水平滑动轨道，滑块圆形白色
class _ExposureHorizontalSlider extends StatelessWidget {
  final double value; // -2.0 .. 2.0
  final ValueChanged<double> onChanged;
  final VoidCallback onReset;

  const _ExposureHorizontalSlider({
    required this.value,
    required this.onChanged,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // 重置按钮（圆形深灰，点击归零）
          GestureDetector(
            onTap: onReset,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withAlpha(180),
                border: Border.all(
                  color: Colors.white.withAlpha(60),
                  width: 1,
                ),
              ),
              child: const Center(
                child: Icon(
                  Icons.refresh,
                  color: Colors.white,
                  size: 22,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 水平滑动轨道
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white.withAlpha(80),
                thumbColor: Colors.white,
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 10,
                  elevation: 0,
                ),
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Slider(
                value: value.clamp(-2.0, 2.0),
                min: -2.0,
                max: 2.0,
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 色温控制面板（点击色温胶囊后弹出）────────────────────────────────────────
// 复刻截图：顶部 K 值数字，渐变滑动条（蓝→橙），右侧三个预设按钮（A/☀/💡）
class _WbControlPanel extends StatelessWidget {
  final int colorTempK;
  final String wbMode;
  final ValueChanged<int> onTempChanged;
  final ValueChanged<String> onPreset;

  const _WbControlPanel({
    required this.colorTempK,
    required this.wbMode,
    required this.onTempChanged,
    required this.onPreset,
  });

  @override
  Widget build(BuildContext context) {
    // 将 K 值（1800..8000）映射到 0.0..1.0
    final sliderVal = ((colorTempK - 1800) / (8000 - 1800)).clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // K 值数字（居中，白色）
          Text(
            '${colorTempK}K',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              // 渐变滑动条（蓝→橙，宽度约占 2/3）
              Expanded(
                flex: 3,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // 渐变轨道背景
                    Container(
                      height: 36,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        gradient: const LinearGradient(
                          colors: [
                            Color(0xFF6B8FE8), // 冷蓝（低K）
                            Color(0xFFB08AE0), // 中紫
                            Color(0xFFE8A05A), // 暖橙（高K）
                          ],
                        ),
                      ),
                    ),
                    // 虚线点装饰
                    Positioned.fill(
                      child: CustomPaint(painter: _WbTrackDotsPainter()),
                    ),
                    // 滑块
                    SliderTheme(
                      data: SliderThemeData(
                        trackHeight: 0,
                        activeTrackColor: Colors.transparent,
                        inactiveTrackColor: Colors.transparent,
                        thumbColor: Colors.white,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 12,
                          elevation: 2,
                        ),
                        overlayShape: SliderComponentShape.noOverlay,
                      ),
                      child: Slider(
                        value: sliderVal,
                        min: 0.0,
                        max: 1.0,
                        onChanged: (v) {
                          final k = (1800 + v * (8000 - 1800)).round();
                          onTempChanged(k);
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // 三个预设按钮（A / ☀ / 💡）
              _WbPresetBtn(
                label: 'A',
                labelStyle: const TextStyle(
                  color: Color(0xFFE8A05A), // 橙色 A
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
                isActive: wbMode == 'auto',
                onTap: () => onPreset('auto'),
              ),
              const SizedBox(width: 8),
              _WbPresetBtn(
                icon: Icons.wb_sunny_outlined,
                isActive: wbMode == 'daylight',
                onTap: () => onPreset('daylight'),
              ),
              const SizedBox(width: 8),
              _WbPresetBtn(
                icon: Icons.lightbulb_outline,
                isActive: wbMode == 'incandescent',
                onTap: () => onPreset('incandescent'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// 预设按钮（圆形深灰，激活时变亮）
class _WbPresetBtn extends StatelessWidget {
  final String? label;
  final TextStyle? labelStyle;
  final IconData? icon;
  final bool isActive;
  final VoidCallback onTap;

  const _WbPresetBtn({
    this.label,
    this.labelStyle,
    this.icon,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          // 激活时：白色实心圆（对齐截图中 A 按钮选中效果）
          // 未激活：深灰色圆
          color: isActive
              ? Colors.white
              : const Color(0xFF3A3A3C),
        ),
        child: Center(
          child: label != null
              ? Text(
                  label!,
                  style: isActive
                      ? TextStyle(
                          color: const Color(0xFFE8A05A), // 激活时保留橙色 A
                          fontSize: labelStyle?.fontSize ?? 16,
                          fontWeight: labelStyle?.fontWeight ?? FontWeight.w700,
                        )
                      : labelStyle,
                )
              : Icon(
                  icon,
                  // 激活时图标变黑色（白底黑字）
                  color: isActive ? const Color(0xFF1C1C1E) : Colors.white.withAlpha(180),
                  size: 20,
                ),
        ),
      ),
    );
  }
}

// 渐变轨道虚线点装饰
class _WbTrackDotsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withAlpha(80)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.fill;
    const dotR = 1.5;
    const spacing = 10.0;
    final cy = size.height / 2;
    var x = spacing;
    while (x < size.width - spacing) {
      canvas.drawCircle(Offset(x, cy), dotR, paint);
      x += spacing;
    }
  }

  @override
  bool shouldRepaint(_WbTrackDotsPainter old) => false;
}

// ─── 色温滤色叠加层（取景框内，根据 colorTempK 叠加半透明色调）──────────────
// 1800K（暖橙）→ 6300K（中性）→ 8000K（冷蓝）
class _WbColorOverlay extends StatelessWidget {
  final int colorTempK;

  const _WbColorOverlay({required this.colorTempK});

  @override
  Widget build(BuildContext context) {
    // 中性点 5500K，低于此偏暖（橙），高于此偏冷（蓝）
    const neutralK = 5500;
    const maxWarm = 1800;
    const maxCool = 8000;

    Color overlayColor;
    double opacity;

    if (colorTempK < neutralK) {
      // 偏暖：橙色叠加
      final t = (neutralK - colorTempK) / (neutralK - maxWarm);
      opacity = (t * 0.22).clamp(0.0, 0.22);
      overlayColor = const Color(0xFFE8A05A).withOpacity(opacity);
    } else {
      // 偏冷：蓝色叠加
      final t = (colorTempK - neutralK) / (maxCool - neutralK);
      opacity = (t * 0.18).clamp(0.0, 0.18);
      overlayColor = const Color(0xFF6B8FE8).withOpacity(opacity);
    }

    return Container(color: overlayColor);
  }
}

// ─── 缩放水平滑动条（点击胶囊倍率按钮后弹出）────────────────────────────────────
// 范围 x0.6 ~ x20，默认 x1.0，左侧重置按钮，右侧显示当前倍率
class _ZoomHorizontalSlider extends StatelessWidget {
  final double value; // 0.6 .. 20.0
  final ValueChanged<double> onChanged;
  final VoidCallback onReset;

  const _ZoomHorizontalSlider({
    required this.value,
    required this.onChanged,
    required this.onReset,
  });

  // 将线性滑动值（0.0~1.0）映射到对数缩放（x0.6~x20）
  // 使用对数刻度让低倍率区间更精细
  static double _sliderToZoom(double t) {
    const minZ = 0.6;
    const maxZ = 20.0;
    // 对数插倦：t=0 → 0.6，t=1 → 20
    return minZ * math.pow(maxZ / minZ, t);
  }

  static double _zoomToSlider(double zoom) {
    const minZ = 0.6;
    const maxZ = 20.0;
    return math.log(zoom / minZ) / math.log(maxZ / minZ);
  }

  // 根据缩放倍率计算等效焦距（行业标准：x1.0 ≈ 28mm 全画幅等效）
  // 参考：手机主摄 26-28mm，x0.6 ≈ 16mm，x2 ≈ 56mm，x5 ≈ 130mm，x10 ≈ 260mm，x20 ≈ 520mm
  static String _focalLabel(double zoom) {
    final mm = (26.0 * zoom).round();
    return '${mm}mm';
  }

  @override
  Widget build(BuildContext context) {
    final sliderVal = _zoomToSlider(value).clamp(0.0, 1.0);
    final zoomLabel = value == value.roundToDouble()
        ? 'x${value.toInt()}'
        : 'x${value.toStringAsFixed(1)}';
    final focalLabel = _focalLabel(value);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // 重置按钮（点击归 x1.0）
          GestureDetector(
            onTap: onReset,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withAlpha(180),
                border: Border.all(
                  color: Colors.white.withAlpha(60),
                  width: 1,
                ),
              ),
              child: const Center(
                child: Icon(
                  Icons.refresh,
                  color: Colors.white,
                  size: 22,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 水平滑动轨道
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white.withAlpha(80),
                thumbColor: Colors.white,
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 10,
                  elevation: 0,
                ),
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Slider(
                value: sliderVal,
                min: 0.0,
                max: 1.0,
                onChanged: (t) => onChanged(_sliderToZoom(t)),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 当前倍率 + 等效焦距标签
          SizedBox(
            width: 68,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  zoomLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  focalLabel,
                  style: TextStyle(
                    color: Colors.white.withAlpha(160),
                    fontSize: 11,
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

// ─── 小窗 overlay（小窗模式开启时显示在取景框内）────────────────────────────────
// 小窗大小随缩放反比变化：
//   x1.0 → 小窗刚好在取景框边缘（宽度 = 取景框宽度）
//   x20  → 最小（约 1/20 取景框宽）
//   x0.6 → 比 x1.0 还大（但不超过取景框）
// 小窗内显示网格线（当 gridEnabled 时）
// 小窗内显示等效焦距标签
class _MinimapOverlay extends StatelessWidget {
  final double zoomLevel;
  final bool gridEnabled;
  final double areaW;
  final double areaH;

  const _MinimapOverlay({
    required this.zoomLevel,
    required this.gridEnabled,
    required this.areaW,
    required this.areaH,
  });

  /// 计算小窗在取景框内的归一化 Rect（用于拍照时裁剪）
  /// 小窗始终居中，宽高比 = 取景框宽高比
  static Rect calcNormalizedRect(double zoomLevel) {
    // x1.0 时小窗占满取景框（归一化 = 整个画面）
    // 随缩放增大，小窗缩小（反比）
    final scale = (1.0 / zoomLevel).clamp(0.05, 1.0);
    final left = (1.0 - scale) / 2;
    final top = (1.0 - scale) / 2;
    return Rect.fromLTWH(left, top, scale, scale);
  }

  @override
  Widget build(BuildContext context) {
    final scale = (1.0 / zoomLevel).clamp(0.05, 1.0);
    final boxW = areaW * scale;
    final boxH = areaH * scale;
    const radius = 12.0; // 小窗圆角半径

    // 等效焦距标签
    final mm = (26.0 * zoomLevel).round();
    final focalLabel = '${mm}mm';

    // 小窗顶部外侧居中的 Y 坐标：取景框垂直中心 - boxH/2 - 标签高度 - 间距
    // 在 Positioned.fill 的 Stack 中，居中小窗的 top = areaH/2 - boxH/2
    final labelTopOffset = (areaH - boxH) / 2 - 24.0; // 24 = 标签高度+间距

    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            // ── 小窗外部暗化遗罩：用 CustomPaint 绘制“挖空”效果 ──
            Positioned.fill(
              child: CustomPaint(
                painter: _MinimapDimPainter(
                  boxW: boxW,
                  boxH: boxH,
                  radius: radius,
                  areaW: areaW,
                  areaH: areaH,
                ),
              ),
            ),
            // ── 焦距标签：小窗顶部外侧正上方居中 ──
            Positioned(
              top: labelTopOffset.clamp(4.0, areaH),
              left: 0,
              right: 0,
              child: Center(
                child: Text(
                  focalLabel,
                  style: TextStyle(
                    color: Colors.white.withAlpha(230),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    shadows: const [
                      Shadow(color: Colors.black54, blurRadius: 6),
                    ],
                  ),
                ),
              ),
            ),
            // ── 小窗主体：圆角边框 + 内部网格 ──
            Center(
              child: SizedBox(
                width: boxW,
                height: boxH,
                child: Stack(
                  children: [
                    // 圆角边框
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(radius),
                          border: Border.all(
                            color: Colors.white.withAlpha(220),
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                    // 圆角裁剪的网格线（仅在 gridEnabled 时显示）
                    if (gridEnabled)
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(radius),
                          child: CustomPaint(
                            painter: _GridPainter(),
                          ),
                        ),
                      ),
                    // 四角 L 形角标
                    ..._buildCorners(boxW, boxH),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildCorners(double w, double h) {
    const len = 12.0;
    const thick = 2.0;
    const color = Colors.white;
    return [
      // 左上
      Positioned(
        left: 0, top: 0,
        child: _Corner(len: len, thick: thick, color: color,
            showRight: true, showBottom: true),
      ),
      // 右上
      Positioned(
        right: 0, top: 0,
        child: _Corner(len: len, thick: thick, color: color,
            showLeft: true, showBottom: true),
      ),
      // 左下
      Positioned(
        left: 0, bottom: 0,
        child: _Corner(len: len, thick: thick, color: color,
            showRight: true, showTop: true),
      ),
      // 右下
      Positioned(
        right: 0, bottom: 0,
        child: _Corner(len: len, thick: thick, color: color,
            showLeft: true, showTop: true),
      ),
    ];
  }
}

class _Corner extends StatelessWidget {
  final double len;
  final double thick;
  final Color color;
  final bool showTop;
  final bool showBottom;
  final bool showLeft;
  final bool showRight;

  const _Corner({
    required this.len,
    required this.thick,
    required this.color,
    this.showTop = false,
    this.showBottom = false,
    this.showLeft = false,
    this.showRight = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: len,
      height: len,
      child: CustomPaint(
        painter: _CornerPainter(
          color: color,
          thick: thick,
          showTop: showTop,
          showBottom: showBottom,
          showLeft: showLeft,
          showRight: showRight,
        ),
      ),
    );
  }
}

class _CornerPainter extends CustomPainter {
  final Color color;
  final double thick;
  final bool showTop, showBottom, showLeft, showRight;

  const _CornerPainter({
    required this.color,
    required this.thick,
    this.showTop = false,
    this.showBottom = false,
    this.showLeft = false,
    this.showRight = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = thick
      ..style = PaintingStyle.stroke;
    if (showTop) canvas.drawLine(Offset(0, 0), Offset(size.width, 0), paint);
    if (showBottom) canvas.drawLine(Offset(0, size.height), Offset(size.width, size.height), paint);
    if (showLeft) canvas.drawLine(Offset(0, 0), Offset(0, size.height), paint);
    if (showRight) canvas.drawLine(Offset(size.width, 0), Offset(size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(_CornerPainter old) =>
      old.color != color || old.thick != thick;
}

// ─── 小窗外部暗化遮罩 Painter ─────────────────────────────────────────────────
// 在整个取景框上绘制半透明黑色，中央挖出圆角矩形（小窗区域保持透明）
class _MinimapDimPainter extends CustomPainter {
  final double boxW;
  final double boxH;
  final double radius;
  final double areaW;
  final double areaH;

  const _MinimapDimPainter({
    required this.boxW,
    required this.boxH,
    required this.radius,
    required this.areaW,
    required this.areaH,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 小窗居中的 Rect
    final cx = size.width / 2;
    final cy = size.height / 2;
    final boxRect = Rect.fromCenter(
      center: Offset(cx, cy),
      width: boxW,
      height: boxH,
    );
    final rrect = RRect.fromRectAndRadius(boxRect, Radius.circular(radius));

    // 用 EvenOdd 填充规则：外部矩形 - 内部圆角矩形 = 遮罩区域
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(rrect)
      ..fillType = PathFillType.evenOdd;

    final paint = Paint()
      ..color = Colors.black.withAlpha(110) // 约 43% 透明度，外部暗化
      ..style = PaintingStyle.fill;

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_MinimapDimPainter old) =>
      old.boxW != boxW || old.boxH != boxH || old.radius != radius;
}
