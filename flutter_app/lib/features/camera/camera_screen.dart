import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../services/camera_service.dart';
import '../../services/preset_repository.dart';
import '../../router/app_router.dart';
import '../../models/preset.dart';

// ─── 相机主屏幕 ───────────────────────────────────────────────────────────────

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});
  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen>
    with TickerProviderStateMixin {
  // ── 相机状态 ──
  bool _isFrontCamera = false;
  String _flashMode = 'off'; // 'off' | 'on' | 'auto'
  int _timerSeconds = 0; // 0 / 3 / 10
  double _exposureValue = 0.0;

  // ── UI 状态 ──
  bool _gridEnabled = false;
  bool _showTopMenu = false;
  bool _showCameraSelector = false;
  bool _isTakingPhoto = false;
  bool _showCaptureFlash = false;

  // ── 底部面板 ──
  String? _activePanel; // null | 'watermark' | 'frame' | 'filter' | 'ratio' | 'lens'

  // ── 图库 ──
  AssetEntity? _latestAsset;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(cameraServiceProvider.notifier).initCamera();
    });
    _loadLatestDazzPhoto();
  }

  // 只加载 DAZZ 相册中的最新照片
  Future<void> _loadLatestDazzPhoto() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.isAuth) return;
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      filterOption: FilterOptionGroup(
        orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
      ),
    );
    // 优先找名为 DAZZ 的相册
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
      setState(() => _latestAsset = assets.first);
    }
  }

  Future<void> _takePhoto() async {
    if (_isTakingPhoto) return;
    setState(() => _isTakingPhoto = true);
    HapticFeedback.mediumImpact();
    try {
      final path = await ref.read(cameraServiceProvider.notifier).takePhoto();
      if (path != null && mounted) {
        setState(() => _showCaptureFlash = true);
        await Future.delayed(const Duration(milliseconds: 150));
        if (mounted) setState(() => _showCaptureFlash = false);
        HapticFeedback.lightImpact();
        await _loadLatestDazzPhoto();
      }
    } finally {
      if (mounted) setState(() => _isTakingPhoto = false);
    }
  }

  void _toggleFlash() {
    setState(() {
      if (_flashMode == 'off') {
        _flashMode = 'on';
      } else if (_flashMode == 'on') {
        _flashMode = 'auto';
      } else {
        _flashMode = 'off';
      }
    });
    ref.read(cameraServiceProvider.notifier).setFlash(_flashMode);
  }

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
    HapticFeedback.selectionClick();
  }

  void _closeAllPanels() {
    setState(() {
      _showTopMenu = false;
      _showCameraSelector = false;
      _activePanel = null;
    });
  }

  void _showPanel(String panel) {
    setState(() {
      _activePanel = _activePanel == panel ? null : panel;
      _showCameraSelector = false;
      _showTopMenu = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cameraState = ref.watch(cameraServiceProvider);
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _closeAllPanels,
        behavior: HitTestBehavior.translucent,
        child: Stack(
          children: [
            SafeArea(
              child: Column(
                children: [
                  _buildTopIndicator(),
                  Expanded(
                    child: _buildPreviewArea(cameraState),
                  ),
                  _buildQuickActions(),
                  const SizedBox(height: 12),
                  _buildBottomBar(),
                  _buildBottomHandle(),
                ],
              ),
            ),
            // 拍照闪光
            if (_showCaptureFlash)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(color: Colors.white.withAlpha(180)),
                ),
              ),
            // 顶部菜单浮层
            if (_showTopMenu) _buildTopMenuOverlay(),
            // 相机选择器
            if (_showCameraSelector)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _CameraSelectorSheet(
                  onClose: () => setState(() => _showCameraSelector = false),
                  onShowPanel: _showPanel,
                  activePanel: _activePanel,
                ),
              ),
            // 底部功能面板
            if (_activePanel != null && !_showCameraSelector)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _buildActivePanel(),
              ),
          ],
        ),
      ),
    );
  }

  // ── 顶部绿色指示灯 ──
  Widget _buildTopIndicator() {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Center(
        child: Container(
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFF00E676),
          ),
        ),
      ),
    );
  }

  // ── 预览区域 ──
  Widget _buildPreviewArea(CameraState cameraState) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: AspectRatio(
          aspectRatio: 3 / 4,
          child: Container(
            color: const Color(0xFF111111),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 相机预览
                if (cameraState.isReady && cameraState.textureId != null)
                  Texture(textureId: cameraState.textureId!)
                else
                  Container(color: const Color(0xFF0A0A0A)),
                // 网格
                if (_gridEnabled) CustomPaint(painter: _GridPainter()),
                // 加载状态
                if (cameraState.isLoading)
                  const Center(
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  ),
                // 错误信息
                if (cameraState.error != null)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.camera_alt_outlined,
                              color: Colors.white54, size: 48),
                          const SizedBox(height: 12),
                          Text(
                            cameraState.error!,
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 12),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                // 右上角 ··· 菜单
                Positioned(
                  top: 12,
                  right: 12,
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        _showTopMenu = !_showTopMenu;
                        _showCameraSelector = false;
                        _activePanel = null;
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(100),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        '···',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          letterSpacing: 2,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                ),
                // 底部控制条
                Positioned(
                  bottom: 14,
                  left: 12,
                  right: 12,
                  child: _buildPreviewControls(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── 预览内控制条 ──
  Widget _buildPreviewControls() {
    return Row(
      children: [
        // 网格切换
        _PreviewPill(
          child: Icon(
            _gridEnabled ? Icons.grid_on : Icons.grid_off,
            color: _gridEnabled ? Colors.white : Colors.white60,
            size: 16,
          ),
          onTap: () => setState(() => _gridEnabled = !_gridEnabled),
        ),
        const SizedBox(width: 8),
        // 色温
        _PreviewPill(
          child: const Icon(Icons.thermostat_outlined,
              color: Colors.white, size: 15),
          onTap: () {},
        ),
        const SizedBox(width: 8),
        // 焦距
        _PreviewPill(
          child: const Text(
            '24',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          onTap: () {},
        ),
        const SizedBox(width: 8),
        // 曝光
        GestureDetector(
          onTap: _showExposureSlider,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(140),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.wb_sunny_outlined,
                    color: Colors.white, size: 14),
                const SizedBox(width: 3),
                Text(
                  _exposureValue == 0.0
                      ? '0.0'
                      : _exposureValue.toStringAsFixed(1),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _showExposureSlider() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('曝光补偿',
                      style: TextStyle(color: Colors.white, fontSize: 16)),
                  Text(
                    _exposureValue.toStringAsFixed(1),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SliderTheme(
                data: SliderTheme.of(ctx).copyWith(
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: Colors.white,
                  overlayColor: Colors.white24,
                ),
                child: Slider(
                  value: _exposureValue,
                  min: -3.0,
                  max: 3.0,
                  divisions: 60,
                  onChanged: (v) {
                    setModalState(() {});
                    setState(() => _exposureValue = v);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 快捷操作栏 ──
  Widget _buildQuickActions() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _QuickBtn(
            icon: Icons.add_photo_alternate_outlined,
            onTap: () {},
          ),
          _QuickBtn(
            icon: Icons.timer_outlined,
            badge: _timerSeconds > 0 ? '${_timerSeconds}s' : null,
            onTap: _cycleTimer,
          ),
          _QuickBtn(
            icon: _flashMode == 'off'
                ? Icons.flash_off
                : _flashMode == 'on'
                    ? Icons.flash_on
                    : Icons.flash_auto,
            onTap: _toggleFlash,
          ),
          _QuickBtn(
            icon: Icons.flip_camera_android_outlined,
            onTap: _switchCamera,
          ),
        ],
      ),
    );
  }

  // ── 底部工具栏 ──
  Widget _buildBottomBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 左：图库缩略图
          GestureDetector(
            onTap: () => context.push(AppRoutes.gallery),
            child: _GalleryThumb(asset: _latestAsset),
          ),
          // 中：快门
          GestureDetector(
            onTap: _takePhoto,
            child: _ShutterButton(isLoading: _isTakingPhoto),
          ),
          // 右：相机型号
          GestureDetector(
            onTap: () {
              setState(() {
                _showCameraSelector = !_showCameraSelector;
                _showTopMenu = false;
                _activePanel = null;
              });
            },
            child: Consumer(
              builder: (context, ref, _) {
                final current = ref.watch(cameraServiceProvider).currentPreset;
                return _CameraModelButton(preset: current);
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── 底部小横条 ──
  Widget _buildBottomHandle() {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }

  // ── 顶部菜单浮层 ──
  Widget _buildTopMenuOverlay() {
    return Positioned(
      top: 60,
      right: 16,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 200,
          decoration: BoxDecoration(
            color: const Color(0xFF2C2C2E),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(100),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _TopMenuItem(
                icon: Icons.grid_on,
                label: '网格',
                trailing: Switch(
                  value: _gridEnabled,
                  onChanged: (v) => setState(() => _gridEnabled = v),
                  activeColor: Colors.white,
                  activeTrackColor: Colors.blue,
                ),
                onTap: () => setState(() => _gridEnabled = !_gridEnabled),
              ),
              const Divider(height: 1, color: Colors.white12),
              _TopMenuItem(
                icon: Icons.hd_outlined,
                label: '清晰度',
                onTap: () {},
              ),
              const Divider(height: 1, color: Colors.white12),
              _TopMenuItem(
                icon: Icons.crop_square,
                label: '小画幅',
                onTap: () {},
              ),
              const Divider(height: 1, color: Colors.white12),
              _TopMenuItem(
                icon: Icons.exposure,
                label: '双重曝光',
                onTap: () {},
              ),
              const Divider(height: 1, color: Colors.white12),
              _TopMenuItem(
                icon: Icons.burst_mode_outlined,
                label: '连拍',
                onTap: () {},
              ),
              const Divider(height: 1, color: Colors.white12),
              _TopMenuItem(
                icon: Icons.settings_outlined,
                label: '设置',
                onTap: () {
                  _closeAllPanels();
                  context.push(AppRoutes.settings);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 活跃底部面板 ──
  Widget _buildActivePanel() {
    switch (_activePanel) {
      case 'watermark':
        return _WatermarkPanel(
          onClose: () => setState(() => _activePanel = null),
        );
      case 'frame':
        return _FramePanel(
          onClose: () => setState(() => _activePanel = null),
        );
      case 'filter':
        return _FilterPanel(
          onClose: () => setState(() => _activePanel = null),
        );
      case 'ratio':
        return _RatioPanel(
          onClose: () => setState(() => _activePanel = null),
        );
      case 'lens':
        return _LensPanel(
          onClose: () => setState(() => _activePanel = null),
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

// ─── 相机选择器底部弹窗 ─────────────────────────────────────────────────────

class _CameraSelectorSheet extends ConsumerStatefulWidget {
  final VoidCallback onClose;
  final void Function(String panel) onShowPanel;
  final String? activePanel;

  const _CameraSelectorSheet({
    required this.onClose,
    required this.onShowPanel,
    required this.activePanel,
  });

  @override
  ConsumerState<_CameraSelectorSheet> createState() =>
      _CameraSelectorSheetState();
}

class _CameraSelectorSheetState extends ConsumerState<_CameraSelectorSheet> {
  String _tab = '照片'; // '照片' | '视频'

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {}, // 阻止点击穿透
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1C1C1E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 拖动条
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[600],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // 标签栏
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  _TabButton(
                    label: '照片',
                    active: _tab == '照片',
                    onTap: () => setState(() => _tab = '照片'),
                  ),
                  const SizedBox(width: 20),
                  _TabButton(
                    label: '视频',
                    active: _tab == '视频',
                    onTap: () => setState(() => _tab = '视频'),
                  ),
                  const Spacer(),
                  _OutlineBtn(
                    icon: Icons.landscape_outlined,
                    label: '样图',
                    onTap: () {},
                  ),
                  const SizedBox(width: 8),
                  _OutlineBtn(
                    icon: Icons.camera_alt_outlined,
                    label: '管理',
                    onTap: () {
                      widget.onClose();
                      context.push(AppRoutes.settings);
                    },
                  ),
                ],
              ),
            ),
            // 相机列表
            Consumer(
              builder: (context, ref, _) {
                final presetsAsync = ref.watch(presetListProvider);
                return presetsAsync.when(
                  data: (presets) {
                    final filtered = _tab == '视频'
                        ? presets.where((p) => p.supportsVideo).toList()
                        : presets.where((p) => p.supportsPhoto).toList();
                    final current =
                        ref.watch(cameraServiceProvider).currentPreset;
                    return SizedBox(
                      height: 100,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final preset = filtered[index];
                          final isSelected = current?.id == preset.id;
                          return GestureDetector(
                            onTap: () {
                              ref
                                  .read(cameraServiceProvider.notifier)
                                  .setPreset(preset);
                              widget.onClose();
                            },
                            child: _PresetCell(
                              preset: preset,
                              isSelected: isSelected,
                            ),
                          );
                        },
                      ),
                    );
                  },
                  loading: () => const SizedBox(
                    height: 100,
                    child: Center(
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    ),
                  ),
                  error: (_, __) => const SizedBox(height: 100),
                );
              },
            ),
            // 底部功能按钮行（水印/边框/滤镜/比例/镜头）
            _buildPanelButtons(),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildPanelButtons() {
    final buttons = [
      ('watermark', Icons.access_time_outlined, '水印'),
      ('frame', Icons.crop_square_outlined, '边框'),
      ('filter', Icons.tune_outlined, '滤镜'),
      ('ratio', Icons.aspect_ratio_outlined, '比例'),
      ('lens', Icons.camera_outlined, '镜头'),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: buttons.map((b) {
          final isActive = widget.activePanel == b.$1;
          return GestureDetector(
            onTap: () => widget.onShowPanel(b.$1),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isActive
                        ? Colors.white.withAlpha(40)
                        : Colors.white.withAlpha(15),
                    border: isActive
                        ? Border.all(color: Colors.white54)
                        : null,
                  ),
                  child: Icon(b.$2,
                      color: isActive ? Colors.white : Colors.white60,
                      size: 20),
                ),
                const SizedBox(height: 4),
                Text(
                  b.$3,
                  style: TextStyle(
                    color: isActive ? Colors.white : Colors.white54,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ─── 水印面板 ────────────────────────────────────────────────────────────────

class _WatermarkPanel extends StatefulWidget {
  final VoidCallback onClose;
  const _WatermarkPanel({required this.onClose});
  @override
  State<_WatermarkPanel> createState() => _WatermarkPanelState();
}

class _WatermarkPanelState extends State<_WatermarkPanel> {
  String _tab = '颜色';
  Color _selectedColor = const Color(0xFFFF8C00);
  bool _enabled = true;

  static const _colors = [
    Colors.white,
    Color(0xFF4CAF50),
    Color(0xFFFFEB3B),
    Color(0xFFFF8C00),
    Color(0xFFFF5722),
    Color(0xFFF44336),
    Color(0xFFE91E63),
    Color(0xFF2196F3),
    Colors.black,
  ];

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {},
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFFF2F2F7),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _PanelHandle(),
            // 标题行
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const Text(
                    '时间水印',
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => setState(() => _enabled = !_enabled),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: _enabled ? Colors.black : Colors.grey[300],
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        _enabled ? '有水印' : '无水印',
                        style: TextStyle(
                          color: _enabled ? Colors.white : Colors.black54,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 子标签
            _SubTabs(
              tabs: const ['颜色', '样式', '位置', '方向', '大小'],
              selected: _tab,
              onSelect: (t) => setState(() => _tab = t),
            ),
            const SizedBox(height: 12),
            // 预览
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              height: 80,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: Text(
                  "2 25 '22",
                  style: TextStyle(
                    color: _selectedColor,
                    fontSize: 28,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // 颜色选择
            if (_tab == '颜色')
              SizedBox(
                height: 52,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _colors.length,
                  itemBuilder: (ctx, i) {
                    final c = _colors[i];
                    final isSelected = _selectedColor == c;
                    return GestureDetector(
                      onTap: () => setState(() => _selectedColor = c),
                      child: Container(
                        width: 44,
                        height: 44,
                        margin: const EdgeInsets.only(right: 10),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: c,
                          border: isSelected
                              ? Border.all(color: Colors.blue, width: 3)
                              : Border.all(
                                  color: Colors.grey[300]!, width: 1),
                        ),
                        child: isSelected
                            ? const Icon(Icons.check,
                                color: Colors.white, size: 20)
                            : null,
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

// ─── 边框面板 ────────────────────────────────────────────────────────────────

class _FramePanel extends StatefulWidget {
  final VoidCallback onClose;
  const _FramePanel({required this.onClose});
  @override
  State<_FramePanel> createState() => _FramePanelState();
}

class _FramePanelState extends State<_FramePanel> {
  String _tab = '样式';
  int _selectedIndex = 2; // 白色

  static const _frameColors = [
    Color(0xFF1C1C1E), // 随机
    Color(0xFFD4B44A), // 黄色
    Color(0xFFF5F5F5), // 白色
    Color(0xFF6B8E4E), // 绿色
    Color(0xFF1A1A1A), // 黑色
  ];

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {},
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFFF2F2F7),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _PanelHandle(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const Text(
                    '边框',
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => setState(() => _selectedIndex = -1),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: _selectedIndex == -1
                            ? Colors.black
                            : Colors.grey[300],
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '无边框',
                        style: TextStyle(
                          color: _selectedIndex == -1
                              ? Colors.white
                              : Colors.black54,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _SubTabs(
              tabs: const ['样式', '背景'],
              selected: _tab,
              onSelect: (t) => setState(() => _tab = t),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 80,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _frameColors.length,
                itemBuilder: (ctx, i) {
                  final isSelected = _selectedIndex == i;
                  return GestureDetector(
                    onTap: () => setState(() => _selectedIndex = i),
                    child: Stack(
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          margin: const EdgeInsets.only(right: 10),
                          decoration: BoxDecoration(
                            color: _frameColors[i],
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: Colors.grey[300]!,
                              width: 1,
                            ),
                          ),
                          child: i == 0
                              ? const Center(
                                  child: Icon(Icons.shuffle,
                                      color: Colors.white54, size: 24))
                              : null,
                        ),
                        if (isSelected)
                          Positioned(
                            bottom: 4,
                            right: 14,
                            child: Container(
                              width: 20,
                              height: 20,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.blue,
                              ),
                              child: const Icon(Icons.check,
                                  color: Colors.white, size: 14),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

// ─── 滤镜面板 ────────────────────────────────────────────────────────────────

class _FilterPanel extends ConsumerStatefulWidget {
  final VoidCallback onClose;
  const _FilterPanel({required this.onClose});
  @override
  ConsumerState<_FilterPanel> createState() => _FilterPanelState();
}

class _FilterPanelState extends ConsumerState<_FilterPanel> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {},
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1C1C1E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _PanelHandle(dark: true),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('滤镜',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600)),
              ),
            ),
            Consumer(
              builder: (context, ref, _) {
                final presetsAsync = ref.watch(presetListProvider);
                return presetsAsync.when(
                  data: (presets) {
                    return SizedBox(
                      height: 90,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        itemCount: presets.length,
                        itemBuilder: (ctx, i) {
                          final isSelected = _selectedIndex == i;
                          return GestureDetector(
                            onTap: () => setState(() => _selectedIndex = i),
                            child: Container(
                              width: 64,
                              margin: const EdgeInsets.only(right: 8),
                              child: Column(
                                children: [
                                  Container(
                                    width: 56,
                                    height: 56,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      color: Colors.grey[800],
                                      border: isSelected
                                          ? Border.all(
                                              color: Colors.white, width: 2)
                                          : null,
                                    ),
                                    child: const Icon(Icons.camera_alt,
                                        color: Colors.white54, size: 24),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    presets[i].name,
                                    style: TextStyle(
                                      color: isSelected
                                          ? Colors.white
                                          : Colors.white54,
                                      fontSize: 9,
                                    ),
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
                  loading: () => const SizedBox(
                      height: 90,
                      child: Center(
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))),
                  error: (_, __) => const SizedBox(height: 90),
                );
              },
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

// ─── 比例面板 ────────────────────────────────────────────────────────────────

class _RatioPanel extends StatefulWidget {
  final VoidCallback onClose;
  const _RatioPanel({required this.onClose});
  @override
  State<_RatioPanel> createState() => _RatioPanelState();
}

class _RatioPanelState extends State<_RatioPanel> {
  String _selected = '4:3';

  static const _ratios = ['1:1', '4:3', '3:2', '16:9', '全幅'];

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {},
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1C1C1E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _PanelHandle(dark: true),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('比例',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: _ratios.map((r) {
                  final isSelected = _selected == r;
                  return GestureDetector(
                    onTap: () => setState(() => _selected = r),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? Colors.white
                            : Colors.white.withAlpha(20),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        r,
                        style: TextStyle(
                          color: isSelected ? Colors.black : Colors.white,
                          fontSize: 14,
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 镜头面板 ────────────────────────────────────────────────────────────────

class _LensPanel extends StatefulWidget {
  final VoidCallback onClose;
  const _LensPanel({required this.onClose});
  @override
  State<_LensPanel> createState() => _LensPanelState();
}

class _LensPanelState extends State<_LensPanel> {
  String _selected = '1x';

  static const _lenses = [
    ('0.5x', '超广角'),
    ('1x', '广角'),
    ('2x', '长焦'),
    ('5x', '远摄'),
  ];

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {},
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1C1C1E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _PanelHandle(dark: true),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('镜头',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: _lenses.map((l) {
                  final isSelected = _selected == l.$1;
                  return GestureDetector(
                    onTap: () => setState(() => _selected = l.$1),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isSelected
                                ? Colors.white
                                : Colors.white.withAlpha(20),
                          ),
                          child: Center(
                            child: Text(
                              l.$1,
                              style: TextStyle(
                                color:
                                    isSelected ? Colors.black : Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l.$2,
                          style: TextStyle(
                            color:
                                isSelected ? Colors.white : Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 小组件 ──────────────────────────────────────────────────────────────────

class _PreviewPill extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  const _PreviewPill({required this.child, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(140),
          borderRadius: BorderRadius.circular(16),
        ),
        child: child,
      ),
    );
  }
}

class _QuickBtn extends StatelessWidget {
  final IconData icon;
  final String? badge;
  final VoidCallback onTap;
  const _QuickBtn({required this.icon, this.badge, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(icon, color: Colors.white, size: 28),
          if (badge != null)
            Positioned(
              top: -6,
              right: -8,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.orange,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(badge!,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.bold)),
              ),
            ),
        ],
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  final bool isLoading;
  const _ShutterButton({required this.isLoading});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 76,
      height: 76,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        color: isLoading ? Colors.grey[300] : Colors.white,
      ),
      child: isLoading
          ? const Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.black,
                ),
              ),
            )
          : null,
    );
  }
}

class _GalleryThumb extends StatelessWidget {
  final AssetEntity? asset;
  const _GalleryThumb({required this.asset});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: const Color(0xFF2C2C2E),
        border: Border.all(color: Colors.white24, width: 1),
      ),
      child: asset != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: FutureBuilder<Uint8List?>(
                future: asset!
                    .thumbnailDataWithSize(const ThumbnailSize(112, 112)),
                builder: (ctx, snap) {
                  if (snap.hasData && snap.data != null) {
                    return Image.memory(snap.data!, fit: BoxFit.cover);
                  }
                  return Container(color: Colors.grey[800]);
                },
              ),
            )
          : const Icon(Icons.photo_library_outlined,
              color: Colors.white54, size: 24),
    );
  }
}

class _CameraModelButton extends StatelessWidget {
  final Preset? preset;
  const _CameraModelButton({required this.preset});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: const Color(0xFF2C2C2E),
        border: Border.all(color: Colors.white24, width: 1),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.camera_alt_outlined, color: Colors.white, size: 22),
          if (preset != null) ...[
            const SizedBox(height: 2),
            Text(
              preset!.name.length > 6
                  ? preset!.name.substring(0, 6)
                  : preset!.name,
              style: const TextStyle(color: Colors.white70, fontSize: 8),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ],
        ],
      ),
    );
  }
}

class _PresetCell extends StatelessWidget {
  final Preset preset;
  final bool isSelected;
  const _PresetCell({required this.preset, required this.isSelected});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      margin: const EdgeInsets.only(right: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: const Color(0xFF3A3A3C),
              border: Border.all(
                color: isSelected ? Colors.white : Colors.transparent,
                width: 2,
              ),
            ),
            child: Stack(
              children: [
                const Center(
                  child: Icon(Icons.camera_alt,
                      color: Colors.white54, size: 26),
                ),
                if (preset.isPremium)
                  Positioned(
                    bottom: 4,
                    right: 4,
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xFF007AFF),
                      ),
                      child: const Center(
                        child: Text('β',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            preset.name,
            style: TextStyle(
              color: isSelected ? Colors.white : Colors.grey[400],
              fontSize: 10,
            ),
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _TabButton(
      {required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Text(
        label,
        style: TextStyle(
          color: active ? Colors.white : Colors.grey[500],
          fontSize: 16,
          fontWeight: active ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }
}

class _OutlineBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _OutlineBtn(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.grey[600]!),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 13),
            const SizedBox(width: 4),
            Text(label,
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _TopMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget? trailing;
  final VoidCallback onTap;
  const _TopMenuItem(
      {required this.icon,
      required this.label,
      this.trailing,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 10),
            Text(label,
                style: const TextStyle(color: Colors.white, fontSize: 14)),
            const Spacer(),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

class _SubTabs extends StatelessWidget {
  final List<String> tabs;
  final String selected;
  final void Function(String) onSelect;
  const _SubTabs(
      {required this.tabs, required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: tabs.map((t) {
          final isSelected = selected == t;
          return GestureDetector(
            onTap: () => onSelect(t),
            child: Padding(
              padding: const EdgeInsets.only(right: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t,
                    style: TextStyle(
                      color: isSelected ? Colors.black : Colors.black45,
                      fontSize: 14,
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (isSelected)
                    Container(
                      height: 2,
                      width: 20,
                      color: Colors.black,
                    ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _PanelHandle extends StatelessWidget {
  final bool dark;
  const _PanelHandle({this.dark = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      width: 36,
      height: 4,
      decoration: BoxDecoration(
        color: dark ? Colors.white24 : Colors.black26,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

// ─── 网格画笔 ────────────────────────────────────────────────────────────────

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 0.5;
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
