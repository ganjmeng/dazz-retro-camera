// camera_manager_screen.dart
// 相机管理页面：收藏夹 + 更多相机，支持单卡拖动排序、启用/禁用、收藏
// 设计风格：纯黑背景，深灰圆角卡片，金色星标，绿色勾选
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/camera_registry.dart';
import '../../services/camera_manager_service.dart';
import '../../core/l10n.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 颜色常量
// ─────────────────────────────────────────────────────────────────────────────
const _kBg = Color(0xFF000000);
const _kCardBg = Color(0xFF1C1C1E);
const _kSectionBg = Color(0xFF111111);
const _kWhite = Colors.white;
const _kGold = Color(0xFFFFCC00);
const _kGreen = Color(0xFF30D158);
const _kGray = Color(0xFF48484A);
const _kOrange = Color(0xFFFF9500);
const _kWidgetPromptKey = 'camera_manager_widget_prompt_shown_v1';

// ─────────────────────────────────────────────────────────────────────────────
// CameraManagerScreen
// ─────────────────────────────────────────────────────────────────────────────
class CameraManagerScreen extends ConsumerStatefulWidget {
  const CameraManagerScreen({super.key});

  @override
  ConsumerState<CameraManagerScreen> createState() =>
      _CameraManagerScreenState();
}

class _CameraManagerScreenState extends ConsumerState<CameraManagerScreen> {
  bool _didSchedulePrompt = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didSchedulePrompt) return;
    _didSchedulePrompt = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeShowWidgetPrompt();
    });
  }

  Future<void> _maybeShowWidgetPrompt() async {
    if (!mounted) return;
    if (!_supportsWidgetPrompt(Theme.of(context).platform)) return;
    final prefs = await SharedPreferences.getInstance();
    final alreadyShown = prefs.getBool(_kWidgetPromptKey) ?? false;
    if (alreadyShown || !mounted) return;
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted) return;
    await prefs.setBool(_kWidgetPromptKey, true);
    if (!mounted) return;
    _showWidgetPromptDialog(context);
  }

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(cameraManagerProvider);
    final s = sOf(ref.watch(languageProvider));
    final supportsWidgets = _supportsWidgetPrompt(Theme.of(context).platform);

    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: _kWhite, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          s.cameraManage,
          style: const TextStyle(
            color: _kWhite,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
        actions: [
          // 重置按钮
          TextButton(
            onPressed: () => _showResetDialog(context, ref, s),
            child: Text(
              s.reset,
              style: const TextStyle(
                color: _kOrange,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
      body: asyncState.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: _kWhite),
        ),
        error: (e, _) => Center(
          child: Text('${s.loadFailed}: $e',
              style: const TextStyle(color: _kWhite)),
        ),
        data: (_) => const _CameraManagerBody(),
      ),
      bottomNavigationBar: supportsWidgets
          ? _WidgetAddBar(
              onTap: () => _showWidgetPromptDialog(context),
            )
          : null,
    );
  }

  void _showWidgetPromptDialog(BuildContext context) {
    final message = _widgetPromptMessage(Theme.of(context).platform);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text(
          '添加桌面小组件',
          style: TextStyle(
            color: _kWhite,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          message,
          style: TextStyle(
            color: Color(0xFFCCCCCC),
            fontSize: 14,
            height: 1.55,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              '稍后再说',
              style: TextStyle(color: Color(0xFF8E8E93), fontSize: 16),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              '知道了',
              style: TextStyle(
                color: _kOrange,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _supportsWidgetPrompt(TargetPlatform platform) {
    return platform == TargetPlatform.iOS || platform == TargetPlatform.android;
  }

  String _widgetPromptMessage(TargetPlatform platform) {
    if (platform == TargetPlatform.android) {
      return '把常用相机放到桌面会更快。\n\n长按桌面，选择“小组件”或“窗口小工具”，搜索 DAZZ，然后选择带相机图标的样式即可。';
    }
    return '把常用相机放到桌面会更快。\n\n长按桌面进入编辑模式，点击左上角“添加小组件”，搜索 DAZZ，然后选择带相机图标的样式即可。';
  }

  void _showResetDialog(BuildContext context, WidgetRef ref, S s) {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          s.resetTitle,
          style: const TextStyle(
            color: _kWhite,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          s.resetConfirm,
          style: const TextStyle(
            color: Color(0xFFAAAAAA),
            fontSize: 14,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              s.cancel,
              style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 16),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              s.reset,
              style: const TextStyle(
                color: _kOrange,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    ).then((confirmed) {
      if (confirmed == true) {
        HapticFeedback.mediumImpact();
        ref.read(cameraManagerProvider.notifier).resetToDefault();
      }
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _CameraManagerBody
// ─────────────────────────────────────────────────────────────────────────────
class _CameraManagerBody extends ConsumerWidget {
  const _CameraManagerBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(cameraManagerProvider).valueOrNull;
    if (state == null) return const SizedBox.shrink();
    final s = sOf(ref.watch(languageProvider));

    final favIds = state.favoriteIds;
    final nonFavIds = state.nonFavoriteIds;
    final notifier = ref.read(cameraManagerProvider.notifier);
    final platform = Theme.of(context).platform;
    final supportsWidgets =
        platform == TargetPlatform.iOS || platform == TargetPlatform.android;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (supportsWidgets) ...[
            _WidgetTipCard(
              onTap: () =>
                  (context.findAncestorStateOfType<_CameraManagerScreenState>())
                      ?._showWidgetPromptDialog(context),
            ),
            const SizedBox(height: 20),
          ],
          // ── 收藏夹区域 ──────────────────────────────────────────────────
          if (favIds.isNotEmpty) ...[
            _SectionHeader(title: s.favorites),
            const SizedBox(height: 12),
            _DraggableGrid(
              cameraIds: favIds,
              state: state,
              isFavoriteSection: true,
              onReorder: (oldIdx, newIdx) =>
                  notifier.reorder(oldIdx, newIdx, isFavoriteSection: true),
            ),
            const SizedBox(height: 28),
          ],

          // ── 更多相机区域 ─────────────────────────────────────────────────
          _SectionHeader(title: s.moreCameras),
          const SizedBox(height: 12),
          _DraggableGrid(
            cameraIds: nonFavIds,
            state: state,
            isFavoriteSection: false,
            onReorder: (oldIdx, newIdx) =>
                notifier.reorder(oldIdx, newIdx, isFavoriteSection: false),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _WidgetTipCard extends StatelessWidget {
  final VoidCallback onTap;

  const _WidgetTipCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: const LinearGradient(
            colors: [Color(0xFF1E1E22), Color(0xFF111113)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: Colors.white10),
        ),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: const LinearGradient(
                  colors: [Color(0xFF353541), Color(0xFF1E1E25)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: const Icon(Icons.widgets_rounded,
                  color: Colors.white, size: 28),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '添加桌面小组件',
                    style: TextStyle(
                      color: _kWhite,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    '把常用相机放到主屏，直接从桌面快速打开。',
                    style: TextStyle(
                      color: Color(0xFFAAAAAA),
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right_rounded,
                color: Colors.white38, size: 24),
          ],
        ),
      ),
    );
  }
}

class _WidgetAddBar extends StatelessWidget {
  final VoidCallback onTap;

  const _WidgetAddBar({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            height: 58,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: const LinearGradient(
                colors: [
                  Color(0xFF3F3F4B),
                  Color(0xFF23232B),
                  Color(0xFF111114),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x44000000),
                  blurRadius: 20,
                  offset: Offset(0, 8),
                ),
              ],
              border: Border.all(color: Colors.white12),
            ),
            child: Stack(
              children: [
                Positioned(
                  top: -16,
                  right: -6,
                  child: Container(
                    width: 88,
                    height: 88,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [Color(0x33FFFFFF), Color(0x00FFFFFF)],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: Colors.white.withAlpha(24),
                        ),
                        child: const Icon(
                          Icons.add_circle_outline_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '添加桌面小组件',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              '把常用相机固定到主屏',
                              style: TextStyle(
                                color: Color(0xB3FFFFFF),
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: Colors.white70,
                        size: 24,
                      ),
                    ],
                  ),
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
// _SectionHeader
// ─────────────────────────────────────────────────────────────────────────────
class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        color: _kWhite,
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _DraggableGrid — 支持单卡拖动的相机网格
// ─────────────────────────────────────────────────────────────────────────────
class _DraggableGrid extends ConsumerWidget {
  final List<String> cameraIds;
  final CameraManagerState state;
  final bool isFavoriteSection;
  final void Function(int oldIdx, int newIdx) onReorder;

  const _DraggableGrid({
    required this.cameraIds,
    required this.state,
    required this.isFavoriteSection,
    required this.onReorder,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (cameraIds.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: _kSectionBg,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Builder(
            builder: (ctx) {
              final sl =
                  sOf(ProviderScope.containerOf(ctx).read(languageProvider));
              return Text(
                isFavoriteSection ? sl.noFavCameras : sl.noCameras,
                style: const TextStyle(color: Colors.white38, fontSize: 14),
              );
            },
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: _kSectionBg,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(12),
      child: ReorderableGridView.count(
        crossAxisCount: 3,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 0.78,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        onReorder: (oldIdx, newIdx) {
          HapticFeedback.mediumImpact();
          onReorder(oldIdx, newIdx);
        },
        dragWidgetBuilderV2: DragWidgetBuilderV2(
          isScreenshotDragWidget: false,
          builder: (index, child, screenshot) {
            // 拖动时显示放大半透明的卡片
            return Opacity(
              opacity: 0.85,
              child: Transform.scale(
                scale: 1.08,
                child: child,
              ),
            );
          },
        ),
        children: cameraIds.map((camId) {
          return _CameraCard(
            key: ValueKey(camId),
            cameraId: camId,
            state: state,
          );
        }).toList(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _CameraCard — 单个相机卡片
// ─────────────────────────────────────────────────────────────────────────────
class _CameraCard extends ConsumerWidget {
  final String cameraId;
  final CameraManagerState state;

  const _CameraCard({
    required super.key,
    required this.cameraId,
    required this.state,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 实时读取最新状态（避免 state 参数过时）
    final liveState = ref.watch(cameraManagerProvider).valueOrNull ?? state;
    final entry = kAllCameras.where((e) => e.id == cameraId).firstOrNull;
    if (entry == null) return const SizedBox.shrink();

    final isFavorited = liveState.favoritedIds.contains(cameraId);
    final isEnabled = liveState.enabledIds.contains(cameraId);
    final notifier = ref.read(cameraManagerProvider.notifier);

    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        notifier.toggleEnabled(cameraId);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: _kCardBg,
          borderRadius: BorderRadius.circular(16),
          border: isEnabled
              ? Border.all(color: Colors.white12, width: 0.5)
              : Border.all(color: Colors.transparent, width: 0.5),
        ),
        child: Stack(
          children: [
            // ── 主内容 ──────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 16, 8, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 相机图标
                  Expanded(
                    child: Center(
                      child: entry.iconPath != null
                          ? Image.asset(
                              entry.iconPath!,
                              fit: BoxFit.contain,
                              color: isEnabled ? null : Colors.white38,
                              colorBlendMode:
                                  isEnabled ? null : BlendMode.modulate,
                              errorBuilder: (_, __, ___) => Icon(
                                Icons.camera_alt,
                                color: isEnabled ? _kWhite : Colors.white38,
                                size: 36,
                              ),
                            )
                          : Icon(
                              Icons.camera_alt,
                              color: isEnabled ? _kWhite : Colors.white38,
                              size: 36,
                            ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // 相机名称
                  Text(
                    entry.name,
                    style: TextStyle(
                      color: isEnabled ? _kWhite : Colors.white38,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  // 启用/禁用勾选按钮
                  GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      notifier.toggleEnabled(cameraId);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isEnabled
                            ? _kGreen.withAlpha(30)
                            : _kGray.withAlpha(80),
                        border: Border.all(
                          color: isEnabled ? _kGreen : _kGray,
                          width: 1.5,
                        ),
                      ),
                      child: isEnabled
                          ? const Icon(Icons.check, color: _kGreen, size: 15)
                          : const SizedBox.shrink(),
                    ),
                  ),
                ],
              ),
            ),

            // ── 星标收藏按钮（右上角）──────────────────────────────────
            Positioned(
              top: 5,
              right: 5,
              child: GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  notifier.toggleFavorite(cameraId);
                },
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (child, anim) => ScaleTransition(
                    scale: anim,
                    child: child,
                  ),
                  child: Icon(
                    isFavorited
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    key: ValueKey(isFavorited),
                    color: isFavorited ? _kGold : Colors.white.withAlpha(64),
                    size: 18,
                  ),
                ),
              ),
            ),

            // ── 禁用遮罩 ─────────────────────────────────────────────────
            if (!isEnabled)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withAlpha(80),
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
