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
import 'camera_notifier.dart';

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

class _CameraConfigSheet extends ConsumerStatefulWidget {
  const _CameraConfigSheet();

  @override
  ConsumerState<_CameraConfigSheet> createState() => _CameraConfigSheetState();
}

class _CameraConfigSheetState extends ConsumerState<_CameraConfigSheet>
    with SingleTickerProviderStateMixin {
  // 当前选中的 Tab（照片/视频）
  int _tabIndex = 0; // 0=照片, 1=视频

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(cameraAppProvider);
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          // 左侧：照片 / 视频
          _TabBtn(label: '照片', selected: _tabIndex == 0, onTap: () => setState(() => _tabIndex = 0)),
          const SizedBox(width: 20),
          _TabBtn(label: '视频', selected: _tabIndex == 1, onTap: () => setState(() => _tabIndex = 1)),
          const Spacer(),
          // 右侧：样图 | 管理
          _PillBtn(label: '样图', icon: Icons.landscape_outlined, onTap: () {}),
          const SizedBox(width: 8),
          _PillBtn(label: '管理', icon: Icons.camera_alt_outlined, onTap: () {}),
        ],
      ),
    );
  }

  // ── 相机列表行 ──────────────────────────────────────────────────────────────
  Widget _buildCameraRow(CameraAppState st) {
    return SizedBox(
      height: 110,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: kAllCameras.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (ctx, i) {
          final entry = kAllCameras[i];
          final isActive = st.activeCameraId == entry.id;
          return _CameraCell(
            entry: entry,
            isActive: isActive,
            onTap: () {
              HapticFeedback.selectionClick();
              ref.read(cameraAppProvider.notifier).switchCamera(entry.id);
            },
          );
        },
      ),
    );
  }

  // ── 功能图标行 ──────────────────────────────────────────────────────────────
  Widget _buildFunctionRow(CameraAppState st, CameraDefinition cam) {
    final uiCap = cam.uiCapabilities;

    // 构建功能按钮列表
    final List<Widget> items = [];

    // 1. 时间水印
    if (uiCap.enableWatermark) {
      final active = st.activeWatermark;
      final hasWatermark = active != null && !active.isNone;
      items.add(_FuncBtn(
        label: '时间水印',
        child: _WatermarkIcon(active: hasWatermark),
        isActive: hasWatermark,
        onTap: () => _openSubPanel(context, _SubPanelType.watermark),
      ));
    }

    // 2. 边框
    if (uiCap.enableFrame) {
      final hasFrame = st.activeFrameId != null;
      items.add(_FuncBtn(
        label: '边框',
        child: _FrameIcon(active: hasFrame),
        isActive: hasFrame,
        onTap: () => _openSubPanel(context, _SubPanelType.frame),
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
        label: isDefaultRatio ? '原比例' : ratioLabel,
        child: _RatioIcon(
          label: isDefaultRatio ? '原比例' : ratioLabel,
          isDefault: isDefaultRatio,
        ),
        isActive: !isDefaultRatio, // 非默认比例时高亮
        onTap: () => _openSubPanel(context, _SubPanelType.ratio),
      ));
    }

    // 4. 滤镜（三色圆图标）
    if (uiCap.enableFilter) {
      items.add(_FuncBtn(
        label: '滤镜',
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
      builder: (_) => _SubPanel(type: type, camera: cam),
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

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: _tabCount, vsync: this);
    _tabCtrl.addListener(() {
      if (!_tabCtrl.indexIsChanging) setState(() => _tabIndex = _tabCtrl.index);
    });
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  int get _tabCount {
    switch (widget.type) {
      case _SubPanelType.watermark: return 5;
      case _SubPanelType.frame: return 2;
      default: return 1;
    }
  }

  String get _title {
    switch (widget.type) {
      case _SubPanelType.watermark: return '时间水印';
      case _SubPanelType.frame: return '边框';
      case _SubPanelType.ratio: return '比例';
      case _SubPanelType.filter: return '滤镜';
      case _SubPanelType.lens: return '镜头';
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(cameraAppProvider);

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
                children: [
                  Text(
                    _title,
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  // 右上角操作按鈕（无水印 / 无边框）
                  if (widget.type == _SubPanelType.watermark)
                    _ActionPill(
                      label: '无水印',
                      onTap: () => ref.read(cameraAppProvider.notifier).selectWatermark('none'),
                    ),
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
            if (widget.type == _SubPanelType.watermark) _buildWatermarkTabs(),
            if (widget.type == _SubPanelType.frame) _buildFrameTabs(),
            // 内容区
            _buildContent(st),
            SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
          ],
        ),
      ),
    );
  }

  // ── 水印 Tab 行 ─────────────────────────────────────────────────────────────
  Widget _buildWatermarkTabs() {
    const tabs = ['颜色', '样式', '位置', '方向', '大小'];
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

  // ── 边框 Tab 行 ─────────────────────────────────────────────────────────────
  Widget _buildFrameTabs() {
    const tabs = ['样式', '背景'];
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
  Widget _buildWatermarkContent(CameraAppState st) {
    if (_tabIndex == 0) {
      // 颜色 Tab：预览 + 颜色选择器
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
                color: _parseColor(st.activeWatermark?.color ?? '#FF8A3D'),
                fontSize: 28,
                fontFamily: 'monospace',
                letterSpacing: 2,
              ),
            ),
          ),
          const SizedBox(height: 16),
          // 颜色选择器
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: [
                // 彩虹（随机）
                _ColorDot(
                  isRainbow: true,
                  selected: false,
                  onTap: () {},
                ),
                ..._kWatermarkColors.map((c) {
                  final r = c.r.toInt().toRadixString(16).padLeft(2, '0');
                  final g = c.g.toInt().toRadixString(16).padLeft(2, '0');
                  final b = c.b.toInt().toRadixString(16).padLeft(2, '0');
                  final hex = '#${r}${g}${b}'.toUpperCase();
                  final isSelected = st.activeWatermark?.color?.toUpperCase() == hex;
                  return _ColorDot(
                    color: c,
                    selected: isSelected,
                    onTap: () => ref.read(cameraAppProvider.notifier).selectWatermarkColor(hex),
                  );
                }),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      );
    }
    // 其他 Tab（样式/位置/方向/大小）暂时显示占位
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: Text('功能开发中', style: TextStyle(color: Color(0xFF8E8E93))),
      ),
    );
  }

  // ── 边框内容 ────────────────────────────────────────────────────────────────
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
          onTap: () => ref.read(cameraAppProvider.notifier).selectFrame('none'),
        ),
        ...frames.map((f) => _FrameStyleCell(
          frame: f,
          selected: st.activeFrameId == f.id,
          onTap: frameEnabled
              ? () => ref.read(cameraAppProvider.notifier).selectFrame(f.id)
              : () => ref.read(cameraAppProvider.notifier).selectFrame(f.id),
        )),
      ];
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            const itemMinWidth = 100.0;
            const spacing = 12.0;
            final cols = ((constraints.maxWidth + spacing) / (itemMinWidth + spacing)).floor().clamp(2, 8);
            return GridView.count(
              crossAxisCount: cols,
              crossAxisSpacing: spacing,
              mainAxisSpacing: spacing,
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
        final r = c.r.toInt().toRadixString(16).padLeft(2, '0');
        final g = c.g.toInt().toRadixString(16).padLeft(2, '0');
        final b = c.b.toInt().toRadixString(16).padLeft(2, '0');
        final hex = '#${r}${g}${b}'.toUpperCase();
        // 匹配用户选择的背景色（frameBackgroundColor）
        final isSelected = (st.frameBackgroundColor?.toUpperCase() == hex);
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
              const itemMinWidth = 100.0;
              const spacing = 12.0;
              final cols = ((constraints.maxWidth + spacing) / (itemMinWidth + spacing)).floor().clamp(2, 8);
              return GridView.count(
                crossAxisCount: cols,
                crossAxisSpacing: spacing,
                mainAxisSpacing: spacing,
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
    // 检查是否有任何不支持边框的比例（展示提示文字）
    final hasFrameRestriction = ratios.any((r) => !r.supportsFrame);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 提示文字：仅1:1和4:3支持边框
        if (hasFrameRestriction)
          Padding(
            padding: const EdgeInsets.only(left: 20, right: 20, bottom: 4),
            child: Text(
              '仅1:1和4:3支持显示边框',
              style: const TextStyle(
                color: Color(0xFF8E8E93),
                fontSize: 13,
              ),
            ),
          ),
        // 比例选项行
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Tab 行：照片 | 视频  +  样图 | 管理
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              _TabBtn(label: '照片', selected: true, onTap: () {}, dark: false),
              const SizedBox(width: 20),
              _TabBtn(label: '视频', selected: false, onTap: () {}, dark: false),
              const Spacer(),
              _PillBtn(label: '样图', icon: Icons.landscape_outlined, onTap: () {}, dark: false),
              const SizedBox(width: 8),
              _PillBtn(label: '管理', icon: Icons.camera_alt_outlined, onTap: () {}, dark: false),
            ],
          ),
        ),
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
  final VoidCallback onTap;

  const _CameraCell({required this.entry, required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 72,
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
              child: entry.iconPath != null
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
                color: isActive ? _kTextPrimary : _kSurface,
                border: isActive
                    ? Border.all(color: _kTextPrimary, width: 2)
                    : null,
              ),
              child: Center(
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
      child: Center(
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
class _FrameToggleSwitch extends StatelessWidget {
  final bool enabled; // true = 有边框
  final ValueChanged<bool> onChanged; // true = 开启边框，false = 关闭边框

  const _FrameToggleSwitch({required this.enabled, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    // "无边框" 标签：enabled=true时灰色（边框开启，无边框=关），enabled=false时黑色（无边框=开）
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '无边框',
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
    return Stack(
      children: [
        Container(
          width: 64,
          height: 80,
          decoration: BoxDecoration(
            color: const Color(0xFFE5E5EA),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 胶卷图标（用 Icon 模拟）
              Container(
                width: 40,
                height: 50,
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
            color: isActive ? Colors.black : const Color(0xFFE5E5EA),
            border: isActive ? Border.all(color: Colors.black, width: 2) : null,
          ),
          child: Center(
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

const _kFrameBgColors = [
  Color(0xFFE8D84B), // 拍立得黄
  Color(0xFFF5F2EA), // 奶白
  Color(0xFFFFFFFF), // 纯白
  Color(0xFF6B8E5A), // 草绿
  Color(0xFFD4A5A5), // 粉红
  Color(0xFF7B9EC7), // 天蓝
  Color(0xFF5C4033), // 深棕
  Color(0xFF1C1C1E), // 黑
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
