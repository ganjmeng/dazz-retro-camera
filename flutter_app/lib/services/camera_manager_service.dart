// camera_manager_service.dart
// 相机管理数据层：收藏、启用/禁用、排序，持久化到 SharedPreferences
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/camera_registry.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CameraManagerState — 管理所有相机的收藏/启用/排序状态
// ─────────────────────────────────────────────────────────────────────────────
class CameraManagerState {
  /// 相机 ID 的排序列表（决定在管理页和选择栏中的显示顺序）
  final List<String> orderedIds;

  /// 已收藏的相机 ID 集合
  final Set<String> favoritedIds;

  /// 已启用的相机 ID 集合（未在此集合中的相机在选择栏不显示）
  final Set<String> enabledIds;

  const CameraManagerState({
    required this.orderedIds,
    required this.favoritedIds,
    required this.enabledIds,
  });

  CameraManagerState copyWith({
    List<String>? orderedIds,
    Set<String>? favoritedIds,
    Set<String>? enabledIds,
  }) =>
      CameraManagerState(
        orderedIds: orderedIds ?? this.orderedIds,
        favoritedIds: favoritedIds ?? this.favoritedIds,
        enabledIds: enabledIds ?? this.enabledIds,
      );

  /// 收藏的相机列表（按 orderedIds 顺序）
  List<String> get favoriteIds =>
      orderedIds.where((id) => favoritedIds.contains(id)).toList();

  /// 非收藏的相机列表（按 orderedIds 顺序）
  List<String> get nonFavoriteIds =>
      orderedIds.where((id) => !favoritedIds.contains(id)).toList();

  /// 已启用且按顺序排列的相机 ID（供相机选择栏使用）
  List<String> get enabledOrderedIds =>
      orderedIds.where((id) => enabledIds.contains(id)).toList();
}

// ─────────────────────────────────────────────────────────────────────────────
// CameraManagerNotifier
// ─────────────────────────────────────────────────────────────────────────────
class CameraManagerNotifier extends AsyncNotifier<CameraManagerState> {
  static const _keyOrder = 'cam_mgr_order';
  static const _keyFavorites = 'cam_mgr_favorites';
  static const _keyEnabled = 'cam_mgr_enabled';

  @override
  Future<CameraManagerState> build() async {
    final prefs = await SharedPreferences.getInstance();

    // 所有相机 ID（来自 kAllCameras 注册表）
    final allIds = kAllCameras.map((e) => e.id).toList();

    // 读取已保存的排序
    final savedOrder = prefs.getStringList(_keyOrder);
    List<String> orderedIds;
    if (savedOrder != null && savedOrder.isNotEmpty) {
      // 合并：已保存的顺序 + 新增的相机（追加到末尾）
      orderedIds = [
        ...savedOrder.where((id) => allIds.contains(id)),
        ...allIds.where((id) => !savedOrder.contains(id)),
      ];
    } else {
      orderedIds = List.from(allIds);
    }

    // 读取收藏
    final savedFavorites = prefs.getStringList(_keyFavorites);
    final favoritedIds =
        savedFavorites != null ? Set<String>.from(savedFavorites) : <String>{};

    // 读取启用状态（默认全部启用）
    // 关键修复：新增相机自动加入 enabledIds，避免旧用户升级后新相机不显示
    final savedEnabled = prefs.getStringList(_keyEnabled);
    final enabledIds = savedEnabled != null
        ? Set<String>.from([
            ...savedEnabled.where((id) => allIds.contains(id)), // 保留旧数据中仍存在的相机
            ...allIds.where((id) => !savedEnabled.contains(id)), // 新增相机自动启用
          ])
        : Set<String>.from(allIds);

    return CameraManagerState(
      orderedIds: orderedIds,
      favoritedIds: favoritedIds,
      enabledIds: enabledIds,
    );
  }

  // ── 切换收藏 ──────────────────────────────────────────────────────────────
  Future<void> toggleFavorite(String cameraId) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final newFavorites = Set<String>.from(current.favoritedIds);
    if (newFavorites.contains(cameraId)) {
      newFavorites.remove(cameraId);
    } else {
      newFavorites.add(cameraId);
    }
    final newState = current.copyWith(favoritedIds: newFavorites);
    state = AsyncData(newState);
    await _persist(newState);
  }

  // ── 切换启用/禁用 ─────────────────────────────────────────────────────────
  Future<void> toggleEnabled(String cameraId) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final newEnabled = Set<String>.from(current.enabledIds);
    if (newEnabled.contains(cameraId)) {
      // 至少保留1个启用的相机
      if (newEnabled.length <= 1) return;
      newEnabled.remove(cameraId);
    } else {
      newEnabled.add(cameraId);
    }
    final newState = current.copyWith(enabledIds: newEnabled);
    state = AsyncData(newState);
    await _persist(newState);
  }

  // ── 重新排序（拖动后调用）─────────────────────────────────────────────────
  Future<void> reorder(int oldIndex, int newIndex, {bool isFavoriteSection = false}) async {
    final current = state.valueOrNull;
    if (current == null) return;

    final newOrderedIds = List<String>.from(current.orderedIds);

    if (isFavoriteSection) {
      // 在收藏夹内拖动
      final favIds = current.favoriteIds;
      if (oldIndex >= favIds.length || newIndex > favIds.length) return;
      final movedId = favIds[oldIndex];
      final newFavIds = List<String>.from(favIds)..removeAt(oldIndex);
      final insertIdx = newIndex > oldIndex ? newIndex - 1 : newIndex;
      newFavIds.insert(insertIdx, movedId);

      // 重建全局排序：收藏夹顺序 + 非收藏顺序
      final nonFavIds = current.nonFavoriteIds;
      newOrderedIds.clear();
      newOrderedIds.addAll(newFavIds);
      newOrderedIds.addAll(nonFavIds);
    } else {
      // 在更多相机区域内拖动
      final nonFavIds = current.nonFavoriteIds;
      if (oldIndex >= nonFavIds.length || newIndex > nonFavIds.length) return;
      final movedId = nonFavIds[oldIndex];
      final newNonFavIds = List<String>.from(nonFavIds)..removeAt(oldIndex);
      final insertIdx = newIndex > oldIndex ? newIndex - 1 : newIndex;
      newNonFavIds.insert(insertIdx, movedId);

      // 重建全局排序
      final favIds = current.favoriteIds;
      newOrderedIds.clear();
      newOrderedIds.addAll(favIds);
      newOrderedIds.addAll(newNonFavIds);
    }

    final newState = current.copyWith(orderedIds: newOrderedIds);
    state = AsyncData(newState);
    await _persist(newState);
  }

  // ── 持久化 ────────────────────────────────────────────────────────────────
  Future<void> _persist(CameraManagerState s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyOrder, s.orderedIds);
    await prefs.setStringList(_keyFavorites, s.favoritedIds.toList());
    await prefs.setStringList(_keyEnabled, s.enabledIds.toList());
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider
// ─────────────────────────────────────────────────────────────────────────────
final cameraManagerProvider =
    AsyncNotifierProvider<CameraManagerNotifier, CameraManagerState>(
  CameraManagerNotifier.new,
);
