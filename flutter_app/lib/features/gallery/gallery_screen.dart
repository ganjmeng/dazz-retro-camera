// ignore_for_file: use_build_context_synchronously
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_view/photo_view.dart';
import 'package:share_plus/share_plus.dart';
import '../../models/camera_registry.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 全局缩略图字节缓存（内存级，App 存活期间有效，避免重复解码）
// ─────────────────────────────────────────────────────────────────────────────
class _ThumbCache {
  static final Map<String, Uint8List> _cache = {};

  static Uint8List? get(String id) => _cache[id];

  static void set(String id, Uint8List data) {
    // 最多缓存 500 张缩略图（约 500×300×300×4 = ~180MB 极端情况，实际 JPEG 约 5-15KB/张，500张约 5-7MB）
    if (_cache.length >= 500) {
      _cache.remove(_cache.keys.first);
    }
    _cache[id] = data;
  }

  static void remove(String id) => _cache.remove(id);
  static void clear() => _cache.clear();
}

// ─────────────────────────────────────────────────────────────────────────────
// 全局相册资产缓存（内存级，App 存活期间有效）
// ─────────────────────────────────────────────────────────────────────────────
class _GalleryCache {
  static List<AssetEntity>? _assets;
  static DateTime? _loadedAt;

  static bool get isValid {
    if (_assets == null || _loadedAt == null) return false;
    return DateTime.now().difference(_loadedAt!).inMinutes < 5;
  }

  static List<AssetEntity>? get assets => _assets;

  static void set(List<AssetEntity> assets) {
    _assets = List.unmodifiable(assets);
    _loadedAt = DateTime.now();
  }

  static void invalidate() {
    _assets = null;
    _loadedAt = null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 相机分类数据
// ─────────────────────────────────────────────────────────────────────────────
class _AlbumEntry {
  final String id;
  final String name;
  final IconData? icon;
  final String? iconPath;
  const _AlbumEntry({required this.id, required this.name, this.icon, this.iconPath});
}

// ─────────────────────────────────────────────────────────────────────────────
// GalleryScreen — 相册列表主页
// ─────────────────────────────────────────────────────────────────────────────
class GalleryScreen extends StatefulWidget {
  final AssetEntity? initialAsset;
  final String? initialCameraId;

  const GalleryScreen({super.key, this.initialAsset, this.initialCameraId});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  List<AssetEntity> _allDazzAssets = [];
  List<AssetEntity> _assets = [];
  bool _isLoading = true;
  bool _isSelectionMode = false;
  Set<String> _selectedIds = {};
  bool _showAlbumDropdown = false;
  String _currentAlbumId = 'all';
  String _currentAlbumName = '全部照片';
  Map<String, int> _albumCounts = {};
  List<_AlbumEntry> _cameraAlbumEntries = [
    const _AlbumEntry(id: 'all', name: '全部照片', icon: Icons.photo_library_outlined),
  ];

  @override
  void initState() {
    super.initState();
    // 每次打开相册强制刷新：拍照发生在相册页面之外，缓存无法感知新照片
    _GalleryCache.invalidate();
    PhotoManager.addChangeCallback(_onMediaChange);
    PhotoManager.startChangeNotify();
    _fetchAssets();
  }

  void _onMediaChange(MethodCall call) {
    _GalleryCache.invalidate();
    if (mounted) _fetchAssets();
  }

  @override
  void dispose() {
    PhotoManager.removeChangeCallback(_onMediaChange);
    PhotoManager.stopChangeNotify();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.initialAsset != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openDetail(widget.initialAsset!, fromLongPress: true);
      });
    }
  }

  Future<void> _fetchAssets() async {
    // 有缓存时立即显示，无需 loading
    if (_GalleryCache.isValid && _GalleryCache.assets != null) {
      final cached = _GalleryCache.assets!;
      _rebuildFromAssets(cached, showLoading: false);
      return;
    }

    setState(() => _isLoading = true);

    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('请在设置中开启相册访问权限，才能查看成片'),
            backgroundColor: Color(0xFF3A3A3C),
          ),
        );
      }
      return;
    }

    // 直接查询，新照片由 changeCallback 触发刷新（移除 releaseCache 避免不必要的延迟）
    final allPaths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      hasAll: true,
      onlyAll: false,
      filterOption: FilterOptionGroup(
        orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
      ),
    );

    if (allPaths.isEmpty) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    // 查找 DAZZ 相册
    AssetPathEntity? dazzPath;
    for (final p in allPaths) {
      final upper = p.name.toUpperCase();
      if (upper == 'DAZZ' || upper.endsWith('/DAZZ') || upper.contains('DAZZ')) {
        dazzPath = p;
        break;
      }
    }

    List<AssetEntity> assets;

    if (dazzPath == null) {
      // 从根相册过滤文件名包含 dazz 的照片
      final rootPath = allPaths.firstWhere((p) => p.isAll, orElse: () => allPaths.first);
      final rootCount = await rootPath.assetCountAsync;
      final rootAssets = await rootPath.getAssetListRange(start: 0, end: rootCount.clamp(0, 5000));
      assets = rootAssets.where((a) {
        final title = (a.title ?? '').toLowerCase();
        return title.startsWith('dazz_') || title.contains('dazz');
      }).toList();
    } else {
      final count = await dazzPath.assetCountAsync;
      assets = await dazzPath.getAssetListRange(start: 0, end: count.clamp(0, 5000));
    }

    _GalleryCache.set(assets);
    _rebuildFromAssets(assets, showLoading: false);

    // 后台预生成前 30 张缩略图，加快首屏渲染
    _prefetchThumbs(assets.take(30).toList());
  }

  /// 后台并行预生成缩略图（不阻塞 UI，最多 8 并发）
  Future<void> _prefetchThumbs(List<AssetEntity> assets) async {
    // 分批并行，每批 8 张，避免一次性占用过多线程
    const batchSize = 8;
    final toLoad = assets.where((a) => _ThumbCache.get(a.id) == null).toList();
    for (int i = 0; i < toLoad.length; i += batchSize) {
      final batch = toLoad.skip(i).take(batchSize).toList();
      await Future.wait(batch.map((asset) async {
        final data = await asset.thumbnailDataWithSize(const ThumbnailSize(300, 300));
        if (data != null) _ThumbCache.set(asset.id, data);
      }));
    }
  }

  void _rebuildFromAssets(List<AssetEntity> assets, {required bool showLoading}) {
    final counts = <String, int>{'all': assets.length};
    final cameraIdsFound = <String>{};
    for (final asset in assets) {
      final title = (asset.title ?? '').toLowerCase();
      for (final cam in kAllCameras) {
        if (title.contains(cam.id.toLowerCase())) {
          cameraIdsFound.add(cam.id);
          counts[cam.id] = (counts[cam.id] ?? 0) + 1;
          break;
        }
      }
    }
    final entries = <_AlbumEntry>[
      const _AlbumEntry(id: 'all', name: '全部照片', icon: Icons.photo_library_outlined),
    ];
    for (final cam in kAllCameras) {
      if (cameraIdsFound.contains(cam.id)) {
        entries.add(_AlbumEntry(id: cam.id, name: cam.name, icon: Icons.camera_alt_outlined, iconPath: cam.iconPath));
      }
    }
    if (mounted) {
      setState(() {
        _allDazzAssets = assets;
        _assets = assets;
        _albumCounts = counts;
        _cameraAlbumEntries = entries;
        _isLoading = showLoading;
      });
      _applyInitialCameraFilter();
    }
  }

  void _applyInitialCameraFilter() {
    final id = widget.initialCameraId;
    if (id == null || id == 'all') return;
    if (_cameraAlbumEntries.any((e) => e.id == id)) {
      _filterByCamera(id);
    }
  }

  void _filterByCamera(String cameraId) {
    setState(() {
      _currentAlbumId = cameraId;
      _currentAlbumName = _cameraAlbumEntries
          .firstWhere((e) => e.id == cameraId,
              orElse: () => const _AlbumEntry(id: 'all', name: '全部照片'))
          .name;
      _showAlbumDropdown = false;
      _assets = cameraId == 'all'
          ? _allDazzAssets
          : _allDazzAssets.where((asset) {
              final title = (asset.title ?? '').toLowerCase();
              return title.contains(cameraId.toLowerCase());
            }).toList();
    });
  }

  void _openDetail(AssetEntity asset, {bool fromLongPress = false}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PhotoDetailPage(
          asset: asset,
          allAssets: _assets,
          fromLongPress: fromLongPress,
        ),
      ),
    );
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final toDelete = _assets.where((a) => _selectedIds.contains(a.id)).map((a) => a.id).toList();
    await PhotoManager.editor.deleteWithIds(toDelete);
    // 清除被删除照片的缩略图缓存
    for (final id in toDelete) {
      _ThumbCache.remove(id);
    }
    _GalleryCache.invalidate();
    setState(() {
      _assets.removeWhere((a) => _selectedIds.contains(a.id));
      _allDazzAssets.removeWhere((a) => _selectedIds.contains(a.id));
      _selectedIds.clear();
      _isSelectionMode = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Column(
            children: [
              _buildAppBar(),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : _buildGrid(),
              ),
            ],
          ),
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 24,
            left: 24,
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: 56,
                height: 56,
                decoration: const BoxDecoration(
                  color: Color(0xFF3A3A3C),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.photo_camera_outlined, color: Colors.white, size: 28),
              ),
            ),
          ),
          if (_showAlbumDropdown) _buildAlbumDropdown(),
        ],
      ),
    );
  }

  Widget _buildAppBar() {
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 20),
              onPressed: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: GestureDetector(
                onTap: _cameraAlbumEntries.length > 1
                    ? () => setState(() => _showAlbumDropdown = !_showAlbumDropdown)
                    : null,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    Flexible(
                      child: Text(
                        _currentAlbumName,
                        style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_cameraAlbumEntries.length > 1) ...[
                      const SizedBox(width: 4),
                      Icon(
                        _showAlbumDropdown ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                        color: Colors.white,
                        size: 20,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            _isSelectionMode
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_selectedIds.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.white),
                          onPressed: _deleteSelected,
                        ),
                      TextButton(
                        onPressed: () => setState(() {
                          _isSelectionMode = false;
                          _selectedIds.clear();
                        }),
                        child: const Text('取消', style: TextStyle(color: Colors.white, fontSize: 15)),
                      ),
                    ],
                  )
                : TextButton(
                    onPressed: () => setState(() => _isSelectionMode = true),
                    child: const Text('选择', style: TextStyle(color: Colors.white, fontSize: 15)),
                  ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid() {
    if (_assets.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: const Color(0xFF2C2C2E),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(Icons.camera_alt_outlined, color: Color(0xFFFF8C00), size: 40),
            ),
            const SizedBox(height: 16),
            const Text('还没有照片', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text('用 DAZZ 拍摄的照片会出现在这里', style: TextStyle(color: Colors.grey, fontSize: 14)),
          ],
        ),
      );
    }

    final itemCount = _assets.length + 1;
    return GridView.builder(
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 0,
        mainAxisSpacing: 0,
      ),
      itemCount: itemCount,
      // 关键优化：addRepaintBoundaries=true 让每个 cell 独立重绘，避免全局重绘
      addRepaintBoundaries: true,
      itemBuilder: (ctx, index) {
        if (index == 0) {
          return GestureDetector(
            onTap: () {},
            child: Container(
              color: const Color(0xFF1A1A1A),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2C2C2E),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.add_photo_alternate_outlined, color: Color(0xFFFF8C00), size: 28),
                  ),
                  const SizedBox(height: 8),
                  const Text('导入图片', style: TextStyle(color: Color(0xFFFF8C00), fontSize: 12)),
                ],
              ),
            ),
          );
        }

        final asset = _assets[index - 1];
        final isSelected = _selectedIds.contains(asset.id);

        return GestureDetector(
          onTap: () {
            if (_isSelectionMode) {
              _toggleSelection(asset.id);
            } else {
              HapticFeedback.selectionClick();
              _openDetail(asset);
            }
          },
          onLongPress: () {
            if (!_isSelectionMode) {
              HapticFeedback.mediumImpact();
              setState(() {
                _isSelectionMode = true;
                _selectedIds.add(asset.id);
              });
            }
          },
          child: _RetroPhotoCell(
            asset: asset,
            isSelected: isSelected,
            isSelectionMode: _isSelectionMode,
          ),
        );
      },
    );
  }

  Widget _buildAlbumDropdown() {
    return GestureDetector(
      onTap: () => setState(() => _showAlbumDropdown = false),
      child: Stack(
        children: [
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(color: Colors.black.withAlpha(100)),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 52,
            left: 0,
            right: 0,
            child: GestureDetector(
              onTap: () {},
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (int i = 0; i < _cameraAlbumEntries.length; i++) ...[
                    _buildDropdownItem(_cameraAlbumEntries[i]),
                    if (i < _cameraAlbumEntries.length - 1)
                      Divider(
                        height: 1,
                        thickness: 0.5,
                        color: Colors.white.withAlpha(20),
                        indent: 100,
                        endIndent: 20,
                      ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDropdownItem(_AlbumEntry entry) {
    final count = _albumCounts[entry.id] ?? 0;
    final isActive = entry.id == _currentAlbumId;
    return GestureDetector(
      onTap: () => _filterByCamera(entry.id),
      child: Container(
        color: Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: const Color(0xFF2C2C2E),
                borderRadius: BorderRadius.circular(14),
              ),
              clipBehavior: Clip.antiAlias,
              child: entry.iconPath != null
                  ? Image.asset(
                      entry.iconPath!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Icon(
                        entry.icon ?? Icons.camera_alt_outlined,
                        color: isActive ? const Color(0xFFFF8C00) : Colors.white54,
                        size: 32,
                      ),
                    )
                  : Icon(
                      entry.icon ?? Icons.photo_library_outlined,
                      color: isActive ? const Color(0xFFFF8C00) : Colors.white54,
                      size: 32,
                    ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                entry.name,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                  letterSpacing: 0.2,
                ),
              ),
            ),
            Text(
              '$count',
              style: TextStyle(
                color: isActive ? Colors.white : Colors.white54,
                fontSize: 17,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 复古相片格子（使用全局缩略图缓存，秒开）
// ─────────────────────────────────────────────────────────────────────────────
class _RetroPhotoCell extends StatefulWidget {
  final AssetEntity asset;
  final bool isSelected;
  final bool isSelectionMode;

  const _RetroPhotoCell({
    required this.asset,
    required this.isSelected,
    required this.isSelectionMode,
  });

  @override
  State<_RetroPhotoCell> createState() => _RetroPhotoCellState();
}

class _RetroPhotoCellState extends State<_RetroPhotoCell> {
  Uint8List? _thumb;

  @override
  void initState() {
    super.initState();
    // 优先从全局缓存取，命中则同步赋值，无需 setState
    final cached = _ThumbCache.get(widget.asset.id);
    if (cached != null) {
      _thumb = cached;
    } else {
      _loadThumb();
    }
  }

  Future<void> _loadThumb() async {
    final data = await widget.asset.thumbnailDataWithSize(const ThumbnailSize(300, 300));
    if (data != null) {
      _ThumbCache.set(widget.asset.id, data);
      if (mounted) setState(() => _thumb = data);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _thumb != null
            ? Image.memory(_thumb!, fit: BoxFit.cover, gaplessPlayback: true)
            : Container(color: const Color(0xFF1C1C1E)),
        if (widget.asset.type == AssetType.video)
          Positioned(
            bottom: 4,
            right: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _formatDuration(widget.asset.videoDuration),
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          ),
        if (widget.isSelectionMode)
          Positioned(
            top: 4,
            right: 4,
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.isSelected ? Colors.blue : Colors.black.withAlpha(100),
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: widget.isSelected
                  ? const Icon(Icons.check, color: Colors.white, size: 14)
                  : null,
            ),
          ),
      ],
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PhotoDetailPage — 相片详情页（支持手势缩放 + 滑动返回）
// ─────────────────────────────────────────────────────────────────────────────
class PhotoDetailPage extends StatefulWidget {
  final AssetEntity asset;
  final List<AssetEntity> allAssets;
  final bool fromLongPress;

  const PhotoDetailPage({
    super.key,
    required this.asset,
    required this.allAssets,
    this.fromLongPress = false,
  });

  @override
  State<PhotoDetailPage> createState() => _PhotoDetailPageState();
}

class _PhotoDetailPageState extends State<PhotoDetailPage> {
  late int _currentIndex;
  late PageController _pageController;
  String _cameraName = '';

  // 每页的图片数据缓存（key: assetId）
  // 优先显示原图，如果原图未加载则显示缩略图占位（避免闪烁）
  final Map<String, Uint8List> _fullDataCache = {};  // 原图数据
  final Map<String, Uint8List> _thumbDataCache = {}; // 缩略图占位数据
  // 每页的 PhotoViewScaleStateController（用于重置缩放）
  final Map<int, PhotoViewScaleStateController> _scaleControllers = {};

  // 滑动返回相关
  double _dragOffset = 0.0;
  bool _isDragging = false;
  bool _isZoomed = false; // 当前页是否已缩放（缩放时禁用滑动返回）

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.allAssets.indexOf(widget.asset);
    if (_currentIndex < 0) _currentIndex = 0;
    _pageController = PageController(initialPage: _currentIndex);
    _parseCameraName(widget.asset);
    // 预加载当前页 + 相邻页
    _preloadPages(_currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final c in _scaleControllers.values) {
      c.dispose();
    }
    _fullDataCache.clear();
    _thumbDataCache.clear();
    super.dispose();
  }

  void _parseCameraName(AssetEntity asset) {
    final title = (asset.title ?? '').toLowerCase();
    for (final cam in kAllCameras) {
      if (title.contains(cam.id.toLowerCase())) {
        if (mounted) setState(() => _cameraName = cam.name);
        return;
      }
    }
    if (mounted) setState(() => _cameraName = 'DAZZ');
  }

  /// 预加载当前页及相邻 ±1 页
  void _preloadPages(int index) {
    final indices = [index - 1, index, index + 1]
        .where((i) => i >= 0 && i < widget.allAssets.length)
        .toList();
    for (final i in indices) {
      final asset = widget.allAssets[i];
      if (!_fullDataCache.containsKey(asset.id)) {
        _loadAsset(asset);
      }
    }
  }

  Future<void> _loadAsset(AssetEntity asset) async {
    if (_fullDataCache.containsKey(asset.id)) return;
    // 先用缩略图占位（如果缓存中有）——不触发 setState，避免闪烁
    final thumb = _ThumbCache.get(asset.id);
    if (thumb != null) {
      _thumbDataCache[asset.id] = thumb;
    }
    // 加载原图（只更新 _fullDataCache，不替换占位图）
    final data = await asset.originBytes;
    if (data != null && mounted) {
      setState(() => _fullDataCache[asset.id] = data);
    }
  }

  /// 获取某页应显示的图片数据：原图优先，其次缩略图，最后 null
  Uint8List? _getDisplayData(String assetId) {
    return _fullDataCache[assetId] ?? _thumbDataCache[assetId];
  }

  PhotoViewScaleStateController _getScaleController(int index) {
    return _scaleControllers.putIfAbsent(index, () => PhotoViewScaleStateController());
  }

  Future<void> _shareAsset() async {
    try {
      final asset = widget.allAssets.isEmpty ? widget.asset : widget.allAssets[_currentIndex];
      final file = await asset.originFile;
      if (file == null) return;
      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'Shot with DAZZ${_cameraName.isNotEmpty ? " · $_cameraName" : ""}',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('分享失败'), backgroundColor: Color(0xFF2C2C2E)),
      );
    }
  }

  Future<void> _saveToGallery() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('照片已保存在相册中'),
        backgroundColor: Color(0xFF2C2C2E),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _deleteAsset() async {
    final asset = widget.allAssets[_currentIndex];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: const Text('删除照片', style: TextStyle(color: Colors.white)),
        content: const Text('确定要删除这张照片吗？', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await PhotoManager.editor.deleteWithIds([asset.id]);
      _ThumbCache.remove(asset.id);
      _GalleryCache.invalidate();
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        // 滑动返回：向下拖动超过 120px 时返回
        onVerticalDragStart: _isZoomed ? null : (details) {
          setState(() {
            _isDragging = true;
            _dragOffset = 0.0;
          });
        },
        onVerticalDragUpdate: _isZoomed ? null : (details) {
          if (details.delta.dy > 0 || _dragOffset > 0) {
            setState(() => _dragOffset += details.delta.dy);
          }
        },
        onVerticalDragEnd: _isZoomed ? null : (details) {
          if (_dragOffset > 120 || details.primaryVelocity! > 800) {
            Navigator.of(context).pop();
          } else {
            setState(() {
              _isDragging = false;
              _dragOffset = 0.0;
            });
          }
        },
        onVerticalDragCancel: _isZoomed ? null : () {
          setState(() {
            _isDragging = false;
            _dragOffset = 0.0;
          });
        },
        child: AnimatedContainer(
          duration: _isDragging ? Duration.zero : const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          transform: Matrix4.translationValues(0, _dragOffset.clamp(0.0, double.infinity), 0),
          child: Stack(
            children: [
              // ── 照片内容（可左右滑动）──
              PageView.builder(
                controller: _pageController,
                itemCount: widget.allAssets.isEmpty ? 1 : widget.allAssets.length,
                // 缩放时禁用 PageView 的水平滑动（避免与 PhotoView 的手势冲突）
                physics: _isZoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
                onPageChanged: (i) {
                  setState(() {
                    _currentIndex = i;
                    _isZoomed = false;
                  });
                  _parseCameraName(widget.allAssets[i]);
                  _preloadPages(i);
                },
                itemBuilder: (ctx, i) {
                  final pageAsset = widget.allAssets.isEmpty ? widget.asset : widget.allAssets[i];
                  final data = _getDisplayData(pageAsset.id);
                  final scaleController = _getScaleController(i);

                  return _PhotoViewPage(
                    asset: pageAsset,
                    data: data,
                    scaleController: scaleController,
                    onScaleChanged: (isZoomed) {
                      if (i == _currentIndex) {
                        setState(() => _isZoomed = isZoomed);
                      }
                    },
                  );
                },
              ),

              // ── 顶部状态栏区域（纯黑）──
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: mq.padding.top,
                child: Container(color: Colors.black),
              ),

              // ── 底部操作栏 ──
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black,
                  padding: EdgeInsets.only(
                    bottom: mq.padding.bottom + 16,
                    top: 16,
                    left: 24,
                    right: 24,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      if (_cameraName.isNotEmpty)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.camera_alt_outlined, color: Colors.white54, size: 14),
                            const SizedBox(width: 5),
                            Text(
                              _cameraName,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ],
                        )
                      else
                        const SizedBox(),
                      Row(
                        children: [
                          _ActionBtn(icon: Icons.ios_share_outlined, onTap: _shareAsset),
                          const SizedBox(width: 12),
                          _ActionBtn(icon: Icons.download_outlined, onTap: _saveToGallery),
                          const SizedBox(width: 12),
                          _ActionBtn(icon: Icons.delete_outline, onTap: _deleteAsset),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 单页照片视图（PhotoView 手势缩放 + 缩略图占位）
// ─────────────────────────────────────────────────────────────────────────────
class _PhotoViewPage extends StatelessWidget {
  final AssetEntity asset;
  final Uint8List? data;
  final PhotoViewScaleStateController scaleController;
  final void Function(bool isZoomed) onScaleChanged;

  const _PhotoViewPage({
    required this.asset,
    required this.data,
    required this.scaleController,
    required this.onScaleChanged,
  });

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);

    if (data == null) {
      // 数据未加载：显示占位
      return Container(
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        ),
      );
    }

    return Container(
      color: Colors.black,
      child: Column(
        children: [
          SizedBox(height: mq.padding.top),
          Expanded(
            child: PhotoView(
              imageProvider: MemoryImage(data!),
              scaleStateController: scaleController,
              minScale: PhotoViewComputedScale.contained,
              maxScale: PhotoViewComputedScale.covered * 4.0,
              initialScale: PhotoViewComputedScale.contained,
              backgroundDecoration: const BoxDecoration(color: Colors.black),
              // 缩放状态变化回调
              scaleStateChangedCallback: (state) {
                final isZoomed = state != PhotoViewScaleState.initial &&
                    state != PhotoViewScaleState.zoomedOut;
                onScaleChanged(isZoomed);
              },
              // 双击恢复原始大小
              enableRotation: false,
              tightMode: false,
              filterQuality: FilterQuality.medium,
              // 加载时用模糊缩略图占位（gaplessPlayback）
              loadingBuilder: (ctx, event) => Container(color: Colors.black),
            ),
          ),
          const SizedBox(height: 90), // 底部操作栏占位
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 底部操作按钮
// ─────────────────────────────────────────────────────────────────────────────
class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _ActionBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: const Color(0xFF2C2C2E),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: Colors.white, size: 24),
      ),
    );
  }
}
