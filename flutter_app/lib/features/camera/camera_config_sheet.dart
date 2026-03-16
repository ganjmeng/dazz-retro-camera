// camera_config_sheet.dart
// ─────────────────────────────────────────────────────────────────────────────
// 相机配置菜单（右侧相机按钮点击展开）
// 复刻截图 13079 / 13080 / 13081 / 13082 / 13083
//
// 布局（从下往上）：
//   ┌─ 功能图标行 ──────────────────────────────────────────────────────────┐
//   │  时间水印 | 边框 | 比例 | 滤镜(三色圆) | · | 镜头1 | 镜头2 | ...      │
//   ├─ 相机列表行 ─────────────────────────────────────────────────────────┤
//   │  [D Slide] [S 67] [NT16★] [Classic U] [DQS] [CCD R] ...横向滚动     │
//   ├─ Tab 行 ─────────────────────────────────────────────────────────────┤
//   │  照片 | 视频                        样图 | 管理                       │
//   └──────────────────────────────────────────────────────────────────────┘
//
// 子面板（DraggableScrollableSheet 从底部弹出）：
//   - 时间水印：颜色/样式/位置/方向/大小 Tab + 颜色选择器
//   - 边框：样式/背景 Tab + 颜色块
//   - 比例：横向滚动比例选项
//   - 滤镜：胶卷图标列表
//   - 镜头：圆形图标行（动态读取配置）
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/camera_definition.dart';
import '../../models/camera_registry.dart';
import '../../services/camera_manager_service.dart';
import 'camera_notifier.dart';
import 'camera_manager_screen.dart';
import 'camera_sample_screen.dart';
import '../../models/watermark_styles.dart';
import '../../core/l10n.dart';

// ─── 颜色常量 ─────────────────────────────────────────────────────────────────
const _kBg = Color(0xFF1A1A1A);
const _kSurface = Color(0xFF2C2C2E);
const _kDivider = Color(0xFF3A3A3C);
const _kTextPrimary = Colors.white;
const _kTextSecondary = Color(0xFF8E8E93);
const _kOrange = Color(0xFFFF9500);

// ─────────────────────────────────────────────────────────────────────────────
// 主面板入口
// ─────────────────────────────────────────────────────────────────────────────

/// 从底部弹出相机配置菜单
Future<void> showCameraConfigSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.transparent,
    builder: (_) => const _CameraConfigSheet(),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// 主面板 Widget
// ─────────────────────────────────────────────────────────────────────────────

/// 图片编辑页底部常驻面板：无 Tab行，只显示相机列表 + 功能图标行
class CameraConfigInlinePanel extends ConsumerWidget {
  /// 是否显示镜头选择按钮（相机页显示，编辑页隐藏）
  final bool showLens;
  const CameraConfigInlinePanel({super.key, this.showLens = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(cameraAppProvider);
    final cam = st.camera;

    return Container(
      color: _kBg,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(height: 1, color: _kDivider),
          _buildCameraRow(context, ref, st),
          const Divider(height: 1, color: _kDivider),
          if (cam != null) _buildFunctionRow(context, ref, st, cam, showLens: showLens),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
        ],
      ),
    );
  }

  // ── 相机列表行 ─────────────────────────────────────────────────────────────
  Widget _buildCameraRow(BuildContext context, WidgetRef ref, CameraAppState st) {
    final managerAsync = ref.watch(cameraManagerProvider);
    final List<CameraEntry> orderedCameras;
    if (managerAsync.hasValue) {
      final mgr = managerAsync.value!;
      final sortedIds = [
        ...mgr.favoriteIds,
        ...mgr.nonFavoriteIds,
      ].where((id) => mgr.enabledIds.contains(id)).toList();
      orderedCameras = sortedIds
          .map((id) => kAllCameras.where((c) => c.id == id).firstOrNull)
          .whereType<CameraEntry>()
          .toList();
    } else {
      orderedCameras = List.from(kAllCameras);
    }

    return SizedBox(
      height: 110,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: orderedCameras.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (ctx, i) {
          final entry = orderedCameras[i];
          final isActive = st.activeCameraId == entry.id;
          final isFav = managerAsync.hasValue
              ? managerAsync.value!.favoritedIds.contains(entry.id)
              : false;
          return _CameraCell(
            entry: entry,
            isActive: isActive,
            isFavorite: isFav,
            onTap: () {
              HapticFeedback.selectionClick();
              ref.read(cameraAppProvider.notifier).switchCamera(entry.id);
            },
          );
        },
      ),
    );
  }

  // ── 功能图标行 ─────────────────────────────────────────────────────────────
  Widget _buildFunctionRow(BuildContext context, WidgetRef ref, CameraAppState st, CameraDefinition cam, {bool showLens = true}) {
    final uiCap = cam.uiCapabilities;
    final s = sOf(ref.read(languageProvider));
    final List<Widget> items = [];

    if (uiCap.enableWatermark) {
      final active = st.activeWatermark;
      final hasWatermark = active != null && !active.isNone;
      items.add(_FuncBtn(
        label: s.watermark,
        child: _WatermarkIcon(active: hasWatermark),
        isActive: hasWatermark,
        onTap: () => _openSubPanel(context, ref, _SubPanelType.watermark, cam),
      ));
    }

    if (uiCap.enableFrame) {
      final hasFrame = st.activeFrameId != null;
      final ratioSupportsFrame = cam.isFrameEnabled(st.activeRatioId);
      items.add(Opacity(
        opacity: ratioSupportsFrame ? 1.0 : 0.35,
        child: IgnorePointer(
          ignoring: !ratioSupportsFrame,
          child: _FuncBtn(
            label: s.frame,
            child: _FrameIcon(active: hasFrame && ratioSupportsFrame),
            isActive: hasFrame && ratioSupportsFrame,
            onTap: () => _openSubPanel(context, ref, _SubPanelType.frame, cam),
          ),
        ),
      ));
    }

    if (uiCap.enableRatio) {
      final ratio = st.activeRatio;
      final isDefaultRatio = st.activeRatioId == null ||
          st.activeRatioId == cam.defaultSelection.ratioId;
      final ratioLabel = ratio?.label ?? '3:4';
      items.add(_FuncBtn(
        label: isDefaultRatio ? s.originalRatio : ratioLabel,
        child: _RatioIcon(
          label: isDefaultRatio ? s.originalRatio : ratioLabel,
          isDefault: isDefaultRatio,
        ),
        isActive: !isDefaultRatio,
        onTap: () => _openSubPanel(context, ref, _SubPanelType.ratio, cam),
      ));
    }

    if (uiCap.enableFilter) {
      items.add(_FuncBtn(
        label: s.filter,
        child: const _FilmFilterIcon(),
        isActive: false,
        onTap: () => _openSubPanel(context, ref, _SubPanelType.filter, cam),
      ));
    }

    items.add(const _DotSeparator());

    if (uiCap.enableLens && showLens) {
      for (final lens in cam.modules.lenses) {
        final isActive = st.activeLensId == lens.id;
        items.add(_LensBtn(
          lens: lens,
          isActive: isActive,
          onTap: () {
            HapticFeedback.selectionClick();
            ref.read(cameraAppProvider.notifier).selectLens(lens.id);
          },
        ));
      }
    }

    return SizedBox(
      height: 90,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: items.map((w) => Padding(
          padding: const EdgeInsets.only(right: 16),
          child: w,
        )).toList(),
      ),
    );
  }

  void _openSubPanel(BuildContext context, WidgetRef ref, _SubPanelType type, CameraDefinition cam) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black26,
      isDismissible: true,
      enableDrag: true,
      useRootNavigator: false,
      builder: (modalCtx) => ProviderScope(
        parent: ProviderScope.containerOf(context),
        child: _SubPanel(type: type, camera: cam),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 弹框版（保持不变，供相机页使用）
// ─────────────────────────────────────────────────────────────────────────────
class _CameraConfigSheet extends ConsumerStatefulWidget {
  const _CameraConfigSheet();

  @override
  ConsumerState<_CameraConfigSheet> createState() => _CameraConfigSheetState();
}

class _CameraConfigSheetState extends ConsumerState<_CameraConfigSheet>
    with SingleTickerProviderStateMixin {
  // Tab 已移除
  final ScrollController _cameraScrollCtrl = ScrollController();
  String? _lastScrolledCameraId; // 避免重复滚动

  @override
  void dispose() {
    _cameraScrollCtrl.dispose();
    super.dispose();
  }

  /// 滚动相机列表使当前相机可见
  void _scrollToActiveCamera(List<CameraEntry> orderedCameras, String activeCameraId) {
    if (_lastScrolledCameraId == activeCameraId) return;
    final idx = orderedCameras.indexWhere((c) => c.id == activeCameraId);
    if (idx < 0) return;
    _lastScrolledCameraId = activeCameraId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_cameraScrollCtrl.hasClients) return;
      // 每个 cell 约 80px + 12px 间距 = 92px，左 padding 16px
      const cellW = 80.0;
      const sepW  = 12.0;
      const padL  = 16.0;
      final targetOffset = padL + idx * (cellW + sepW) - 16.0;
      final maxOffset = _cameraScrollCtrl.position.maxScrollExtent;
      _cameraScrollCtrl.animateTo(
        targetOffset.clamp(0.0, maxOffset),
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(cameraAppProvider);
    final s = sOf(ref.watch(languageProvider));
    final cam = st.camera;

    return Container(
      decoration: const BoxDecoration(
        color: _kBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 拖拽指示条
          Container(
            margin: const EdgeInsets.only(top: 8, bottom: 4),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: _kDivider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Tab 行：照片 | 视频  +  样图 | 管理
          _buildTabRow(),
          const Divider(height: 1, color: _kDivider),
          // 相机列表行
          _buildCameraRow(st),
          const Divider(height: 1, color: _kDivider),
          // 功能图标行
          if (cam != null) _buildFunctionRow(st, cam),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
        ],
      ),
    );
  }

  // ── Tab 行 ──────────────────────────────────────────────────────────────────
  Widget _buildTabRow() {
    // Tab行已简化：移除照片/视频Tab和样式管理按钮
    return const SizedBox(height: 4);
  }

  // ── 相机列表行 ──────────────────────────────────────────────────────────────
  // 顺序与相机管理页联动：收藏的相机排在最前，其余按管理页拖动顺序排列
  Widget _buildCameraRow(CameraAppState st) {
    // 读取相机管理状态（异步加载中时降级为 kAllCameras 默认顺序）
    final managerAsync = ref.watch(cameraManagerProvider);
    final List<CameraEntry> orderedCameras;
    if (managerAsync.hasValue) {
      final mgr = managerAsync.value!;
      // 收藏相机排在最前，其余按管理页顺序排列
      // 仅显示已启用的相机（enabledIds 中的）
      final sortedIds = [
        ...mgr.favoriteIds,
        ...mgr.nonFavoriteIds,
      ].where((id) => mgr.enabledIds.contains(id)).toList();
      orderedCameras = sortedIds
          .map((id) => kAllCameras.where((c) => c.id == id).firstOrNull)
          .whereType<CameraEntry>()
          .toList();
    } else {
      // 管理状态未加载时，使用默认顺序
      orderedCameras = List.from(kAllCameras);
    }

    // 每次建立列表时自动滚动到当前相机
    _scrollToActiveCamera(orderedCameras, st.activeCameraId);

    return SizedBox(
      height: 110,
      child: ListView.separated(
        controller: _cameraScrollCtrl,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: orderedCameras.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (ctx, i) {
          final entry = orderedCameras[i];
          final isActive = st.activeCameraId == entry.id;
          final isFav = managerAsync.hasValue
              ? managerAsync.value!.favoritedIds.contains(entry.id)
              : false;
          return _CameraCell(
            entry: entry,
            isActive: isActive,
            isFavorite: isFav,
            onTap: () {
              HapticFeedback.selectionClick();
              // 切换相机后重置滚动标记，下次打开时自动滚到新相机
              _lastScrolledCameraId = null;
              ref.read(cameraAppProvider.notifier).switchCamera(entry.id);
            },
          );
        },
      ),
    );
  }// ── 功能图标行 ──────────────────────────────────────────────────────────────
  Widget _buildFunctionRow(CameraAppState st, CameraDefinition cam) {
    final uiCap = cam.uiCapabilities;
    final s = sOf(ref.read(languageProvider));

    // 构建功能按鈕列表
    final List<Widget> items = [];

    // 1. 时间水印
    if (uiCap.enableWatermark) {
      final active = st.activeWatermark;
      final hasWatermark = active != null && !active.isNone;
      items.add(_FuncBtn(
        label: s.watermark,
        child: _WatermarkIcon(active: hasWatermark),
        isActive: hasWatermark,
        onTap: () => _openSubPanel(context, _SubPanelType.watermark),
      ));
    }

    // 2. 边框（当前比例不支持相框时，按鈕变灰不可点击）
    if (uiCap.enableFrame) {
      final hasFrame = st.activeFrameId != null;
      final ratioSupportsFrame = cam.isFrameEnabled(st.activeRatioId);
      items.add(Opacity(
        opacity: ratioSupportsFrame ? 1.0 : 0.35,
        child: IgnorePointer(
          ignoring: !ratioSupportsFrame,
          child: _FuncBtn(
            label: s.frame,
            child: _FrameIcon(active: hasFrame && ratioSupportsFrame),
            isActive: hasFrame && ratioSupportsFrame,
            onTap: () => _openSubPanel(context, _SubPanelType.frame),
          ),
        ),
      ));
    }

    // 3. 比例
    if (uiCap.enableRatio) {
      final ratio = st.activeRatio;
      // 如果 activeRatioId 与默认比例相同，显示原比例；否则显示选中的比例标签
      final isDefaultRatio = st.activeRatioId == null ||
          st.activeRatioId == cam.defaultSelection.ratioId;
      final ratioLabel = ratio?.label ?? '3:4';
      items.add(_FuncBtn(
        label: isDefaultRatio ? s.originalRatio : ratioLabel,
        child: _RatioIcon(
          label: isDefaultRatio ? s.originalRatio : ratioLabel,
          isDefault: isDefaultRatio,
        ),
        isActive: !isDefaultRatio,
        onTap: () => _openSubPanel(context, _SubPanelType.ratio),
      ));
    }

    // 4. 滤镜（三色圆图标）
    if (uiCap.enableFilter) {
      items.add(_FuncBtn(
        label: s.filter,
        child: const _FilmFilterIcon(),
        isActive: false,
        onTap: () => _openSubPanel(context, _SubPanelType.filter),
      ));
    }

    // 5. 分隔点
    items.add(const _DotSeparator());

    // 6. 镜头列表（圆形图标，动态读取）
    if (uiCap.enableLens) {
      for (final lens in cam.modules.lenses) {
        final isActive = st.activeLensId == lens.id;
        items.add(_LensBtn(
          lens: lens,
          isActive: isActive,
          onTap: () {
            HapticFeedback.selectionClick();
            ref.read(cameraAppProvider.notifier).selectLens(lens.id);
          },
        ));
      }
    }

    return SizedBox(
      height: 90,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: items.map((w) => Padding(
          padding: const EdgeInsets.only(right: 16),
          child: w,
        )).toList(),
      ),
    );
  }

  // ── 打开子面板 ──────────────────────────────────────────────────────────────
  // 子面板弹出时主面板保持在后面，关闭子面板后主面板仍可见
  void _openSubPanel(BuildContext ctx, _SubPanelType type) {
    final st = ref.read(cameraAppProvider);
    final cam = st.camera;
    if (cam == null) return;

    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black26,
      isDismissible: true, // 点击遗罩关闭
      enableDrag: true,    // 下拉手势关闭
      // 使用 useRootNavigator=false 确保 modal 在 ProviderScope 内部
      useRootNavigator: false,
      builder: (modalCtx) => ProviderScope(
        // 共享父级 ProviderContainer，确保子面板能正确 watch/read 全局状态
        parent: ProviderScope.containerOf(ctx),
        child: _SubPanel(type: type, camera: cam),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 子面板类型
// ─────────────────────────────────────────────────────────────────────────────

enum _SubPanelType { watermark, frame, ratio, filter, lens }

// ─────────────────────────────────────────────────────────────────────────────
// 子面板 Widget
// ─────────────────────────────────────────────────────────────────────────────

class _SubPanel extends ConsumerStatefulWidget {
  final _SubPanelType type;
  final CameraDefinition camera;

  const _SubPanel({required this.type, required this.camera});

  @override
  ConsumerState<_SubPanel> createState() => _SubPanelState();
}

class _SubPanelState extends ConsumerState<_SubPanel>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  int _tabIndex = 0;
  bool _showColorPicker = false; // 彩虹圆圈点击后展开 HSV 色盘
  double _pickerHue = 30.0;        // HSV 色相 0~360
  double _pickerSaturation = 1.0;  // HSV 饱和度 0~1
  double _pickerValue = 1.0;       // HSV 亮度 0~1

  int _lastTabCount = 0;

  @override
  void initState() {
    super.initState();
    _lastTabCount = _tabCount;
    _tabCtrl = TabController(length: _lastTabCount, vsync: this);
    _tabCtrl.addListener(() {
      if (!_tabCtrl.indexIsChanging) setState(() => _tabIndex = _tabCtrl.index);
    });
  }

  /// 当相框切换导致 supportsBackground 变化时，重建 TabController
  void _rebuildTabControllerIfNeeded() {
    final newCount = _tabCount;
    if (newCount != _lastTabCount) {
      _tabCtrl.dispose();
      _lastTabCount = newCount;
      _tabCtrl = TabController(length: newCount, vsync: this);
      _tabCtrl.addListener(() {
        if (!_tabCtrl.indexIsChanging) setState(() => _tabIndex = _tabCtrl.index);
      });
      // 如果当前 tab 超出范围，重置到第一个
      if (_tabIndex >= newCount) {
        _tabIndex = 0;
        _tabCtrl.animateTo(0);
      }
    }
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  int get _tabCount {
    switch (widget.type) {
      case _SubPanelType.watermark: return 5;
      case _SubPanelType.frame: return _frameSupportsBackground ? 2 : 1;
      default: return 1;
    }
  }

  /// 当前选中相框是否支持背景色选择
  bool get _frameSupportsBackground {
    final st = ref.read(cameraAppProvider);
    final frame = widget.camera.frameById(st.activeFrameId);
    return frame?.supportsBackground ?? false;
  }

  String _title(S s) {
    switch (widget.type) {
      case _SubPanelType.watermark: return s.watermark;
      case _SubPanelType.frame: return s.frame;
      case _SubPanelType.ratio: return s.ratio;
      case _SubPanelType.filter: return s.filter;
      case _SubPanelType.lens: return s.lens;
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(cameraAppProvider);
    final s = sOf(ref.watch(languageProvider));

    return GestureDetector(
      onTap: () {}, // 防止点击穿透到背景层
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFFF2F2F7),
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 拖拽条
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 8, bottom: 4),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFD1D1D6),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // 标题行
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    _title(s),
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  // 比例面板：在标题旁显示相框限制提示
                  if (widget.type == _SubPanelType.ratio &&
                      widget.camera.modules.ratios.any((r) => !r.supportsFrame)) ...
                    [
                      const SizedBox(width: 8),
                      Text(
                        s.frameRatioHint,
                        style: const TextStyle(
                          color: Color(0xFF8E8E93),
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  const Spacer(),
                  // 右上角操作按鈕（无水印开关 / 无边框）
                  if (widget.type == _SubPanelType.watermark) (() {
                    final isNone = st.activeWatermark?.isNone ?? st.activeWatermarkId == null;
                    return GestureDetector(
                      onTap: () {
                        if (isNone) {
                          // 当前无水印 → 切回第一个非-none 预设
                          final presets = widget.camera.modules.watermarks.presets;
                          final first = presets.firstWhere((p) => !p.isNone, orElse: () => presets.first);
                          ref.read(cameraAppProvider.notifier).selectWatermark(first.id);
                        } else {
                          // 当前有水印 → 切换到 none
                          ref.read(cameraAppProvider.notifier).selectWatermark('none');
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: isNone ? const Color(0xFFFF9500) : const Color(0xFFE5E5EA),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          s.noWatermark,
                          style: TextStyle(
                            color: isNone ? Colors.white : Colors.black,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    );
                  })(),
                  if (widget.type == _SubPanelType.frame)
                    _FrameToggleSwitch(
                      enabled: ref.watch(cameraAppProvider).activeFrameId != null,
                      onChanged: (v) {
                        // v=true 表示开启边框，v=false 表示关闭边框
                        if (!v) {
                          ref.read(cameraAppProvider.notifier).selectFrame('none');
                        } else {
                          final frames = widget.camera.modules.frames;
                          if (frames.isNotEmpty) {
                            ref.read(cameraAppProvider.notifier).selectFrame(frames.first.id);
                          }
                        }
                      },
                    ),
                ],
              ),
            ),
            // 子 Tab 行（水印/边框有多 Tab）
            if (widget.type == _SubPanelType.watermark) (() {
              final isNone = st.activeWatermark?.isNone ?? st.activeWatermarkId == null;
              return Opacity(
                opacity: isNone ? 0.35 : 1.0,
                child: AbsorbPointer(
                  absorbing: isNone,
                  child: _buildWatermarkTabs(),
                ),
              );
            })(),
            if (widget.type == _SubPanelType.frame) _buildFrameTabs(),
            // 内容区（可滚动）
            Flexible(
              child: (() {
                final isNone = widget.type == _SubPanelType.watermark &&
                    (st.activeWatermark?.isNone ?? st.activeWatermarkId == null);
                return Opacity(
                  opacity: isNone ? 0.35 : 1.0,
                  child: AbsorbPointer(
                    absorbing: isNone,
                    child: SingleChildScrollView(
                      child: _buildContent(st),
                    ),
                  ),
                );
              })(),
            ),
            SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
          ],
        ),
      ),
    );
  }

  // ── 水印 Tab 行 ─────────────────────────────────────────────────────────────
  Widget _buildWatermarkTabs() {
    final s = sOf(ref.read(languageProvider));
    final tabs = [s.wmColor, s.wmStyle, s.wmPosition, s.wmDirection, s.wmSize];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: tabs.asMap().entries.map((e) {
          final selected = e.key == _tabIndex;
          return GestureDetector(
            onTap: () {
              _tabCtrl.animateTo(e.key);
              setState(() => _tabIndex = e.key);
            },
            child: Container(
              margin: const EdgeInsets.only(right: 20),
              padding: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: selected ? Colors.black : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              child: Text(
                e.value,
                style: TextStyle(
                  color: selected ? Colors.black : const Color(0xFF8E8E93),
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── 边框 Tab 行 ────────────────────────────────────────────────────────────────────────────────────
  Widget _buildFrameTabs() {
    // 仅当当前相框支持背景色时才显示“背景”Tab
    final s = sOf(ref.read(languageProvider));
    final tabs = _frameSupportsBackground ? [s.wmStyle, s.frameBackground] : [s.wmStyle];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: tabs.asMap().entries.map((e) {
          final selected = e.key == _tabIndex;
          return GestureDetector(
            onTap: () {
              _tabCtrl.animateTo(e.key);
              setState(() => _tabIndex = e.key);
            },
            child: Container(
              margin: const EdgeInsets.only(right: 20),
              padding: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: selected ? Colors.black : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              child: Text(
                e.value,
                style: TextStyle(
                  color: selected ? Colors.black : const Color(0xFF8E8E93),
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── 内容区 ──────────────────────────────────────────────────────────────────
  Widget _buildContent(CameraAppState st) {
    switch (widget.type) {
      case _SubPanelType.watermark:
        return _buildWatermarkContent(st);
      case _SubPanelType.frame:
        return _buildFrameContent(st);
      case _SubPanelType.ratio:
        return _buildRatioContent(st);
      case _SubPanelType.filter:
        return _buildFilterContent(st);
      case _SubPanelType.lens:
        return _buildLensContent(st);
    }
  }

  // ── 水印内容 ────────────────────────────────────────────────────────────────
  // 将 HSV 转为 hex 字符串
  String _hsvToHex(double h, double s, double v) {
    final color = HSVColor.fromAHSV(1.0, h, s, v).toColor();
    // Flutter 3.x 中 Color.r/g/b 是 double (0.0~1.0)，需乘以 255 再取整
    final r = (color.r * 255).round().toRadixString(16).padLeft(2, '0');
    final g = (color.g * 255).round().toRadixString(16).padLeft(2, '0');
    final b = (color.b * 255).round().toRadixString(16).padLeft(2, '0');
    return '#$r$g$b'.toUpperCase();
  }

  Widget _buildWatermarkContent(CameraAppState st) {
    if (_tabIndex == 0) {
      // 解析当前颜色，用于预览
      final currentColor = _parseColor(st.watermarkColor ?? st.activeWatermark?.color ?? '#FF8A3D');

      // 颜色 Tab：预览 + 彩虹圆圈（点击展开 HSV 色盘）
      return Column(
        children: [
          const SizedBox(height: 12),
          // 预览框（黑色背景，橙色数字）
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 20),
            height: 80,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Text(
              '2 25 \'22',
              style: TextStyle(
                color: currentColor,
                fontSize: 28,
                fontFamily: 'monospace',
                letterSpacing: 2,
              ),
            ),
          ),
          const SizedBox(height: 16),
          // 彩虹圆圈 + 预设颜色圆圈
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: [
                // 彩虹圆圈：点击展开 HSV 色盘
                _ColorDot(
                  isRainbow: true,
                  selected: _showColorPicker,
                  onTap: () => setState(() => _showColorPicker = !_showColorPicker),
                ),
                ..._kWatermarkColors.map((c) {
                  // Flutter 3.x 中 Color.r/g/b 是 double (0.0~1.0)，需乘以 255 再取整
                  final r = (c.r * 255).round().toRadixString(16).padLeft(2, '0');
                  final g = (c.g * 255).round().toRadixString(16).padLeft(2, '0');
                  final b = (c.b * 255).round().toRadixString(16).padLeft(2, '0');
                  final hex = '#$r$g$b'.toUpperCase();
                  // 预设颜色选中时关闭 HSV 色盘
                  final isSelected = !_showColorPicker &&
                      (st.watermarkColor?.toUpperCase() == hex ||
                       (st.watermarkColor == null && st.activeWatermark?.color?.toUpperCase() == hex));
                  return _ColorDot(
                    color: c,
                    selected: isSelected,
                    onTap: () {
                      setState(() => _showColorPicker = false);
                      ref.read(cameraAppProvider.notifier).selectWatermarkColor(hex);
                    },
                  );
                }),
              ],
            ),
          ),
          // HSV 色盘（彩虹圆圈展开时显示）
          if (_showColorPicker) ..._buildHsvPicker(),
          const SizedBox(height: 8),
        ],
      );
    }
    // Tab 1: 样式（6 种 LED 数字时钟风格横向滚动卡片）
    if (_tabIndex == 1) {
      final now = DateTime.now();
      // 当前水印颜色（用于卡片预览）
      final previewColor = _parseColor(st.watermarkColor ?? st.activeWatermark?.color ?? '#FF8A3D');
      final currentStyleId = st.watermarkStyle ?? 's1';
      return SizedBox(
        height: 120,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          itemCount: kWatermarkStyles.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (ctx, i) {
            final style = kWatermarkStyles[i];
            final isActive = currentStyleId == style.id;
            final previewText = style.buildText(now);
            return GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                ref.read(cameraAppProvider.notifier).setWatermarkStyle(style.id);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 110,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(10),
                  border: isActive
                      ? Border.all(color: const Color(0xFFFF9500), width: 2)
                      : Border.all(color: const Color(0xFF3A3A3C), width: 1),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // LED 风格日期预览
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        previewText,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: isActive ? previewColor : previewColor.withOpacity(0.7),
                          fontSize: style.fontSize.clamp(11.0, 15.0),
                          fontFamily: style.fontFamily,
                          fontWeight: style.fontWeight,
                          letterSpacing: style.letterSpacing.clamp(0.5, 3.0),
                          height: style.wordSpacing > 0 ? 1.4 : 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    // 样式名称标签
                    Text(
                      style.label,
                      style: TextStyle(
                        color: isActive ? const Color(0xFFFF9500) : const Color(0xFF8E8E93),
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    }

    // Tab 2: 位置
    if (_tabIndex == 2) {
      final sl = sOf(ref.read(languageProvider));
      final positions = [
        ('top_left',     sl.posTopLeft),
        ('top_center',   sl.posTopCenter),
        ('top_right',    sl.posTopRight),
        ('bottom_left',  sl.posBottomLeft),
        ('bottom_center',sl.posBottomCenter),
        ('bottom_right', sl.posBottomRight),
      ];
      final currentPos = st.watermarkPosition ?? st.activeWatermark?.position ?? 'bottom_right';
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Column(
          children: [
            // 3x2 位置选择网格
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(12),
              ),
              child: AspectRatio(
                aspectRatio: 3 / 2,
                child: GridView.count(
                  crossAxisCount: 3,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  children: positions.map((pos) {
                    final isSelected = currentPos == pos.$1;
                    return GestureDetector(
                      onTap: () => ref.read(cameraAppProvider.notifier).setWatermarkPosition(pos.$1),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isSelected ? const Color(0xFFFF9500) : const Color(0xFF2C2C2E),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Center(
                          child: Text(
                            pos.$2,
                            style: TextStyle(
                              color: isSelected ? Colors.black : Colors.white54,
                              fontSize: 13,
                              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Tab 3: 方向
    if (_tabIndex == 3) {
      final currentDir = st.watermarkDirection ?? 'horizontal';
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () => ref.read(cameraAppProvider.notifier).setWatermarkDirection('horizontal'),
                child: Container(
                  height: 80,
                  decoration: BoxDecoration(
                    color: currentDir == 'horizontal' ? const Color(0xFFFF9500) : Colors.black,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: currentDir == 'horizontal' ? const Color(0xFFFF9500) : const Color(0xFF3A3A3C),
                      width: 2,
                    ),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.text_fields, color: currentDir == 'horizontal' ? Colors.black : Colors.white54, size: 24),
                        const SizedBox(height: 4),
                        Text(sOf(ref.read(languageProvider)).wmHorizontal, style: TextStyle(
                          color: currentDir == 'horizontal' ? Colors.black : Colors.white54,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        )),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: GestureDetector(
                onTap: () => ref.read(cameraAppProvider.notifier).setWatermarkDirection('vertical'),
                child: Container(
                  height: 80,
                  decoration: BoxDecoration(
                    color: currentDir == 'vertical' ? const Color(0xFFFF9500) : Colors.black,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: currentDir == 'vertical' ? const Color(0xFFFF9500) : const Color(0xFF3A3A3C),
                      width: 2,
                    ),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.text_rotate_vertical, color: currentDir == 'vertical' ? Colors.black : Colors.white54, size: 24),
                        const SizedBox(height: 4),
                        Text(sOf(ref.read(languageProvider)).wmVertical, style: TextStyle(
                          color: currentDir == 'vertical' ? Colors.black : Colors.white54,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        )),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Tab 4: 大小
    if (_tabIndex == 4) {
      final sl = sOf(ref.read(languageProvider));
      final sizes = [
        ('small',  sl.small),
        ('medium', sl.medium),
        ('large',  sl.large),
      ];
      final currentSize = st.watermarkSize ?? 'medium';
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(
          children: sizes.map((s) {
            final isSelected = currentSize == s.$1;
            // 不同大小对应不同的字体大小预览
            final previewFontSize = s.$1 == 'small' ? 14.0 : s.$1 == 'medium' ? 20.0 : 28.0;
            return Expanded(
              child: GestureDetector(
                onTap: () => ref.read(cameraAppProvider.notifier).setWatermarkSize(s.$1),
                child: Container(
                  margin: EdgeInsets.only(right: s.$1 != 'large' ? 12 : 0),
                  height: 80,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isSelected ? const Color(0xFFFF9500) : const Color(0xFF3A3A3C),
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '26.03',
                          style: TextStyle(
                            color: const Color(0xFFFF8C00),
                            fontSize: previewFontSize,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(s.$2, style: TextStyle(
                          color: isSelected ? const Color(0xFFFF9500) : Colors.white54,
                          fontSize: 12,
                          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                        )),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      );
    }

    return const SizedBox.shrink();
  }

  // ── HSV 色盘（彩虹圆圈展开时显示）─────────────────────────────────────────────────────────
  List<Widget> _buildHsvPicker() {
    return [
      const SizedBox(height: 12),
      // 色相+饱和度二维色盘
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final pickerW = constraints.maxWidth;
            const pickerH = 200.0;
            return GestureDetector(
              onPanUpdate: (d) {
                final dx = d.localPosition.dx.clamp(0.0, pickerW);
                final dy = d.localPosition.dy.clamp(0.0, pickerH);
                final newH = _pickerHue;
                final newS = dx / pickerW;
                final newV = 1.0 - dy / pickerH;
                setState(() {
                  _pickerSaturation = newS;
                  _pickerValue = newV;
                });
                ref.read(cameraAppProvider.notifier)
                    .selectWatermarkColor(_hsvToHex(newH, newS, newV));
              },
              onTapDown: (d) {
                final dx = d.localPosition.dx.clamp(0.0, pickerW);
                final dy = d.localPosition.dy.clamp(0.0, pickerH);
                final newS = dx / pickerW;
                final newV = 1.0 - dy / pickerH;
                setState(() {
                  _pickerSaturation = newS;
                  _pickerValue = newV;
                });
                ref.read(cameraAppProvider.notifier)
                    .selectWatermarkColor(_hsvToHex(_pickerHue, newS, newV));
              },
              child: CustomPaint(
                size: Size(pickerW, pickerH),
                painter: _HsvSVPainter(
                  hue: _pickerHue,
                  saturation: _pickerSaturation,
                  value: _pickerValue,
                ),
              ),
            );
          },
        ),
      ),
      const SizedBox(height: 12),
      // 色相滑块
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final sliderW = constraints.maxWidth;
            const sliderH = 28.0;
            return GestureDetector(
              onPanUpdate: (d) {
                final dx = d.localPosition.dx.clamp(0.0, sliderW);
                final newH = dx / sliderW * 360;
                setState(() => _pickerHue = newH);
                ref.read(cameraAppProvider.notifier)
                    .selectWatermarkColor(_hsvToHex(newH, _pickerSaturation, _pickerValue));
              },
              onTapDown: (d) {
                final dx = d.localPosition.dx.clamp(0.0, sliderW);
                final newH = dx / sliderW * 360;
                setState(() => _pickerHue = newH);
                ref.read(cameraAppProvider.notifier)
                    .selectWatermarkColor(_hsvToHex(newH, _pickerSaturation, _pickerValue));
              },
              child: CustomPaint(
                size: Size(sliderW, sliderH),
                painter: _HueSliderPainter(hue: _pickerHue),
              ),
            );
          },
        ),
      ),
      const SizedBox(height: 8),
    ];
  }

  // ── 边框内容 ──────────────────────────────────────────────────────────────────────────
  Widget _buildFrameContent(CameraAppState st) {
    final frameEnabled = st.activeFrameId != null;

    if (_tabIndex == 0) {
      // 样式 Tab：边框样式选择（固定 3 列 GridView）
      final frames = widget.camera.modules.frames;
      final allCells = <Widget>[
        // 无边框选项（随机图标）
        _FrameStyleCell(
          isRandom: true,
          selected: st.activeFrameId == null,
          onTap: () {
            ref.read(cameraAppProvider.notifier).selectFrame('none');
            setState(() => _rebuildTabControllerIfNeeded());
          },
        ),
        ...frames.map((f) => _FrameStyleCell(
          frame: f,
          selected: st.activeFrameId == f.id,
          onTap: () {
            ref.read(cameraAppProvider.notifier).selectFrame(f.id);
            setState(() => _rebuildTabControllerIfNeeded());
          },
        )),
      ];
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            const itemSize = 64.0;  // 固定 item 大小 64dp
            const spacing = 12.0;
            final cols = ((constraints.maxWidth + spacing) / (itemSize + spacing)).floor().clamp(2, 8);
            final ratio = itemSize / itemSize;  // 1:1 正方形
            return GridView.count(
              crossAxisCount: cols,
              crossAxisSpacing: spacing,
              mainAxisSpacing: spacing,
              childAspectRatio: ratio,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: allCells,
            );
          },
        ),
      );
    }
    // 背景 Tab：颜色块选择（含透明选项，固定 3 列）
    final bgCells = <Widget>[
      // 透明背景（棋盘格图案）
      _BgColorCell(
        color: Colors.transparent,
        isTransparent: true,
        selected: (st.frameBackgroundColor ?? '').toLowerCase() == 'transparent' ||
                  (st.frameBackgroundColor ?? '').toLowerCase() == '#00000000',
        onTap: () => ref.read(cameraAppProvider.notifier).selectFrameBackground('transparent'),
      ),
      ..._kFrameBgColors.map((c) {
        // Flutter 3.x 中 Color.r/g/b 是 double (0.0~1.0)，需乘以 255 再取整
        final r = (c.r * 255).round().toRadixString(16).padLeft(2, '0');
        final g = (c.g * 255).round().toRadixString(16).padLeft(2, '0');
        final b = (c.b * 255).round().toRadixString(16).padLeft(2, '0');
        final hex = '#${r}${g}${b}'.toUpperCase();
        // 匹配用户选择的背景色（frameBackgroundColor）
        // 初始状态 frameBackgroundColor==null 时，默认白色被选中（对应 outerBackgroundColor #FFFFFF）
        final effectiveBg = st.frameBackgroundColor ?? '#FFFFFF';
        final isSelected = effectiveBg.toUpperCase() == hex;
        return _BgColorCell(
          color: c,
          selected: isSelected,
          onTap: () => ref.read(cameraAppProvider.notifier).selectFrameBackground(hex),
        );
      }),
    ];
    return Opacity(
      opacity: frameEnabled ? 1.0 : 0.4,
      child: IgnorePointer(
        ignoring: !frameEnabled,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              const itemSize = 64.0;  // 固定 item 大小 64dp
              const spacing = 12.0;
              final cols = ((constraints.maxWidth + spacing) / (itemSize + spacing)).floor().clamp(2, 8);
              return GridView.count(
                crossAxisCount: cols,
                crossAxisSpacing: spacing,
                mainAxisSpacing: spacing,
                childAspectRatio: 1.0,  // 1:1 正方形
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: bgCells,
              );
            },
          ),
        ),
      ),
    );
  }

  // ── 比例内容 ────────────────────────────────────────────────────────────────
  Widget _buildRatioContent(CameraAppState st) {
    final ratios = widget.camera.modules.ratios;
    final s = sOf(ref.read(languageProvider));
    // 检查是否有任何不支持边框的比例（展示提示文字）
    final hasFrameRestriction = ratios.any((r) => !r.supportsFrame);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 比例选项行（提示文字已移至标题行）
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: ratios.asMap().entries.map((entry) {
              final r = entry.value;
              final isActive = st.activeRatioId == r.id;
              return GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  ref.read(cameraAppProvider.notifier).selectRatio(r.id);
                  Navigator.of(context).pop();
                },
                child: Container(
                  margin: EdgeInsets.only(right: entry.key < ratios.length - 1 ? 28 : 0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 比例图标（空心矩形，宽高比例匹配）
                      _RatioShapeIcon(
                        widthRatio: r.width.toDouble(),
                        heightRatio: r.height.toDouble(),
                        selected: isActive,
                      ),
                      const SizedBox(height: 8),
                      // 比例文字
                      Text(
                        r.label,
                        style: TextStyle(
                          color: isActive ? Colors.black : const Color(0xFF8E8E93),
                          fontSize: 13,
                          fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  // ── 滤镜内容（复刻截图 13082）──────────────────────────────────────────────
  Widget _buildFilterContent(CameraAppState st) {
    final filters = widget.camera.modules.filters;
    final s = sOf(ref.read(languageProvider));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Tab行已移除（照片/视频Tab和样式管理按钮）
        // 胶卷图标列表
        SizedBox(
          height: 100,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            itemCount: filters.length,
            separatorBuilder: (_, __) => const SizedBox(width: 16),
            itemBuilder: (_, i) {
              final f = filters[i];
              final isActive = st.activeFilterId == f.id;
              return GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  ref.read(cameraAppProvider.notifier).selectFilter(f.id);
                },
                child: _FilmRollCell(filter: f, isActive: isActive),
              );
            },
          ),
        ),
      ],
    );
  }

  // ── 镜头内容 ────────────────────────────────────────────────────────────────
  Widget _buildLensContent(CameraAppState st) {
    final lenses = widget.camera.modules.lenses;
    return SizedBox(
      height: 90,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        itemCount: lenses.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          final l = lenses[i];
          final isActive = st.activeLensId == l.id;
          return GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              ref.read(cameraAppProvider.notifier).selectLens(l.id);
            },
            child: _LensCell(lens: l, isActive: isActive),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 辅助 Widgets
// ─────────────────────────────────────────────────────────────────────────────

/// Tab 按钮（照片/视频）
class _TabBtn extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool dark;

  const _TabBtn({required this.label, required this.selected, required this.onTap, this.dark = true});

  @override
  Widget build(BuildContext context) {
    final activeColor = dark ? _kTextPrimary : Colors.black;
    final inactiveColor = dark ? _kTextSecondary : const Color(0xFF8E8E93);
    return GestureDetector(
      onTap: onTap,
      child: Text(
        label,
        style: TextStyle(
          color: selected ? activeColor : inactiveColor,
          fontSize: 16,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    );
  }
}

/// 胶囊按钮（样图/管理）
class _PillBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool dark;

  const _PillBtn({required this.label, required this.icon, required this.onTap, this.dark = true});

  @override
  Widget build(BuildContext context) {
    final bg = dark ? _kSurface : const Color(0xFFE5E5EA);
    final fg = dark ? _kTextPrimary : Colors.black;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: fg, size: 14),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: fg, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

/// 相机单元格（相机列表行）
class _CameraCell extends StatelessWidget {
  final CameraEntry entry;
  final bool isActive;
  final bool isFavorite;
  final VoidCallback onTap;

  const _CameraCell({
    required this.entry,
    required this.isActive,
    required this.onTap,
    this.isFavorite = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 72,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: _kSurface,
                    borderRadius: BorderRadius.circular(12),
                    border: isActive
                        ? Border.all(color: _kOrange, width: 2.5)
                        : null,
                  ),
                  child: (entry.iconPath?.isNotEmpty ?? false)
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.asset(
                            entry.iconPath!,
                            width: 64,
                            height: 64,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Center(
                              child: Icon(
                                Icons.camera_alt_outlined,
                                color: isActive ? _kOrange : _kTextSecondary,
                                size: 28,
                              ),
                            ),
                          ),
                        )
                      : Center(
                          child: Icon(
                            Icons.camera_alt_outlined,
                            color: isActive ? _kOrange : _kTextSecondary,
                            size: 28,
                          ),
                        ),
                ),
                // 收藏角标：左上角黄色五角星
                if (isFavorite)
                  Positioned(
                    top: -2,
                    left: -2,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A1A),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: const Center(
                        child: Text(
                          '★',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFFFFCC00),
                            height: 1.0,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              entry.name,
              style: TextStyle(
                color: isActive ? _kOrange : _kTextPrimary,
                fontSize: 11,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// 功能按钮（时间水印/边框/比例/滤镜）
class _FuncBtn extends StatelessWidget {
  final String label;
  final Widget child;
  final bool isActive;
  final VoidCallback onTap;

  const _FuncBtn({required this.label, required this.child, required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 52,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 44, height: 44, child: child),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(color: _kTextSecondary, fontSize: 10),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// 镜头圆形按钮（功能图标行末尾）
class _LensBtn extends StatelessWidget {
  final LensDefinition lens;
  final bool isActive;
  final VoidCallback onTap;

  const _LensBtn({required this.lens, required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 52,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black,
                border: isActive
                    ? Border.all(color: Colors.white, width: 2.5)
                    : Border.all(color: Colors.transparent, width: 2.5),
              ),
              clipBehavior: Clip.antiAlias,
              child: lens.iconPath != null
                  ? Image.asset(
                      lens.iconPath!,
                      width: 44,
                      height: 44,
                      fit: BoxFit.cover,
                    )
                  : Center(
                      child: Icon(
                        Icons.lens_outlined,
                        color: isActive ? Colors.black : _kTextSecondary,
                        size: 22,
                      ),
                    ),
            ),
            const SizedBox(height: 2),
            if (isActive)
              Text(
                lens.nameEn,
                style: const TextStyle(color: _kTextPrimary, fontSize: 10),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
          ],
        ),
      ),
    );
  }
}

/// 分隔点
class _DotSeparator extends StatelessWidget {
  const _DotSeparator();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 16,
      child: Align(
        alignment: Alignment.center,
        child: Container(
          width: 5,
          height: 5,
          decoration: const BoxDecoration(
            color: _kTextSecondary,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

// ─── 功能图标内部图形 ──────────────────────────────────────────────────────────

/// 时间水印图标（时钟样式圆形）
class _WatermarkIcon extends StatelessWidget {
  final bool active;
  const _WatermarkIcon({required this.active});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? _kOrange.withAlpha(40) : _kSurface,
      ),
      child: Center(
        child: Icon(
          Icons.access_time_outlined,
          color: active ? _kOrange : _kTextSecondary,
          size: 22,
        ),
      ),
    );
  }
}

/// 边框图标（方形边框，无边框时叠加斜杠）
class _FrameIcon extends StatelessWidget {
  final bool active;
  const _FrameIcon({required this.active});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? _kOrange.withAlpha(40) : _kSurface,
      ),
      child: Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(
              Icons.crop_square_outlined,
              color: active ? _kOrange : _kTextSecondary,
              size: 22,
            ),
            // 无边框时叠加斜杠
            if (!active)
              CustomPaint(
                size: const Size(22, 22),
                painter: _DiagonalLinePainter(color: _kTextSecondary),
              ),
          ],
        ),
      ),
    );
  }
}

/// 比例图标（显示比例文字，复刻截图 13088）
class _RatioIcon extends StatelessWidget {
  final String label;
  final bool isDefault;
  const _RatioIcon({required this.label, this.isDefault = true});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _kSurface,
        border: isDefault
            ? Border.all(color: _kTextSecondary.withValues(alpha: 0.3), width: 1.5)
            : Border.all(color: _kOrange, width: 2),
      ),
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            color: isDefault ? _kTextPrimary : _kOrange,
            fontSize: label.length > 3 ? 9 : 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// 比例形状图标（空心矩形，宽高比例匹配，复刻截图 13087）
class _RatioShapeIcon extends StatelessWidget {
  final double widthRatio;
  final double heightRatio;
  final bool selected;
  const _RatioShapeIcon({
    required this.widthRatio,
    required this.heightRatio,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    // 根据比例计算图标宽高（在 40x50 的容器内缩放）
    const maxW = 36.0;
    const maxH = 44.0;
    double w, h;
    if (widthRatio / heightRatio > maxW / maxH) {
      w = maxW;
      h = maxW * heightRatio / widthRatio;
    } else {
      h = maxH;
      w = maxH * widthRatio / heightRatio;
    }
    return SizedBox(
      width: maxW,
      height: maxH,
      child: Center(
        child: Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? Colors.black : const Color(0xFF8E8E93),
              width: selected ? 2.5 : 1.5,
            ),
          ),
        ),
      ),
    );
  }
}

/// 滤镜图标（三色圆，复刻截图中的三色圆圈图标）
class _FilmFilterIcon extends StatelessWidget {
  const _FilmFilterIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: _kSurface,
      ),
      child: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CustomPaint(painter: _TriColorPainter()),
        ),
      ),
    );
  }
}

class _TriColorPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final cr = r * 0.6;
    final cx = size.width / 2;
    final cy = size.height / 2;

    final colors = [
      const Color(0xFFFF3B30), // 红
      const Color(0xFF34C759), // 绿
      const Color(0xFF007AFF), // 蓝
    ];
    final offsets = [
      Offset(cx - cr * 0.4, cy - cr * 0.35),
      Offset(cx + cr * 0.4, cy - cr * 0.35),
      Offset(cx, cy + cr * 0.4),
    ];

    for (int i = 0; i < 3; i++) {
      canvas.drawCircle(
        offsets[i],
        cr,
        Paint()
          ..color = colors[i].withAlpha(180)
          ..blendMode = BlendMode.screen,
      );
    }
  }

  @override
  bool shouldRepaint(_TriColorPainter old) => false;
}

// ─── 操作胶囊按钮（无水印/无边框）──────────────────────────────────────────────

class _ActionPill extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _ActionPill({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFE5E5EA),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.black,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

// ─── 颜色圆点（水印颜色选择器）────────────────────────────────────────────────

class _ColorDot extends StatelessWidget {
  final Color? color;
  final bool isRainbow;
  final bool selected;
  final VoidCallback onTap;

  const _ColorDot({this.color, this.isRainbow = false, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 10),
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: selected
              ? Border.all(color: Colors.black, width: 2.5)
              : Border.all(color: Colors.transparent, width: 2.5),
          gradient: isRainbow
              ? const SweepGradient(colors: [
                  Colors.red, Colors.orange, Colors.yellow,
                  Colors.green, Colors.blue, Colors.purple, Colors.red,
                ])
              : null,
          color: isRainbow ? null : color,
        ),
      ),
    );
  }
}

// ─── 边框样式单元格 ────────────────────────────────────────────────────────────

class _FrameStyleCell extends StatelessWidget {
  final FrameDefinition? frame;
  final bool isRandom;
  final bool selected;
  final VoidCallback onTap;

  const _FrameStyleCell({this.frame, this.isRandom = false, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: const Color(0xFFE5E5EA),
              borderRadius: BorderRadius.circular(10),
              border: selected
                  ? Border.all(color: Colors.black, width: 2.5)
                  : null,
            ),
            child: isRandom
                ? const Center(child: Icon(Icons.shuffle, color: Colors.black54, size: 28))
                : Center(
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: _parseColor(frame?.backgroundColor ?? '#FFFFFF'),
                        border: Border.all(color: Colors.black26, width: 1),
                      ),
                    ),
                  ),
          ),
          if (selected)
            Positioned(
              bottom: 4,
              right: 4,
              child: Container(
                width: 18,
                height: 18,
                decoration: const BoxDecoration(
                  color: Colors.black,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check, color: Colors.white, size: 12),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── // ─── 边框背景颜色单元格 ────────────────────────────────────────────

class _BgColorCell extends StatelessWidget {
  final Color color;
  final bool isTransparent;
  final bool selected;
  final VoidCallback onTap;

  const _BgColorCell({
    required this.color,
    required this.selected,
    required this.onTap,
    this.isTransparent = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? Colors.black : Colors.black12,
                width: selected ? 2.5 : 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: isTransparent
                  ? CustomPaint(painter: _CheckerPainter())
                  : ColoredBox(color: color),
            ),
          ),
          if (selected)
            Positioned(
              bottom: 4,
              right: 4,
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: isTransparent ? Colors.black54 : Colors.black,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check, color: Colors.white, size: 12),
              ),
            ),
        ],
      ),
    );
  }
}

/// 棋盘格透明背景画笔
class _CheckerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const cellSize = 9.0;
    final paint1 = Paint()..color = const Color(0xFFCCCCCC);
    final paint2 = Paint()..color = Colors.white;
    final cols = (size.width / cellSize).ceil();
    final rows = (size.height / cellSize).ceil();
    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        final isLight = (r + c) % 2 == 0;
        canvas.drawRect(
          Rect.fromLTWH(c * cellSize, r * cellSize, cellSize, cellSize),
          isLight ? paint2 : paint1,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerPainter old) => false;
}

/// 斜杠画笔（用于边框图标无边框状态）
class _DiagonalLinePainter extends CustomPainter {
  final Color color;
  const _DiagonalLinePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(size.width * 0.15, size.height * 0.85),
      Offset(size.width * 0.85, size.height * 0.15),
      paint,
    );
  }

  @override
  bool shouldRepaint(_DiagonalLinePainter old) => old.color != color;
}

/// 无边框开关
/// enabled = true 表示当前有边框（开关处于"关"状态，即"无边框"=关）
/// onChanged(true) = 开启边框，onChanged(false) = 关闭边框
class _FrameToggleSwitch extends ConsumerWidget {
  final bool enabled; // true = 有边框
  final ValueChanged<bool> onChanged; // true = 开启边框，false = 关闭边框

  const _FrameToggleSwitch({required this.enabled, required this.onChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = sOf(ref.watch(languageProvider));
    // "无边框" 标签：enabled=true时灰色（边框开启，无边框=关），enabled=false时黑色（无边框=开）
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          s.noFrame,
          style: TextStyle(
            color: !enabled ? Colors.black : const Color(0xFF8E8E93),
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: 6),
        Transform.scale(
          scale: 0.8,
          child: Switch.adaptive(
            value: !enabled, // 开关 ON = 无边框（enabled=false）
            onChanged: (switchOn) => onChanged(!switchOn), // switchOn=true→无边框→enabled=false
            activeColor: Colors.black,
            inactiveThumbColor: const Color(0xFF8E8E93),
            inactiveTrackColor: const Color(0xFFD1D1D6),
          ),
        ),
      ],
    );
  }
}


// ─── 胶卷图标单元格（滤镜列表）────────────────────────────────────────────────

class _FilmRollCell extends StatelessWidget {
  final FilterDefinition filter;
  final bool isActive;

  const _FilmRollCell({required this.filter, required this.isActive});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: const Color(0xFFE5E5EA),
                  borderRadius: BorderRadius.circular(8),
                  border: isActive
                      ? Border.all(color: Colors.black, width: 2)
                      : null,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // 胶卷图标（用 Icon 模拟）
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: _filmColor(filter.id),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Center(
                        child: Icon(Icons.filter_vintage, color: Colors.white, size: 20),
                      ),
                    ),
                  ],
                ),
              ),
              if (isActive)
                Positioned(
                  bottom: 4,
                  right: 4,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: const BoxDecoration(
                      color: Colors.black,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.check, color: Colors.white, size: 10),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            filter.nameEn,
            style: TextStyle(
              color: isActive ? Colors.black : const Color(0xFF555555),
              fontSize: 10,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Color _filmColor(String id) {
    if (id.contains('standard') || id.contains('classic')) return const Color(0xFF1C1C1E);
    if (id.contains('warm') || id.contains('orange')) return const Color(0xFF2E7D32);
    if (id.contains('high_contrast')) return const Color(0xFF1B5E20);
    return const Color(0xFF37474F);
  }
}

// ─── 镜头单元格（镜头列表）────────────────────────────────────────────────────

class _LensCell extends StatelessWidget {
  final LensDefinition lens;
  final bool isActive;

  const _LensCell({required this.lens, required this.isActive});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black,
            border: isActive
                ? Border.all(color: Colors.white, width: 2.5)
                : Border.all(color: const Color(0xFF444444), width: 1.5),
          ),
          clipBehavior: Clip.antiAlias,
          child: lens.iconPath != null
              ? Image.asset(
                  lens.iconPath!,
                  width: 60,
                  height: 60,
                  fit: BoxFit.cover,
                )
              : Center(
                  child: Icon(
                    Icons.lens_outlined,
                    color: isActive ? Colors.white : Colors.black54,
                    size: 28,
                  ),
                ),
        ),
        const SizedBox(height: 4),
        if (isActive)
          Text(
            lens.nameEn,
            style: const TextStyle(color: Colors.black, fontSize: 11),
          ),
      ],
    );
  }
}

// ─── 常量数据 ──────────────────────────────────────────────────────────────────

const _kWatermarkColors = [
  Color(0xFF34C759), // 绿
  Color(0xFFFFCC00), // 黄
  Color(0xFFFF9500), // 橙
  Color(0xFFFF3B30), // 橙红（选中）
  Color(0xFFFF2D55), // 红
  Color(0xFFFF2D96), // 粉
  Color(0xFF007AFF), // 蓝
  Color(0xFF000000), // 黑
];

// 背景色：黑/白 + 多巴胺配色（与相框6色对应）
const _kFrameBgColors = [
  Color(0xFFFFFFFF), // 纯白
  Color(0xFF1C1C1E), // 纯黑
  Color(0xFFEBE6F8), // 薰衣草紫
  Color(0xFFFCEEE1), // 蜜桃橙
  Color(0xFFE1F8EE), // 薄荷绿
  Color(0xFFE1EEFC), // 天空蓝
  Color(0xFFFCE6F0), // 玫瑰粉
  Color(0xFFF5F6FA), // 冷白
];

// ─── 工具函数 ──────────────────────────────────────────────────────────────────

Color _parseColor(String hex) {
  try {
    final h = hex.replaceAll('#', '');
    if (h.length == 6) return Color(int.parse('FF$h', radix: 16));
    if (h.length == 8) return Color(int.parse(h, radix: 16));
  } catch (_) {}
  return const Color(0xFFFF8A3D);
}

// ─── HSV 色盘 Painter（饱和度-亮度二维色盘）────────────────────────────────────

class _HsvSVPainter extends CustomPainter {
  final double hue;
  final double saturation;
  final double value;

  const _HsvSVPainter({required this.hue, required this.saturation, required this.value});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final radius = const Radius.circular(8);
    final rrect = RRect.fromRectAndRadius(rect, radius);

    // 底色：纯色（当前色相，饱和度=1，亮度=1）
    final baseColor = HSVColor.fromAHSV(1.0, hue, 1.0, 1.0).toColor();
    canvas.drawRRect(rrect, Paint()..color = baseColor);

    // 水平渐变：从白（左）到透明（右）
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white, Colors.white.withValues(alpha: 0)],
        ).createShader(rect),
    );

    // 垂直渐变：从透明（上）到黑（下）
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(rect),
    );

    // 选择指示器
    final cx = saturation * size.width;
    final cy = (1.0 - value) * size.height;
    final indicatorPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawCircle(Offset(cx, cy), 10, indicatorPaint);
    canvas.drawCircle(
      Offset(cx, cy),
      8,
      Paint()..color = HSVColor.fromAHSV(1.0, hue, saturation, value).toColor(),
    );
  }

  @override
  bool shouldRepaint(_HsvSVPainter old) =>
      old.hue != hue || old.saturation != saturation || old.value != value;
}

// ─── 色相滑块 Painter ──────────────────────────────────────────────────────────

class _HueSliderPainter extends CustomPainter {
  final double hue; // 0~360

  const _HueSliderPainter({required this.hue});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(14));

    // 彩虹渐变
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          colors: List.generate(37, (i) => HSVColor.fromAHSV(1.0, i * 10.0, 1.0, 1.0).toColor()),
        ).createShader(rect),
    );

    // 指示器（白色圆圈）
    final cx = hue / 360 * size.width;
    final cy = size.height / 2;
    canvas.drawCircle(
      Offset(cx, cy),
      size.height / 2 + 2,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    canvas.drawCircle(
      Offset(cx, cy),
      size.height / 2 - 1,
      Paint()..color = HSVColor.fromAHSV(1.0, hue, 1.0, 1.0).toColor(),
    );
  }

  @override
  bool shouldRepaint(_HueSliderPainter old) => old.hue != hue;
}
