// camera_manager_screen.dart
// 相机管理页面：收藏夹 + 更多相机，支持单卡拖动排序、启用/禁用、收藏
// 设计风格：纯黑背景，深灰圆角卡片，金色星标，绿色勾选
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';
import '../../models/camera_registry.dart';
import '../../services/camera_manager_service.dart';

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

// ─────────────────────────────────────────────────────────────────────────────
// CameraManagerScreen
// ─────────────────────────────────────────────────────────────────────────────
class CameraManagerScreen extends ConsumerWidget {
  const CameraManagerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(cameraManagerProvider);

    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: _kWhite, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          '相机管理',
          style: TextStyle(
            color: _kWhite,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
      ),
      body: asyncState.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: _kWhite),
        ),
        error: (e, _) => Center(
          child: Text('加载失败: $e', style: const TextStyle(color: _kWhite)),
        ),
        data: (_) => const _CameraManagerBody(),
      ),
    );
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

    final favIds = state.favoriteIds;
    final nonFavIds = state.nonFavoriteIds;
    final notifier = ref.read(cameraManagerProvider.notifier);

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 收藏夹区域 ──────────────────────────────────────────────────
          if (favIds.isNotEmpty) ...[
            _SectionHeader(title: '收藏夹'),
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
          _SectionHeader(title: '更多相机'),
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
          child: Text(
            isFavoriteSection ? '暂无收藏相机' : '暂无相机',
            style: const TextStyle(color: Colors.white38, fontSize: 14),
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
                              colorBlendMode: isEnabled ? null : BlendMode.modulate,
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
                    isFavorited ? Icons.star_rounded : Icons.star_outline_rounded,
                    key: ValueKey(isFavorited),
                    color: isFavorited ? _kGold : Colors.white25,
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
