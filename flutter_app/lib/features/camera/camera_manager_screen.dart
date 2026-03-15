// camera_manager_screen.dart
// 相机管理页面：收藏夹 + 更多相机，支持拖动排序、启用/禁用、收藏
// 设计风格：纯黑背景，深灰圆角卡片，金色星标，白色勾选
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/camera_registry.dart';
import '../../services/camera_manager_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 常量
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
        data: (state) => _CameraManagerBody(state: state),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _CameraManagerBody
// ─────────────────────────────────────────────────────────────────────────────
class _CameraManagerBody extends ConsumerStatefulWidget {
  final CameraManagerState state;
  const _CameraManagerBody({required this.state});

  @override
  ConsumerState<_CameraManagerBody> createState() => _CameraManagerBodyState();
}

class _CameraManagerBodyState extends ConsumerState<_CameraManagerBody> {
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(cameraManagerProvider).valueOrNull;
    if (state == null) return const SizedBox.shrink();

    final favIds = state.favoriteIds;
    final nonFavIds = state.nonFavoriteIds;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 收藏夹区域 ──────────────────────────────────────────────────
          if (favIds.isNotEmpty) ...[
            _SectionHeader(title: '收藏夹'),
            const SizedBox(height: 12),
            _FavoriteGrid(cameraIds: favIds, state: state),
            const SizedBox(height: 28),
          ],

          // ── 更多相机区域 ─────────────────────────────────────────────────
          _SectionHeader(title: '更多相机'),
          const SizedBox(height: 12),
          _ReorderableGrid(cameraIds: nonFavIds, state: state),
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
// _FavoriteGrid — 收藏夹网格（支持拖动排序）
// ─────────────────────────────────────────────────────────────────────────────
class _FavoriteGrid extends ConsumerWidget {
  final List<String> cameraIds;
  final CameraManagerState state;
  const _FavoriteGrid({required this.cameraIds, required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      decoration: BoxDecoration(
        color: _kSectionBg,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(12),
      child: _buildDraggableGrid(context, ref),
    );
  }

  Widget _buildDraggableGrid(BuildContext context, WidgetRef ref) {
    // 使用 ReorderableWrap 模拟网格拖动
    // 每行3列
    return LayoutBuilder(builder: (context, constraints) {
      final itemWidth = (constraints.maxWidth - 24) / 3;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (int i = 0; i < cameraIds.length; i++)
            SizedBox(
              width: itemWidth,
              child: _CameraCard(
                cameraId: cameraIds[i],
                state: state,
                isFavoriteSection: true,
              ),
            ),
        ],
      );
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ReorderableGrid — 更多相机网格（支持长按拖动排序）
// ─────────────────────────────────────────────────────────────────────────────
class _ReorderableGrid extends ConsumerStatefulWidget {
  final List<String> cameraIds;
  final CameraManagerState state;
  const _ReorderableGrid({required this.cameraIds, required this.state});

  @override
  ConsumerState<_ReorderableGrid> createState() => _ReorderableGridState();
}

class _ReorderableGridState extends ConsumerState<_ReorderableGrid> {
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(cameraManagerProvider).valueOrNull;
    if (state == null) return const SizedBox.shrink();
    final ids = state.nonFavoriteIds;

    return Container(
      decoration: BoxDecoration(
        color: _kSectionBg,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(builder: (context, constraints) {
        final itemWidth = (constraints.maxWidth - 24) / 3;
        // 将列表转为行列结构，每行3个
        final rows = <List<String>>[];
        for (int i = 0; i < ids.length; i += 3) {
          rows.add(ids.sublist(i, i + 3 > ids.length ? ids.length : i + 3));
        }

        return ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: rows.length,
          onReorder: (oldRow, newRow) {
            // 将行索引转换为元素索引
            final oldIdx = oldRow * 3;
            final newIdx = newRow * 3;
            ref.read(cameraManagerProvider.notifier).reorder(
                  oldIdx,
                  newIdx,
                  isFavoriteSection: false,
                );
          },
          itemBuilder: (context, rowIdx) {
            final rowIds = rows[rowIdx];
            return Padding(
              key: ValueKey('row_$rowIdx'),
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  for (int col = 0; col < 3; col++)
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                          left: col == 0 ? 0 : 6,
                          right: col == 2 ? 0 : 6,
                        ),
                        child: col < rowIds.length
                            ? _CameraCard(
                                cameraId: rowIds[col],
                                state: state,
                                isFavoriteSection: false,
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      }),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _CameraCard — 单个相机卡片
// ─────────────────────────────────────────────────────────────────────────────
class _CameraCard extends ConsumerWidget {
  final String cameraId;
  final CameraManagerState state;
  final bool isFavoriteSection;

  const _CameraCard({
    required this.cameraId,
    required this.state,
    required this.isFavoriteSection,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = kAllCameras.where((e) => e.id == cameraId).firstOrNull;
    if (entry == null) return const SizedBox.shrink();

    final isFavorited = state.favoritedIds.contains(cameraId);
    final isEnabled = state.enabledIds.contains(cameraId);
    final notifier = ref.read(cameraManagerProvider.notifier);

    return GestureDetector(
      onTap: () => notifier.toggleEnabled(cameraId),
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
            // 主内容
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 16, 8, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 相机图标
                  SizedBox(
                    height: 64,
                    width: 64,
                    child: entry.iconPath != null
                        ? Image.asset(
                            entry.iconPath!,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Icon(
                              Icons.camera_alt,
                              color: _kWhite,
                              size: 40,
                            ),
                          )
                        : const Icon(
                            Icons.camera_alt,
                            color: _kWhite,
                            size: 40,
                          ),
                  ),
                  const SizedBox(height: 8),
                  // 相机名称
                  Text(
                    entry.name,
                    style: TextStyle(
                      color: isEnabled ? _kWhite : Colors.white38,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  // 启用/禁用勾选按钮
                  GestureDetector(
                    onTap: () => notifier.toggleEnabled(cameraId),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 28,
                      height: 28,
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
                          ? const Icon(Icons.check, color: _kGreen, size: 16)
                          : const SizedBox.shrink(),
                    ),
                  ),
                ],
              ),
            ),

            // 星标收藏按钮（右上角）
            Positioned(
              top: 6,
              right: 6,
              child: GestureDetector(
                onTap: () => notifier.toggleFavorite(cameraId),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    isFavorited ? Icons.star : Icons.star_border,
                    key: ValueKey(isFavorited),
                    color: isFavorited ? _kGold : Colors.white30,
                    size: 18,
                  ),
                ),
              ),
            ),

            // 禁用遮罩
            if (!isEnabled)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withAlpha(100),
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
