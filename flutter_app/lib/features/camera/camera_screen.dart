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
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../models/camera_definition.dart';
import '../../models/camera_registry.dart';
import '../../services/camera_service.dart';
import '../../services/location_service.dart';
import 'camera_notifier.dart';
import 'camera_manager_screen.dart';
import '../settings/settings_screen.dart';
import 'preview_renderer.dart';
import '../gallery/gallery_screen.dart';
import 'camera_config_sheet.dart';
import '../../services/shutter_sound_service.dart';
import 'camera_sample_screen.dart';
import '../image_edit/image_edit_screen.dart';
import '../../services/camera_manager_service.dart';
import '../../models/watermark_styles.dart';
// ─── 颜色常量 ─────────────────────────────────────────────────────────────────────────────
const _kBlack = Color(0xFF000000);
const _kDarkGray = Color(0xFF1C1C1E);
const _kLightGray = Color(0xFF3A3A3C);
const _kWhite = Colors.white;
const _kBlue = Color(0xFF007AFF);
const _kRed = Color(0xFFFF3B30);

// ─── 布局常量（提升为顶层常量，供多个方法共享）─────────────────────────────────────────────────────────────────────────────
const kToolbarH = 52.0;          // 工具栏高度
const kShutterH = 88.0;           // 快门行高度
const kBottomPanelTopPad = 0.0;   // 工具栏上方间距
const kToolbarShutterGap = 10.0;  // 工具栏和快门行间距
const kBottomPanelH = kBottomPanelTopPad + kToolbarH + kToolbarShutterGap + kShutterH;
const kCapsuleH = 40.0;           // 胶囊高度（参考图约40px）
const kCapsuleInsetBottom = 8.0;  // 胶囊距取景框底部的内边距（胶囊下移8px）
const kSliderAreaH = 72.0;        // 胶囊下方滑条展开区域预留高度（不能小于滑条内容高度44px）
const kViewfinderHPadding = 8.0;  // 取景框左右边距（参考图约8px，贴边显示）
const kTopBarH = 44.0;
// 宽屏适配：取景框最大宽度（平板/折叠屏展开态限制取景框不超过此宽度，避免画面过宽失调）
// 普通手机最宽约 430dp，此值确保宽屏设备取景框宽度与手机体验一致
const kMaxViewfinderW = 520.0;
// 宽屏适配：底部控件区（工具栏+快门行+顶部菜单）最大内容宽度
const kMaxBottomContentW = 500.0;

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

  // ── 设备方向监听 ───────────────────────────────────────────────────────────────────────────────────
  // 当前设备方向：0=竖屏正向, 1=横屏90度(逆时针), 2=倒竖, 3=横屏270度(顺时针)
  int _deviceQuarter = 0;
  // 旋转动画控制器（工具栏图标旋转动画）
  late AnimationController _rotateAnim;
  late Animation<double> _rotateAngle;
  double _prevAngle = 0.0;
  StreamSubscription<AccelerometerEvent>? _accelSub;

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

    // 旋转动画控制器
    _rotateAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _rotateAngle = Tween<double>(begin: 0.0, end: 0.0).animate(
      CurvedAnimation(parent: _rotateAnim, curve: Curves.easeOutCubic),
    );

    // 启动加速度计监听
    _startOrientationListener();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 一次性请求所有权限（相机 + 相册），再初始化
      await _requestPermissions();
      if (mounted) {
        // 加载相机 JSON 配置
        ref.read(cameraAppProvider.notifier).initialize();
        // 初始化原生相机硬件（获取 textureId，开始预览）
        await ref.read(cameraServiceProvider.notifier).initCamera();
        // 同步清晰度档位对应的原生分辨率（initCamera 默认 1080p，需根据当前档位切换）
        // IMPORTANT: must await — native camera must finish reconfiguring before
        // the loading overlay is dismissed and takePhoto is allowed.
        final sharpenLevel = ref.read(cameraAppProvider).sharpenLevel;
        const sharpenLevels = [0.0, 0.5, 1.0];
        await ref.read(cameraServiceProvider.notifier).setSharpen(sharpenLevels[sharpenLevel]);
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
    _rotateAnim.dispose();
    _accelSub?.cancel();
    super.dispose();
  }

  /// 启动加速度计监听，检测设备方向并驱动旋转动画
  void _startOrientationListener() {
    _accelSub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 200),
    ).listen((AccelerometerEvent event) {
      // x: 正=右倾, 负=左倾
      // y: 正=上立, 负=倒立
      final x = event.x;
      final y = event.y;
      final absX = x.abs();
      final absY = y.abs();

      // 触发阈値：主轴必须超过 5.5，且主轴必须比副轴大 2.0 倍，避免轻微倾斜就触发旋转
      const double kPrimaryThreshold = 5.5;
      const double kDominanceRatio = 2.0;
      int newQuarter;
      if (absY > absX && absY > kPrimaryThreshold && absY > absX * kDominanceRatio) {
        // 以氪屏为主
        newQuarter = y > 0 ? 0 : 2; // 0=氪屏正向, 2=倒氪
      } else if (absX > absY && absX > kPrimaryThreshold && absX > absY * kDominanceRatio) {
        // 以横屏为主
        newQuarter = x > 0 ? 3 : 1; // 1=逆时针横屏(左转90°), 3=顺时针横屏(右转90°)
      } else {
        return; // 不满足阈値，不更新方向
      }

      if (newQuarter != _deviceQuarter) {
        // 计算目标旋转角度（工具栏图标旋转方向）
        final targetAngle = _quarterToAngle(newQuarter);
        // 选择最短旋转路径
        double delta = targetAngle - _prevAngle;
        if (delta > math.pi) delta -= 2 * math.pi;
        if (delta < -math.pi) delta += 2 * math.pi;
        final newAngle = _prevAngle + delta;

        setState(() {
          _deviceQuarter = newQuarter;
          _rotateAngle = Tween<double>(
            begin: _prevAngle,
            end: newAngle,
          ).animate(CurvedAnimation(parent: _rotateAnim, curve: Curves.easeOutCubic));
          _prevAngle = newAngle;
        });
        _rotateAnim
          ..reset()
          ..forward();
      }
    });
  }

  /// 将设备方向转换为工具栏图标的旋转角度（弧度）
  double _quarterToAngle(int quarter) {
    switch (quarter) {
      case 0: return 0.0;              // 竖屏正向：图标不旋转
      case 1: return -math.pi / 2;    // 逆时针横屏：图标顺时针旋转90°
      case 2: return math.pi;          // 倒竖：图标旋转180°
      case 3: return math.pi / 2;     // 顺时针横屏：图标逆时针旋转90°
      default: return 0.0;
    }
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

  /// 进入二级页面时暂停相机预览，返回后自动恢复，并显示过渡动画。
  Future<void> _pushWithCameraPause(Widget page) async {
    // 1. 显示过渡动画（黑屏 + icon）
    _transitionTimer?.cancel();
    setState(() => _showTransition = true);
    await Future.delayed(const Duration(milliseconds: 180));
    // 2. 暂停原生相机预览（释放 GPU/CPU 资源）
    await ref.read(cameraServiceProvider.notifier).stopPreview();
    // 3. push 到二级页面，await 等待返回
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => page),
    );
    // 4. 返回后重新初始化相机（重新获取 textureId）
    // 注意：不能只用 startPreview，因为 stopSession 后 MetalRenderer 停止推帧，
    // Flutter 的 Texture widget 会冻结在最后一帧。必须重新 initCamera 才能恢复实时预览。
    if (!mounted) return;
    await ref.read(cameraServiceProvider.notifier).initCamera();
    // 同步清晰度档位对应的原生分辨率
    // IMPORTANT: must await so the transition overlay stays visible until the
    // native camera is fully reconfigured at the correct resolution.
    final sharpenLevelBack = ref.read(cameraAppProvider).sharpenLevel;
    const sharpenLevelsBack = [0.0, 0.5, 1.0];
    await ref.read(cameraServiceProvider.notifier).setSharpen(sharpenLevelsBack[sharpenLevelBack]);
    // 5. 淡出过渡动画（setSharpen 完成后再淡出，确保分辨率已切换）
    _transitionTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _showTransition = false);
    });
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
    // 播放快门声音（如果已开启）
    if (st.shutterSoundEnabled) {
      ShutterSoundService.instance.play(st.activeCameraId);
    }
    // 小窗模式开启时，计算小窗在取景框内的归一化坐标
    Rect? minimapRect;
    if (st.minimapEnabled) {
      minimapRect = _MinimapOverlay.calcNormalizedRect(st.zoomLevel);
    }
    final result = await ref.read(cameraAppProvider.notifier).takePhoto(
      minimapNormalizedRect: minimapRect,
      deviceQuarter: _deviceQuarter,
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
    // 宽屏设备（平板/折叠屏）限制取景框最大宽度，避免画面过宽失调
    final maxVfW = (screenW - kViewfinderHPadding * 2).clamp(0.0, kMaxViewfinderW);
    double viewfinderW;
    double viewfinderH;
    if (aspectRatio < 0.75) {
      // 竖向比例（如 9:16 = 0.5625）：高度撑满可用空间，宽度按比例缩窄
      viewfinderH = maxViewfinderH;
      viewfinderW = (viewfinderH * aspectRatio).clamp(0.0, maxVfW);
    } else {
      // 横向或方形比例（1:1, 3:4, 2:3）：宽度撑满（受宽屏限制），高度按比例
      viewfinderW = maxVfW;
      viewfinderH = (viewfinderW / aspectRatio).clamp(viewfinderW * 0.5, maxViewfinderH);
    }
    // 取景框在顶部栏和底部面板之间的可用空间内垂直居中
    // 注意：去掉 clamp 上限，确保 1:1/3:4 等比例下取景框能真正居中
    final availableH = maxViewfinderH;
    final viewfinderTopOffset = statusBarH + kTopBarH + ((availableH - viewfinderH) / 2).clamp(0.0, availableH);
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
                child: SizedBox(
                  width: 56,
                  height: kTopBarH,
                  child: Center(
                    child: AnimatedBuilder(
                      animation: _rotateAngle,
                      builder: (_, __) => Transform.rotate(
                        angle: _rotateAngle.value,
                        child: const Text(
                          '•••',
                          style: TextStyle(
                            color: _kWhite,
                            fontSize: 16,
                            letterSpacing: 0,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // ── 取景框（圆角，垂直居中，水平居中）──
          // PhysicalModel 强制 GPU 层圆角裁剪，解决 Android Texture 直角问题
          Positioned(
            top: viewfinderTopOffset,
            left: viewfinderLeft,
            child: PhysicalModel(
              color: Colors.black,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: viewfinderW,
                height: viewfinderH,
                child: _buildViewfinderArea(st, camSvc, viewfinderH, viewfinderW),
              ),
            ),
          ),
          // ── 控制胶囊：固定浮层，与取景框大小/比例/缩放全部无关 ──
          // 从底部往上算：底部面板 + 安全区 + 滑条区 + 内边距
          // 视觉上贴着取景框底部内侧边缘，实际是独立浮层
          Positioned(
            left: viewfinderLeft,
            right: viewfinderLeft,
            bottom: kBottomPanelH + bottomSafeH + kSliderAreaH + kCapsuleInsetBottom,
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
      clipBehavior: Clip.hardEdge, // 强制裁剪，防止 OverflowBox 内容溢出圆角边界
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 相机预览
          _buildPreview(st, camSvc),
          // 三等分网格线：小窗开启时网格移入小窗内部，小窗关闭时全局显示
          if (st.gridEnabled && !st.minimapEnabled) _buildGrid(),
          // 调试信息浮层（开发调试用）
          if (st.showDebugOverlay)
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: _DebugOverlay(st: st),
            ),
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
                // 小窗模式下最大缩放 10x（防止小窗缩到 120mm 以下）
                // 正常模式最大 20x
                final maxZoom = ref.read(cameraAppProvider).minimapEnabled ? 10.0 : 20.0;
                final newZoom = (_pinchStartZoom * d.scale).clamp(0.6, maxZoom);
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

          // ── 鱼眼圆圈默色边角阒罩 overlay（fisheyeMode 开启时显示）──
          if (st.fisheyeMode)
            IgnorePointer(
              child: CustomPaint(
                size: Size.infinite,
                painter: _FisheyeCirclePainter(),
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
          const SizedBox(height: 35),
          const SizedBox(height: kToolbarShutterGap),
          // 快门行
          _buildShutterRow(st),
          // 底部安全区域已移入 _buildShutterRow
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
          // 样图按钮（显示当前相机图标，点击跳转到当前相机的样片页）
          GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              _pushWithCameraPause(CameraSampleScreen(cameraId: st.activeCameraId));
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF3A3A3C),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 当前相机图标（圆角小图）
                  Builder(builder: (_) {
                    final entry = kAllCameras.where((e) => e.id == st.activeCameraId).firstOrNull;
                    final iconPath = entry?.iconPath;
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: iconPath != null
                          ? Image.asset(iconPath, width: 18, height: 18, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined, color: _kWhite, size: 14))
                          : const Icon(Icons.image_outlined, color: _kWhite, size: 14),
                    );
                  }),
                  const SizedBox(width: 5),
                  const Text('样图', style: TextStyle(color: _kWhite, fontSize: 13)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 管理按钮
          GestureDetector(
            onTap: () {
              _pushWithCameraPause(const CameraManagerScreen());
            },
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

  // ── 相机列表（横向滚动，从 cameraManagerProvider 读取启用且有序的相机）────────
  Widget _buildCameraList(CameraAppState st) {
    // 从管理状态读取启用且有序的相机 ID 列表
    final managerState = ref.watch(cameraManagerProvider).valueOrNull;
    final enabledIds = managerState?.enabledOrderedIds
        ?? kAllCameras.map((e) => e.id).toList();

    return SizedBox(
      height: 88,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: enabledIds.length,
        itemBuilder: (context, index) {
          final camId = enabledIds[index];
          final entry = kAllCameras.where((e) => e.id == camId).firstOrNull;
          if (entry == null) return const SizedBox.shrink();
          final isActive = st.activeCameraId == camId;
          final iconPath = entry.iconPath;
          final isFavorited = managerState?.favoritedIds.contains(camId) ?? false;

          return GestureDetector(
            onTap: () => _showCameraTransition(
              () => ref.read(cameraAppProvider.notifier).switchToCamera(camId),
              duration: const Duration(milliseconds: 500),
            ),
            child: Container(
              width: 76,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A1A1A),
                          borderRadius: BorderRadius.circular(14),
                          border: isActive
                              ? Border.all(color: _kWhite, width: 2)
                              : Border.all(color: Colors.grey[800]!, width: 1),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(13),
                          child: iconPath != null
                              ? Image.asset(
                                  iconPath,
                                  width: 64,
                                  height: 64,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const Center(
                                    child: Icon(Icons.camera_alt, color: Colors.white54, size: 28),
                                  ),
                                )
                              : const Center(
                                  child: Icon(Icons.camera_alt, color: Colors.white54, size: 28),
                                ),
                        ),
                      ),
                      // 收藏星标（右上角）
                      if (isFavorited)
                        Positioned(
                          top: -3,
                          right: -3,
                          child: Container(
                            width: 16,
                            height: 16,
                            decoration: const BoxDecoration(
                              color: Color(0xFFFFCC00),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.star, color: Colors.black, size: 10),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    entry.name,
                    style: TextStyle(
                      color: isActive ? _kWhite : Colors.grey,
                      fontSize: 10,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
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
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (_showWbPanel || st.wbMode != 'auto')
                  ? Colors.white.withAlpha(230)
                  : Colors.black.withAlpha(160),
            ),
            child: Center(
              child: AnimatedBuilder(
                animation: _rotateAngle,
                builder: (_, __) => Transform.rotate(
                  angle: _rotateAngle.value,
                  child: Icon(
                    _showWbPanel ? Icons.keyboard_arrow_down : Icons.thermostat_outlined,
                    size: 16,
                    color: (_showWbPanel || st.wbMode != 'auto') ? Colors.black : _kWhite,
                  ),
                ),
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
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: st.showZoomSlider
                  ? Colors.white.withAlpha(230)
                  : Colors.black.withAlpha(160),
            ),
            child: Center(
              child: AnimatedBuilder(
                animation: _rotateAngle,
                builder: (_, __) => Transform.rotate(
                  angle: _rotateAngle.value,
                  child: Text(
                    zoomLabel,
                    style: TextStyle(
                      color: st.showZoomSlider ? Colors.black : _kWhite,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
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
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: (_showExposureSlider || st.exposureValue != 0)
                  ? Colors.white.withAlpha(230)
                  : Colors.black.withAlpha(160),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _showExposureSlider ? Icons.keyboard_arrow_down : Icons.wb_sunny_outlined,
                  size: 14,
                  color: (_showExposureSlider || st.exposureValue != 0) ? Colors.black : _kWhite,
                ),
                const SizedBox(width: 5),
                AnimatedBuilder(
                  animation: _rotateAngle,
                  builder: (_, __) => Transform.rotate(
                    angle: _rotateAngle.value,
                    child: Text(
                      st.exposureValue == 0
                          ? '0.0'
                          : (st.exposureValue > 0 ? '+' : '') +
                              st.exposureValue.toStringAsFixed(1),
                      style: TextStyle(
                        color: (_showExposureSlider || st.exposureValue != 0) ? Colors.black : _kWhite,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
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
    const double btnW = 64.0;
    return SizedBox(
      height: 52,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 1. 导入图片
            SizedBox(
              width: btnW,
              child: _RotatingToolbarBtn(
                rotateAnimation: _rotateAngle,
                rotateController: _rotateAnim,
                child: _ToolbarBtn(
                  icon: Icons.add_photo_alternate_outlined,
                  label: '导入图片',
                  onTap: () => openImageImportFlow(context),
                ),
              ),
            ),
            // 2. 倒计时
            SizedBox(
              width: btnW,
              child: _RotatingToolbarBtn(
                rotateAnimation: _rotateAngle,
                rotateController: _rotateAnim,
                child: _ToolbarBtn(
                  icon: Icons.timer_outlined,
                  label: '倒计时',
                  badge: st.timerSeconds > 0 ? '${st.timerSeconds}s' : null,
                  onTap: () {
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
              ),
            ),
            // 3. 闪光灯
            SizedBox(
              width: btnW,
              child: _RotatingToolbarBtn(
                rotateAnimation: _rotateAngle,
                rotateController: _rotateAnim,
                child: _FlashBtn(
                  mode: st.flashMode,
                  label: '闪光灯',
                  onTap: () {
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
              ),
            ),
            // 4. 前置/后置切换
            SizedBox(
              width: btnW,
              child: _RotatingToolbarBtn(
                rotateAnimation: _rotateAngle,
                rotateController: _rotateAnim,
                child: _ToolbarBtn(
                  icon: Icons.flip_camera_ios_outlined,
                  label: '后置',
                  onTap: () => _showCameraTransition(
                    () => ref.read(cameraAppProvider.notifier).flipCamera(),
                    duration: const Duration(milliseconds: 500),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 快门行 ──────────────────────────────────────────────────────────────────
  // 截图布局：[缩略图 72×72] [快门 80×80] [相机图标 72×72]
  Widget _buildShutterRow(CameraAppState st) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 88,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: kMaxBottomContentW),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
            // 左侧: 图库缩略图（单击→相册列表，长按→直接打开最新相片详情）
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: GestureDetector(
                  onTap: _openGallery,
                  onLongPress: _openLatestPhotoDetail,
              child: AnimatedBuilder(
                animation: _rotateAngle,
                builder: (_, __) => Transform.rotate(
                  angle: _rotateAngle.value,
                  child: Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: _kDarkGray,
                    ),
                    child: _latestThumb != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.memory(_latestThumb!, fit: BoxFit.cover),
                          )
                        : const Icon(Icons.photo_outlined, color: Colors.grey, size: 24),
                  ),
                ),
                ),
              ),
            ),
            ),
            // 中间: 快门按钮（外圈白色线圈，内圆白色实心）
            GestureDetector(
              onTap: st.isTakingPhoto ? null : _handleShutter,
              child: Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.transparent,
                  border: Border.all(color: _kWhite, width: 3.5),
                ),
                child: Center(
                  child: Container(
                    width: 66,
                    height: 66,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: _kWhite,
                    ),
                  ),
                ),
              ),
            ),
            // 右侧: 相机图标（虚线圆圈背景，点击打开相机配置）
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: GestureDetector(
                  onTap: () => showCameraConfigSheet(context),
              child: SizedBox(
                width: 97,
                height: 97,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // 虚线圆圈背景（圆圈大小 70，图标不变）
                    CustomPaint(
                      size: const Size(70, 70),
                      painter: _DashedCirclePainter(),
                    ),
                    // 相机图标 + 名称（跟随设备方向旋转）
                    AnimatedBuilder(
                      animation: _rotateAngle,
                      builder: (_, __) => Transform.rotate(
                        angle: _rotateAngle.value,
                        child: Builder(builder: (ctx) {
                          final entry = kAllCameras.firstWhere(
                            (e) => e.id == st.activeCameraId,
                            orElse: () => kAllCameras.first,
                          );
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              // 优先使用真实相机图标，如果没有则用系统图标
                              if (entry.iconPath != null)
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Image.asset(
                                    entry.iconPath!,
                                    width: 69,
                                    height: 69,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        const Icon(Icons.photo_camera_outlined, color: _kWhite, size: 68),
                                  ),
                                )
                              else
                                const Icon(Icons.photo_camera_outlined, color: _kWhite, size: 36),
                              Text(
                                entry.name,
                                style: const TextStyle(
                                  color: _kWhite,
                                  fontSize: 8,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.3,
                                  height: 1.0,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          );
                        }),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10), // 底部安全区
      ],
    );
  }

  // ── 右上角菜单弹框（"..."展开）──────────────────────────────────────────────
  Widget _buildTopMenuOverlay(CameraAppState st) {
    final mq = MediaQuery.of(context);
    // 复刻截图样式：深棕色半透明圆角卡片，覆盖取景框顶部
    final menuTop = mq.padding.top + kTopBarH - 30;
    final sharpenLabels = ['低', '中', '高'];
    // 按鈕实际宽度 = (屏幕宽 - 左右padding) / 4
    final screenW = mq.size.width;
    // 宽屏限制：btnW 最大 160dp，避免平板上按鈕过宽
    // 容器 maxWidth = screenW-16，margin=8*2=16，padding=16*2=32 → 可用内容宽 = screenW-64
    // 4个按鈕平分该宽度，防止溢出
    final btnW = ((screenW - 64) / 4).clamp(0.0, 160.0);
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
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: screenW > 600
                        ? (kMaxBottomContentW + 32)
                        : (screenW - 16),
                  ),
                  child: GestureDetector(
                    onTap: () {}, // 阻止穿透
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        // 深棕色半透明背景（对齐截图中的深色卡片）
                        color: const Color(0xE5202020),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
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
                            btnW: btnW,
                            onTap: () => ref.read(cameraAppProvider.notifier).toggleGrid(),
                          ),
                          // 2. 清晰度（循环切换 低/中/高）
                          _TopMenuBtn(
                            customIcon: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.white, width: 1.5),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Center(
                                child: Text(
                                  sharpenLabels[st.sharpenLevel],
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    height: 1,
                                  ),
                                ),
                              ),
                            ),
                            label: '清晰度',
                            btnW: btnW,
                            onTap: () => _showCameraTransition(
                              () => ref.read(cameraAppProvider.notifier).cycleSharpen(),
                              duration: const Duration(milliseconds: 350),
                            ),
                          ),
                          // 3. 小框模式
                          _TopMenuBtn(
                            icon: st.minimapEnabled
                                ? Icons.picture_in_picture
                                : Icons.picture_in_picture_outlined,
                            label: st.minimapEnabled ? '小框模式开启' : '小框模式关闭',
                            btnW: btnW,
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
                            btnW: btnW,
                            onTap: () {},
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      // 第二行: 2个图标 + 2个占位（保持等宽对齐）
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // 5. 连拍
                          _TopMenuBtn(
                            icon: Icons.burst_mode_outlined,
                            label: '连拍关闭',
                            btnW: btnW,
                            onTap: () {},
                          ),
                          // 6. 位置信息
                          _TopMenuBtn(
                            icon: st.locationEnabled
                                ? Icons.location_on
                                : Icons.location_off_outlined,
                            label: st.locationEnabled ? '位置开启' : '位置关闭',
                            btnW: btnW,
                            onTap: () async {
                              final result = await ref.read(cameraAppProvider.notifier).toggleLocation();
                              if (!context.mounted) return;
                              switch (result) {
                                case LocationToggleResult.enabled:
                                  _showViewfinderHint('位置信息已开启');
                                  break;
                                case LocationToggleResult.disabled:
                                  _showViewfinderHint('位置信息已关闭');
                                  break;
                                case LocationToggleResult.permissionDenied:
                                  _showViewfinderHint('位置权限被拒绝');
                                  break;
                                case LocationToggleResult.permissionDeniedForever:
                                  // 引导用户到系统设置
                                  showDialog(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      backgroundColor: const Color(0xFF1C1C1E),
                                      title: const Text('需要位置权限',
                                          style: TextStyle(color: Colors.white)),
                                      content: const Text(
                                        '请在设置中开启位置权限，以将 GPS 坐标记录到照片',
                                        style: TextStyle(color: Colors.grey),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(ctx),
                                          child: const Text('取消',
                                              style: TextStyle(color: Colors.grey)),
                                        ),
                                        TextButton(
                                          onPressed: () {
                                            Navigator.pop(ctx);
                                            LocationService.instance.openSettings();
                                          },
                                          child: const Text('去设置',
                                              style: TextStyle(color: Color(0xFFFF9500))),
                                        ),
                                      ],
                                    ),
                                  );
                                  break;
                              }
                            },
                          ),
                          // 7. 设置
                          _TopMenuBtn(
                            icon: Icons.settings_outlined,
                            label: '设置',
                            btnW: btnW,
                            onTap: () {
                              ref.read(cameraAppProvider.notifier).toggleTopMenu();
                              _pushWithCameraPause(const SettingsScreen());
                            },
                          ),
                          // 8. 调试信息浮层
                          _TopMenuBtn(
                            icon: st.showDebugOverlay
                                ? Icons.bug_report
                                : Icons.bug_report_outlined,
                            label: st.showDebugOverlay ? '调试开启' : '调试关闭',
                            btnW: btnW,
                            onTap: () {
                              ref.read(cameraAppProvider.notifier).toggleDebugOverlay();
                              ref.read(cameraAppProvider.notifier).toggleTopMenu();
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
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
    _pushWithCameraPause(const GalleryScreen());
  }

  // ── 长按：直接打开最新相片详情，返回后回到相册列表 ─────────────────────────
  void _openLatestPhotoDetail() {
    if (_latestAsset == null) {
      // 没有照片时，单纯打开相册
      _openGallery();
      return;
    }
    HapticFeedback.mediumImpact();
    _pushWithCameraPause(GalleryScreen(initialAsset: _latestAsset));
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
                    _buildManagedCameraSection(context, ref, st),
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

  // ── Photo 相机选择（从 cameraManagerProvider 读取启用且有序的相机）─────────────
  Widget _buildManagedCameraSection(BuildContext context, WidgetRef ref, CameraAppState st) {
    final managerState = ref.watch(cameraManagerProvider).valueOrNull;
    final enabledIds = managerState?.enabledOrderedIds
        ?? kAllCameras.map((e) => e.id).toList();

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
            child: const Text('Photo', style: TextStyle(color: _kWhite, fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ),
        SizedBox(
          height: 110,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: enabledIds.length,
            itemBuilder: (ctx, i) {
              final camId = enabledIds[i];
              final entry = kAllCameras.where((e) => e.id == camId).firstOrNull;
              if (entry == null) return const SizedBox.shrink();
              final isActive = st.activeCameraId == camId;
              final isFavorited = managerState?.favoritedIds.contains(camId) ?? false;

              return GestureDetector(
                onTap: () {
                  onCameraTransition(
                    () => ref.read(cameraAppProvider.notifier).switchToCamera(camId),
                    duration: const Duration(milliseconds: 500),
                  );
                  onClose();
                },
                child: Container(
                  width: 80,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  child: Column(
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
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
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(13),
                              child: entry.iconPath != null
                                  ? Image.asset(
                                      entry.iconPath!,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => const Icon(
                                        Icons.camera_alt,
                                        color: Colors.white54,
                                        size: 32,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.camera_alt,
                                      color: Colors.white54,
                                      size: 32,
                                    ),
                            ),
                          ),
                          if (isFavorited)
                            Positioned(
                              top: -3,
                              right: -3,
                              child: Container(
                                width: 16,
                                height: 16,
                                decoration: const BoxDecoration(
                                  color: Color(0xFFFFCC00),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.star, color: Colors.black, size: 10),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        entry.name,
                        style: TextStyle(
                          color: isActive ? _kWhite : Colors.grey,
                          fontSize: 11,
                          fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        textAlign: TextAlign.center,
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
    // 当前比例是否支持边框
    final currentRatioSupportsFrame = camera?.ratioById(st.activeRatioId)?.supportsFrame ?? false;
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
              // 边框（仅在当前比例支持边框时显示）
              if (currentRatioSupportsFrame)
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

/// 工具栏图标旋转包装器：设备方向改变时，图标带动画旋转保持正局
/// 整个 UI 保持竖屏，只有图标内容旋转
class _RotatingToolbarBtn extends StatelessWidget {
  final Animation<double> rotateAnimation;
  final AnimationController rotateController;
  final Widget child;

  const _RotatingToolbarBtn({
    required this.rotateAnimation,
    required this.rotateController,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: rotateAnimation,
      builder: (context, _) {
        return Transform.rotate(
          angle: rotateAnimation.value,
          child: child,
        );
      },
    );
  }
}

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
      child: SizedBox(
        width: 68,
        child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(icon, color: _kWhite, size: 22),
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
            const SizedBox(height: 3),
            Text(label!, style: const TextStyle(color: Colors.white70, fontSize: 10)),
          ],
        ],
        ),
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
    final isAuto = mode == 'auto';
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 68,
        child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  Icons.flash_on,
                  color: isOff ? _kWhite : _kRed,
                  size: 22,
                ),
                if (isOff)
                  CustomPaint(
                    size: const Size(22, 22),
                    painter: _StrikethroughPainter(),
                  ),
                if (isAuto)
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                      decoration: BoxDecoration(
                        color: _kBlue,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('A', style: TextStyle(color: _kWhite, fontSize: 8, fontWeight: FontWeight.w700)),
                    ),
                  ),
              ],
            ),
          ),
          if (label != null) ...[  
            const SizedBox(height: 3),
            Text(label!, style: const TextStyle(color: Colors.white70, fontSize: 10)),
          ],
        ],
        ),
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
  final double btnW;

  const _TopMenuBtn({
    this.icon,
    this.customIcon,
    required this.label,
    required this.onTap,
    this.btnW = 72,
  }) : assert(icon != null || customIcon != null);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: btnW,
        // 固定总高度：图标区(32) + 间距(8) + 文字区(36) = 76
        // 文字区固定高度确保所有按鈕图标对齐
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 图标区域：固定 32×32，始终居中
            SizedBox(
              width: 32,
              height: 32,
              child: Center(
                child: customIcon ?? Icon(icon!, color: _kWhite, size: 30),
              ),
            ),
            const SizedBox(height: 8),
            // 文字区域：固定高度 36px，防止换行时高度变化导致图标错位
            SizedBox(
              height: 36,
              child: Align(
                alignment: Alignment.topCenter,
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    height: 1.3,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
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
  _CameraItem(id: 'grd_r', name: 'GRD', emoji: '📷', hasR: true),
  _CameraItem(id: 'fxn_r', name: 'FXN', emoji: '📷', hasR: true),
  _CameraItem(id: 'inst_sq', name: 'INST SQ', emoji: '🎞'),
  _CameraItem(id: 'bw_classic', name: 'BW', emoji: '⬛'),
  _CameraItem(id: 'ccd_m', name: 'CCD M', emoji: '📸'),
  _CameraItem(id: 'd_classic', name: 'D Classic', emoji: '📷'),
  _CameraItem(id: 'inst_c', name: 'INST C', emoji: '🎞'),
  _CameraItem(id: 'inst_s', name: 'INST S', emoji: '🎞'),
  _CameraItem(id: 'u300', name: 'U300', emoji: '📷'),
  _CameraItem(id: 'fisheye', name: 'FISHEYE', emoji: '🔵'),
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // K 値数字（居中，白色）
          Text(
            '${colorTempK}K',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
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
                      height: 30,
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
                          enabledThumbRadius: 10,
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
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          // 激活时：白色实心圆（对齐截图中 A 按鈕选中效果）
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
      overlayColor = Color(0xFFE8A05A).withValues(alpha: opacity);
    } else {
      // 偏冷：蓝色叠加
      final t = (colorTempK - neutralK) / (maxCool - neutralK);
      opacity = (t * 0.18).clamp(0.0, 0.18);
      overlayColor = Color(0xFF6B8FE8).withValues(alpha: opacity);
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
// 小窗边框圆角（与取景框一致）
const _kMinimapRadius = 16.0;

class _MinimapOverlay extends StatefulWidget {
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
  static Rect calcNormalizedRect(double zoomLevel) {
    final scale = (1.0 / zoomLevel).clamp(0.05, 1.0);
    final left = (1.0 - scale) / 2;
    final top = (1.0 - scale) / 2;
    return Rect.fromLTWH(left, top, scale, scale);
  }

  @override
  State<_MinimapOverlay> createState() => _MinimapOverlayState();
}

class _MinimapOverlayState extends State<_MinimapOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _borderAnim;
  late Animation<double> _borderOpacity;

  @override
  void initState() {
    super.initState();
    _borderAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _borderOpacity = CurvedAnimation(
      parent: _borderAnim,
      curve: Curves.easeInOut,
    );
    // 初始状态：根据当前缩放判断边框可见性
    if (widget.zoomLevel > 1.0) {
      _borderAnim.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(_MinimapOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.zoomLevel != widget.zoomLevel) {
      if (widget.zoomLevel > 1.0) {
        _borderAnim.forward();
      } else {
        _borderAnim.reverse();
      }
    }
  }

  @override
  void dispose() {
    _borderAnim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = (1.0 / widget.zoomLevel).clamp(0.05, 1.0);
    final boxW = widget.areaW * scale;
    final boxH = widget.areaH * scale;
    const radius = _kMinimapRadius;
    // 等效焦距标签
    final mm = (26.0 * widget.zoomLevel).round();
    final focalLabel = '${mm}mm';
    // 胶片文字固定在取景框顶部（不随小窗缩放移动）
    const labelTopFixed = 12.0;

    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            // ── 小窗外部暗化遮罩：用 CustomPaint 绘制"挖空"效果 ──
            Positioned.fill(
              child: CustomPaint(
                painter: _MinimapDimPainter(
                  boxW: boxW,
                  boxH: boxH,
                  radius: radius,
                  areaW: widget.areaW,
                  areaH: widget.areaH,
                ),
              ),
            ),
            // ── 小窗主体：圆角边框 + 内部网格（居中）──
            Center(
              child: SizedBox(
                width: boxW,
                height: boxH,
                child: Stack(
                  children: [
                    // 圆角边框（缩放≤1时淡出）
                    Positioned.fill(
                      child: FadeTransition(
                        opacity: _borderOpacity,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(radius),
                            border: Border.all(
                              color: Colors.white.withAlpha(220),
                              width: 1.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 圆角裁剪的网格线（仅在 gridEnabled 时显示）
                    if (widget.gridEnabled)
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(radius),
                          child: CustomPaint(painter: _GridPainter()),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // ── 胶片文字：固定在取景框顶部，不随小窗大小变化 ──
            Positioned(
              top: labelTopFixed,
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
          ],
        ),
      ),
    );
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
    // 用 EvenOdd 填充规则：外部矩形 - 内部小窗矩形 = 遗罩区域
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    if (radius > 0) {
      final rrect = RRect.fromRectAndRadius(boxRect, Radius.circular(radius));
      path.addRRect(rrect);
    } else {
      path.addRect(boxRect);
    }
    path.fillType = PathFillType.evenOdd;

    final paint = Paint()
      ..color = Colors.black.withAlpha(110) // 约 43% 透明度，外部暗化
      ..style = PaintingStyle.fill;

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_MinimapDimPainter old) =>
      old.boxW != boxW || old.boxH != boxH || old.radius != radius;
}

// ─────────────────────────────────────────────────────────────────────────────
// 取景框实时水印预览 overlay
// 与 capture_pipeline._drawWatermark 保持一致的位置/大小/方向逻辑
// ─────────────────────────────────────────────────────────────────────────────

class _WatermarkPreviewOverlay extends StatelessWidget {
  final WatermarkPreset watermark;
  final String? colorOverride;
  final String? positionOverride;
  final String? sizeOverride;
  final String? directionOverride;
  final String? styleId; // 样式 ID，对应 kWatermarkStyles 中的 id

  const _WatermarkPreviewOverlay({
    required this.watermark,
    this.colorOverride,
    this.positionOverride,
    this.sizeOverride,
    this.directionOverride,
    this.styleId,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: CustomPaint(
        painter: _WatermarkPainter(
          watermark: watermark,
          colorOverride: colorOverride,
          positionOverride: positionOverride,
          sizeOverride: sizeOverride,
          directionOverride: directionOverride,
          styleId: styleId,
        ),
      ),
    );
  }
}

class _WatermarkPainter extends CustomPainter {
  final WatermarkPreset watermark;
  final String? colorOverride;
  final String? positionOverride;
  final String? sizeOverride;
  final String? directionOverride;
  final String? styleId; // 样式 ID，对应 kWatermarkStyles 中的 id

  _WatermarkPainter({
    required this.watermark,
    this.colorOverride,
    this.positionOverride,
    this.sizeOverride,
    this.directionOverride,
    this.styleId,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final now = DateTime.now();
    // 获取样式定义（默认 s1）
    final styleDef = getWatermarkStyle(styleId);
    // 根据样式生成文本
    final text = styleDef.buildText(now);
    // 解析颜色
    Color textColor = const Color(0xFFFF8C00);
    final colorSrc = colorOverride ?? watermark.color;
    if (colorSrc != null && colorSrc.isNotEmpty) {
      try {
        final hex = colorSrc.replaceAll('#', '');
        textColor = Color(int.parse('FF$hex', radix: 16));
      } catch (_) {}
    }

    // 解析大小
    double baseFontSize;
    switch (sizeOverride) {
      case 'small':
        baseFontSize = size.width * 0.028;
        break;
      case 'medium':
        baseFontSize = size.width * 0.038;
        break;
      case 'large':
        baseFontSize = size.width * 0.055;
        break;
      default:
        baseFontSize = size.width * 0.038;
    }
    final fontSize = baseFontSize.clamp(10.0, 60.0);

    // 解析方向
    final isVertical = (directionOverride ?? 'horizontal') == 'vertical';

    // 解析位置
    final position = positionOverride ?? watermark.position ?? 'bottom_right';
    final margin = size.width * 0.04;

    // 样式定义的字体和字间距
    final fontFamily = styleDef.fontFamily ?? watermark.fontFamily;
    final letterSpacing = styleDef.letterSpacing;
    final fontWeight = styleDef.fontWeight;

    if (isVertical) {
      // 垂直水印：逐字符绘制
      final style = TextStyle(
        color: textColor,
        fontSize: fontSize,
        fontFamily: fontFamily,
        fontWeight: fontWeight,
      );
      final charPainters = text.split('').map((c) {
        final p = TextPainter(
          text: TextSpan(text: c, style: style),
          textDirection: TextDirection.ltr,
        )..layout();
        return p;
      }).toList();

      final totalH = charPainters.fold(0.0, (s, p) => s + p.height);
      final charW = charPainters.fold(
          0.0, (s, p) => s > p.width ? s : p.width);

      double startX, startY;
      switch (position) {
        case 'bottom_right':
          startX = size.width - charW - margin;
          startY = size.height - totalH - margin;
          break;
        case 'bottom_left':
          startX = margin;
          startY = size.height - totalH - margin;
          break;
        case 'top_right':
          startX = size.width - charW - margin;
          startY = margin;
          break;
        case 'top_left':
          startX = margin;
          startY = margin;
          break;
        case 'bottom_center':
          startX = (size.width - charW) / 2;
          startY = size.height - totalH - margin;
          break;
        case 'top_center':
          startX = (size.width - charW) / 2;
          startY = margin;
          break;
        default:
          startX = size.width - charW - margin;
          startY = size.height - totalH - margin;
      }

      double curY = startY;
      for (final p in charPainters) {
        p.paint(canvas, Offset(startX + (charW - p.width) / 2, curY));
        curY += p.height;
      }
    } else {
      // 水平水印
      final textPainter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: textColor,
            fontSize: fontSize,
            fontFamily: fontFamily,
            fontWeight: fontWeight,
            letterSpacing: letterSpacing,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width);

      double dx, dy;
      switch (position) {
        case 'bottom_right':
          dx = size.width - textPainter.width - margin;
          dy = size.height - textPainter.height - margin;
          break;
        case 'bottom_left':
          dx = margin;
          dy = size.height - textPainter.height - margin;
          break;
        case 'top_right':
          dx = size.width - textPainter.width - margin;
          dy = margin;
          break;
        case 'top_left':
          dx = margin;
          dy = margin;
          break;
        case 'bottom_center':
          dx = (size.width - textPainter.width) / 2;
          dy = size.height - textPainter.height - margin;
          break;
        case 'top_center':
          dx = (size.width - textPainter.width) / 2;
          dy = margin;
          break;
        default:
          dx = size.width - textPainter.width - margin;
          dy = size.height - textPainter.height - margin;
      }

      textPainter.paint(canvas, Offset(dx, dy));
    }
  }

  @override
  bool shouldRepaint(_WatermarkPainter old) =>
      old.watermark != watermark ||
      old.colorOverride != colorOverride ||
      old.positionOverride != positionOverride ||
      old.sizeOverride != sizeOverride ||
      old.directionOverride != directionOverride ||
      old.styleId != styleId;
}

// ─────────────────────────────────────────────────────────────────────────────
// _DebugOverlay — 调试信息浮层（开发调试用）
// 显示当前相机 ID、滤镜参数、曝光、色温、渲染策略等实时信息
// ─────────────────────────────────────────────────────────────────────────────
class _DebugOverlay extends ConsumerWidget {
  final CameraAppState st;
  const _DebugOverlay({required this.st});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final params = st.renderParams;
    final cam = st.camera;
    final camInfo = ref.watch(cameraServiceProvider).activeCameraDebugInfo;

    final lines = <String>[
      '── DAZZ DEBUG ──',
      'Camera: ${st.activeCameraId}  (${cam?.name ?? "loading"})',
      'Filter: ${st.activeFilterId ?? "none"}  Lens: ${st.activeLensId ?? "default"}',
      'Ratio: ${st.activeRatioId ?? "default"}  Frame: ${st.activeFrameId ?? "none"}',
      '',
      '── Render Params ──',
      if (params != null) ...[
        'Exposure: ${st.exposureValue.toStringAsFixed(2)} EV',
        'Temp: ${params.effectiveTemperature.toStringAsFixed(0)} (offset: ${st.temperatureOffset.toStringAsFixed(0)})',
        'Tint: ${params.effectiveTint.toStringAsFixed(0)}',
        'Contrast: ${params.effectiveContrast.toStringAsFixed(2)}',
        'Saturation: ${params.effectiveSaturation.toStringAsFixed(2)}',
        'Vibrance: ${params.effectiveVibrance.toStringAsFixed(0)}',
        'Highlights: ${params.effectiveHighlights.toStringAsFixed(0)}  Shadows: ${params.effectiveShadows.toStringAsFixed(0)}',
        'Whites: ${params.effectiveWhites.toStringAsFixed(0)}  Blacks: ${params.effectiveBlacks.toStringAsFixed(0)}',
        'Clarity: ${params.effectiveClarity.toStringAsFixed(0)}',
        'Vignette: ${params.effectiveVignette.toStringAsFixed(2)}',
        'Bloom: ${params.effectiveBloom.toStringAsFixed(2)}  SoftFocus: ${params.effectiveSoftFocus.toStringAsFixed(2)}',
        'ChromAb: ${params.effectiveChromaticAberration.toStringAsFixed(3)}',
        'Grain: ${params.effectiveGrain.toStringAsFixed(2)}',
        'ColorBias R:${params.effectiveColorBiasR.toStringAsFixed(2)} G:${params.effectiveColorBiasG.toStringAsFixed(2)} B:${params.effectiveColorBiasB.toStringAsFixed(2)}',
        '',
        '── Policy ──',
        'LUT:${params.policy.enableLut ? "✓" : "✗"} '
            'Temp:${params.policy.enableTemperature ? "✓" : "✗"} '
            'Contrast:${params.policy.enableContrast ? "✓" : "✗"} '
            'Sat:${params.policy.enableSaturation ? "✓" : "✗"}',
        'Vignette:${params.policy.enableVignette ? "✓" : "✗"} '
            'Bloom:${params.policy.enableBloom ? "✓" : "✗"} '
            'ChromAb:${params.policy.enableChromaticAberration ? "✓" : "✗"} '
            'Grain:${params.policy.enableGrain ? "✓" : "✗"}',
      ] else
        'params: null (loading...)',
      '',
      '── UI State ──',
      'Zoom: ${st.zoomLevel.toStringAsFixed(1)}x  Flash: ${st.flashMode}  Timer: ${st.timerSeconds}s',
      'WB: ${st.wbMode} (${st.colorTempK}K)  Front: ${st.isFrontCamera}',
      'Sharpen: ${["\u4f4e", "\u4e2d", "\u9ad8"][st.sharpenLevel]}  Grid: ${st.gridEnabled}  Minimap: ${st.minimapEnabled}',
      '',
      '\u2500\u2500 Capture Resolution \u2500\u2500',
      'Raw: ${st.lastCaptureRaw.isEmpty ? "(not captured yet)" : st.lastCaptureRaw}',
      'Output: ${st.lastCaptureOutput.isEmpty ? "(not captured yet)" : st.lastCaptureOutput}',
      '',
      '── Active Camera (Android) ──',
      if (camInfo.isNotEmpty) ...[
        'ID: ${camInfo["cameraId"] ?? "?"}  Facing: ${camInfo["facing"] ?? "?"}',
        'Sensor: ${camInfo["sensorSize"] ?? "?"}  (${camInfo["sensorMp"] ?? "?"}MP)',
        'Focal: ${camInfo["focalLengths"] ?? "?"}mm',
      ] else
        '(iOS or not yet initialized)',
    ];
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(180),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF00FF88).withAlpha(120), width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: lines.map((line) => Text(
            line,
            style: TextStyle(
              color: line.startsWith('──')
                  ? const Color(0xFF00FF88)
                  : Colors.white.withAlpha(220),
              fontSize: 9.5,
              fontFamily: 'monospace',
              height: 1.4,
              fontWeight: line.startsWith('──') ? FontWeight.w700 : FontWeight.w400,
            ),
          )).toList(),
        ),
      ),
    );
  }
}

// ─── 鱼眼圆圈遮罩 ──────────────────────────────────────────────────────────────
/// 在取景框四角绘制黑色遮罩，只留中央圆形区域可见，模拟鱼眼镜头的圆形画面效果。
class _FisheyeCirclePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2;

    // 用 Path 的 evenOdd 填充规则：矩形 - 圆形 = 四角黑色区域
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(Rect.fromCircle(center: center, radius: radius))
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_FisheyeCirclePainter oldDelegate) => false;
}
