// ignore_for_file: use_build_context_synchronously
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:dismissible_page/dismissible_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/camera_registry.dart';
import '../../core/l10n.dart';
import '../image_edit/image_edit_screen.dart';
import '../../services/original_asset_service.dart';

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
}

// ─────────────────────────────────────────────────────────────────────────────
// 缩略图并发加载队列（限流 + 去重，避免滚动时瞬间并发导致抖动）
// ─────────────────────────────────────────────────────────────────────────────
class _ThumbLoadQueue {
  static const int _maxConcurrent = 4;
  static int _running = 0;
  static final List<Future<void> Function()> _pending = [];
  static final Set<String> _inflight = <String>{};

  static Future<Uint8List?> load(
    AssetEntity asset, {
    required ThumbnailSize size,
  }) async {
    final id = asset.id;
    final cached = _ThumbCache.get(id);
    if (cached != null) return cached;

    if (_inflight.contains(id)) {
      while (_inflight.contains(id)) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      return _ThumbCache.get(id);
    }

    final completer = Completer<Uint8List?>();
    _inflight.add(id);

    Future<void> task() async {
      try {
        final data = await asset.thumbnailDataWithSize(size);
        if (data != null) {
          _ThumbCache.set(id, data);
        }
        completer.complete(data);
      } catch (_) {
        completer.complete(null);
      } finally {
        _inflight.remove(id);
        _running--;
        _drain();
      }
    }

    _pending.add(task);
    _drain();
    return completer.future;
  }

  static void _drain() {
    while (_running < _maxConcurrent && _pending.isNotEmpty) {
      final task = _pending.removeAt(0);
      _running++;
      task();
    }
  }
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

class _LivePhotoSupport {
  static const List<int> _motionPhotoMarker = <int>[
    0x43,
    0x61,
    0x6D,
    0x65,
    0x72,
    0x61,
    0x3A,
    0x4D,
    0x6F,
    0x74,
    0x69,
    0x6F,
    0x6E,
    0x50,
    0x68,
    0x6F,
    0x74,
    0x6F,
    0x3D,
    0x22,
    0x31,
    0x22,
  ];
  static const List<int> _ftypMarker = <int>[0x66, 0x74, 0x79, 0x70];
  static final RegExp _microVideoOffsetPattern = RegExp(
    r'Camera:MicroVideoOffset="(\d+)"',
  );
  static final RegExp _containerItemLengthPattern = RegExp(
    r'Item:Semantic="MotionPhoto"[\s\S]*?Item:Length="(\d+)"',
  );

  static final Map<String, bool> _liveAssetCache = <String, bool>{};
  static final Map<String, Future<bool>> _liveAssetInflight =
      <String, Future<bool>>{};
  static final Map<String, String> _playbackPathCache = <String, String>{};
  static final Map<String, Future<String?>> _playbackInflight =
      <String, Future<String?>>{};

  static bool getCachedLiveFlag(String id) => _liveAssetCache[id] ?? false;

  static Future<bool> isLiveAsset(AssetEntity asset) {
    final cached = _liveAssetCache[asset.id];
    if (cached != null) return Future<bool>.value(cached);
    final inflight = _liveAssetInflight[asset.id];
    if (inflight != null) return inflight;
    final future = _resolveIsLiveAsset(asset);
    _liveAssetInflight[asset.id] = future;
    future.whenComplete(() => _liveAssetInflight.remove(asset.id));
    return future;
  }

  static Future<bool> _resolveIsLiveAsset(AssetEntity asset) async {
    if (asset.type != AssetType.image) {
      _liveAssetCache[asset.id] = false;
      return false;
    }
    if (Platform.isIOS || Platform.isMacOS) {
      final isLive = asset.isLivePhoto;
      _liveAssetCache[asset.id] = isLive;
      return isLive;
    }
    if (!Platform.isAndroid) {
      _liveAssetCache[asset.id] = false;
      return false;
    }

    try {
      final file = await asset.originFile;
      if (file == null || !await file.exists()) {
        _liveAssetCache[asset.id] = false;
        return false;
      }
      final raf = await file.open();
      try {
        final probeLength = math.min((await raf.length()).toInt(), 256 * 1024);
        final head = await raf.read(probeLength);
        final isLive = _indexOfBytes(head, _motionPhotoMarker) >= 0;
        _liveAssetCache[asset.id] = isLive;
        return isLive;
      } finally {
        await raf.close();
      }
    } catch (_) {
      _liveAssetCache[asset.id] = false;
      return false;
    }
  }

  static Future<String?> resolvePlaybackPath(AssetEntity asset) {
    final inflight = _playbackInflight[asset.id];
    if (inflight != null) return inflight;
    final future = _resolvePlaybackPath(asset);
    _playbackInflight[asset.id] = future;
    future.whenComplete(() => _playbackInflight.remove(asset.id));
    return future;
  }

  static Future<String?> _resolvePlaybackPath(AssetEntity asset) async {
    if (!await isLiveAsset(asset)) return null;

    final cached = _playbackPathCache[asset.id];
    if (cached != null && await File(cached).exists()) {
      return cached;
    }

    if (Platform.isIOS || Platform.isMacOS) {
      if (!await asset.isLocallyAvailable(withSubtype: true)) {
        await asset.originFileWithSubtype;
      }
      final mediaUrl = await asset.getMediaUrl();
      if (mediaUrl == null || mediaUrl.isEmpty) return null;
      final uri = Uri.parse(mediaUrl);
      if (uri.scheme == 'file') {
        return uri.toFilePath();
      }
      return null;
    }

    if (!Platform.isAndroid) return null;

    final imageFile = await asset.originFile;
    if (imageFile == null || !await imageFile.exists()) return null;
    final raf = await imageFile.open();
    try {
      final length = await raf.length();
      final headProbeLength = math.min(length, 512 * 1024);
      final head = await raf.read(headProbeLength);
      final xmpOffset = _extractMotionVideoOffset(head);

      int? start;
      if (xmpOffset != null && xmpOffset > 0 && xmpOffset < length) {
        final candidate = length - xmpOffset;
        if (await _isValidMp4Start(raf, candidate, length)) {
          start = candidate;
        }
      }

      if (start == null) {
        final probeStart = math.max(0, length - 1024 * 1024);
        await raf.setPosition(probeStart);
        final tail = await raf.read(length - probeStart);
        final startInTail = _lastIndexOfBytes(tail, _ftypMarker);
        if (startInTail >= 4) {
          final candidate = probeStart + startInTail - 4;
          if (candidate >= 0 &&
              candidate < length &&
              await _isValidMp4Start(raf, candidate, length)) {
            start = candidate;
          }
        }
      }

      if (start == null) return null;
      await raf.setPosition(start);
      final mp4Bytes = await raf.read(length - start);
      final tempFile = File(
        '${Directory.systemTemp.path}/dazz_live_${asset.id}_${imageFile.lastModifiedSync().millisecondsSinceEpoch}.mp4',
      );
      await tempFile.writeAsBytes(mp4Bytes, flush: true);
      _playbackPathCache[asset.id] = tempFile.path;
      return tempFile.path;
    } finally {
      await raf.close();
    }
  }

  static int _indexOfBytes(List<int> source, List<int> pattern) {
    if (pattern.isEmpty || source.length < pattern.length) return -1;
    for (int i = 0; i <= source.length - pattern.length; i++) {
      bool matched = true;
      for (int j = 0; j < pattern.length; j++) {
        if (source[i + j] != pattern[j]) {
          matched = false;
          break;
        }
      }
      if (matched) return i;
    }
    return -1;
  }

  static int _lastIndexOfBytes(List<int> source, List<int> pattern) {
    if (pattern.isEmpty || source.length < pattern.length) return -1;
    for (int i = source.length - pattern.length; i >= 0; i--) {
      bool matched = true;
      for (int j = 0; j < pattern.length; j++) {
        if (source[i + j] != pattern[j]) {
          matched = false;
          break;
        }
      }
      if (matched) return i;
    }
    return -1;
  }

  static int? _extractMotionVideoOffset(List<int> head) {
    if (head.isEmpty) return null;
    final text = String.fromCharCodes(head);
    final microVideoMatch = _microVideoOffsetPattern.firstMatch(text);
    final microVideoOffset = int.tryParse(microVideoMatch?.group(1) ?? '');
    if (microVideoOffset != null && microVideoOffset > 0) {
      return microVideoOffset;
    }
    final containerMatch = _containerItemLengthPattern.firstMatch(text);
    final containerOffset = int.tryParse(containerMatch?.group(1) ?? '');
    if (containerOffset != null && containerOffset > 0) {
      return containerOffset;
    }
    return null;
  }

  static Future<bool> _isValidMp4Start(
    RandomAccessFile raf,
    int start,
    int fileLength,
  ) async {
    if (start < 0 || start + 8 > fileLength) return false;
    await raf.setPosition(start);
    final header = await raf.read(12);
    if (header.length < 8) return false;
    return header[4] == 0x66 &&
        header[5] == 0x74 &&
        header[6] == 0x79 &&
        header[7] == 0x70;
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
  const _AlbumEntry(
      {required this.id, required this.name, this.icon, this.iconPath});
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
  bool _isFetchingAssets = false;
  int _fetchGeneration = 0;
  bool _isSelectionMode = false;
  bool _isDeletingSelection = false;
  final ValueNotifier<Set<String>> _selectedIdsNotifier =
      ValueNotifier<Set<String>>(<String>{});
  bool _showAlbumDropdown = false;
  String _currentAlbumId = 'all';
  String _currentAlbumName = '';
  Map<String, int> _albumCounts = {};
  List<_AlbumEntry> _cameraAlbumEntries = [];

  String _normalizeCameraMatchText(String raw) {
    return raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  String? _cameraIdForAsset(AssetEntity asset) {
    final rawTitle = (asset.title ?? '').trim();
    if (rawTitle.isEmpty) return null;
    final normalizedTitle = _normalizeCameraMatchText(rawTitle);
    for (final cam in kAllCameras) {
      final normalizedId = _normalizeCameraMatchText(cam.id);
      final normalizedName = _normalizeCameraMatchText(cam.name);
      if (normalizedId.isNotEmpty && normalizedTitle.contains(normalizedId)) {
        return cam.id;
      }
      if (normalizedName.isNotEmpty &&
          normalizedTitle.contains(normalizedName)) {
        return cam.id;
      }
    }
    return null;
  }

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
    _selectedIdsNotifier.dispose();
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
    if (_isFetchingAssets) return;
    _isFetchingAssets = true;
    final fetchGeneration = ++_fetchGeneration;

    void finishFetch() {
      if (_fetchGeneration == fetchGeneration) {
        _isFetchingAssets = false;
      }
    }

    try {
      // 有缓存时立即显示，无需 loading
      if (_GalleryCache.isValid && _GalleryCache.assets != null) {
        final cached = _GalleryCache.assets!;
        _rebuildFromAssets(cached, showLoading: false);
        return;
      }

      if (mounted) {
        setState(() => _isLoading = true);
      }

      final ps = await PhotoManager.requestPermissionExtend();
      if (!ps.hasAccess) {
        if (mounted) {
          setState(() => _isLoading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_s().galleryPermissionHint),
              backgroundColor: const Color(0xFF3A3A3C),
            ),
          );
        }
        return;
      }

      final allPaths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        hasAll: true,
        onlyAll: false,
        filterOption: FilterOptionGroup(
          orders: [
            const OrderOption(type: OrderOptionType.createDate, asc: false)
          ],
        ),
      );

      if (allPaths.isEmpty) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      AssetPathEntity? dazzPath;
      for (final p in allPaths) {
        final upper = p.name.toUpperCase();
        if (upper == 'DAZZ' ||
            upper.endsWith('/DAZZ') ||
            upper.contains('DAZZ')) {
          dazzPath = p;
          break;
        }
      }

      List<AssetEntity> assets;
      if (dazzPath == null) {
        final rootPath =
            allPaths.firstWhere((p) => p.isAll, orElse: () => allPaths.first);
        final rootCount = await rootPath.assetCountAsync;
        final rootAssets = await rootPath.getAssetListRange(
            start: 0, end: rootCount.clamp(0, 5000));
        assets = rootAssets.where((a) {
          final title = (a.title ?? '').toLowerCase();
          return title.startsWith('dazz_') || title.contains('dazz');
        }).toList();
      } else {
        final count = await dazzPath.assetCountAsync;
        assets = await dazzPath.getAssetListRange(
          start: 0,
          end: count.clamp(0, 5000),
        );
      }

      if (!mounted || _fetchGeneration != fetchGeneration) return;

      _GalleryCache.set(assets);
      _rebuildFromAssets(assets, showLoading: false);
      unawaited(_prefetchThumbs(assets.take(30).toList()));
    } catch (e, st) {
      debugPrint('[GalleryScreen] _fetchAssets failed: $e\n$st');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _allDazzAssets = const [];
          _assets = const [];
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_s().galleryPermissionHint),
            backgroundColor: const Color(0xFF3A3A3C),
          ),
        );
      }
    } finally {
      finishFetch();
    }
  }

  /// 后台并行预生成缩略图（不阻塞 UI，最多 8 并发）
  Future<void> _prefetchThumbs(List<AssetEntity> assets) async {
    try {
      // 分批并行，每批 8 张，避免一次性占用过多线程
      const batchSize = 8;
      final toLoad =
          assets.where((a) => _ThumbCache.get(a.id) == null).toList();
      for (int i = 0; i < toLoad.length; i += batchSize) {
        final batch = toLoad.skip(i).take(batchSize).toList();
        await Future.wait(batch.map((asset) async {
          await _ThumbLoadQueue.load(
            asset,
            size: const ThumbnailSize(300, 300),
          );
        }));
      }
    } catch (e) {
      debugPrint('[GalleryScreen] _prefetchThumbs failed: $e');
    }
  }

  void _rebuildFromAssets(List<AssetEntity> assets,
      {required bool showLoading}) {
    final counts = <String, int>{'all': assets.length};
    final cameraIdsFound = <String>{};
    for (final asset in assets) {
      final cameraId = _cameraIdForAsset(asset);
      if (cameraId != null) {
        cameraIdsFound.add(cameraId);
        counts[cameraId] = (counts[cameraId] ?? 0) + 1;
      }
    }
    final s = sOf(ProviderScope.containerOf(context).read(languageProvider));
    final entries = <_AlbumEntry>[
      _AlbumEntry(
          id: 'all', name: s.allPhotos, icon: Icons.photo_library_outlined),
    ];
    for (final cam in kAllCameras) {
      if (cameraIdsFound.contains(cam.id)) {
        entries.add(_AlbumEntry(
            id: cam.id,
            name: cam.name,
            icon: Icons.camera_alt_outlined,
            iconPath: cam.iconPath));
      }
    }
    if (mounted) {
      setState(() {
        _allDazzAssets = assets;
        _assets = assets;
        _albumCounts = counts;
        _cameraAlbumEntries = entries;
        _isLoading = showLoading;
        if (_currentAlbumName.isEmpty) _currentAlbumName = entries.first.name;
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
              orElse: () => _AlbumEntry(id: 'all', name: _s().allPhotos))
          .name;
      _showAlbumDropdown = false;
      _assets = cameraId == 'all'
          ? _allDazzAssets
          : _allDazzAssets
              .where((asset) => _cameraIdForAsset(asset) == cameraId)
              .toList();
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
    final next = Set<String>.from(_selectedIdsNotifier.value);
    if (next.contains(id)) {
      next.remove(id);
    } else {
      next.add(id);
    }
    _selectedIdsNotifier.value = next;
  }

  Future<void> _deleteSelected() async {
    final selected = _selectedIdsNotifier.value;
    if (selected.isEmpty || _isDeletingSelection) return;
    final toDelete = List<String>.from(selected);
    setState(() => _isDeletingSelection = true);
    try {
      // 大批量删除分段执行，避免一次性传超大列表导致 UI 卡顿。
      const batchSize = 200;
      for (int i = 0; i < toDelete.length; i += batchSize) {
        final end =
            (i + batchSize < toDelete.length) ? i + batchSize : toDelete.length;
        await PhotoManager.editor.deleteWithIds(toDelete.sublist(i, end));
      }
      await OriginalAssetService.instance.removeOriginals(toDelete);
      for (final id in toDelete) {
        _ThumbCache.remove(id);
      }
      _GalleryCache.invalidate();
      if (!mounted) return;
      setState(() {
        final deleted = toDelete.toSet();
        _assets.removeWhere((a) => deleted.contains(a.id));
        _allDazzAssets.removeWhere((a) => deleted.contains(a.id));
        _selectedIdsNotifier.value = <String>{};
        _isSelectionMode = false;
      });
    } finally {
      if (mounted) {
        setState(() => _isDeletingSelection = false);
      }
    }
  }

  bool get _isAllSelected =>
      _assets.isNotEmpty && _selectedIdsNotifier.value.length == _assets.length;

  void _toggleSelectAll() {
    if (_isDeletingSelection) return;
    if (_isAllSelected) {
      _selectedIdsNotifier.value = <String>{};
    } else {
      _selectedIdsNotifier.value = _assets.map((a) => a.id).toSet();
    }
  }

  S _s() => sOf(ProviderScope.containerOf(context).read(languageProvider));

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
                    ? const Center(
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
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
                child: const Icon(Icons.photo_camera_outlined,
                    color: Colors.white, size: 28),
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
              icon: const Icon(Icons.arrow_back_ios,
                  color: Colors.white, size: 20),
              onPressed: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: GestureDetector(
                onTap: _cameraAlbumEntries.length > 1
                    ? () =>
                        setState(() => _showAlbumDropdown = !_showAlbumDropdown)
                    : null,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    Flexible(
                      child: Text(
                        _currentAlbumName,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_cameraAlbumEntries.length > 1) ...[
                      const SizedBox(width: 4),
                      Icon(
                        _showAlbumDropdown
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
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
                      ValueListenableBuilder<Set<String>>(
                        valueListenable: _selectedIdsNotifier,
                        builder: (_, selected, __) {
                          return Text(
                            '${selected.length}/${_assets.length}',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 13),
                          );
                        },
                      ),
                      IconButton(
                        icon: Icon(
                          _isAllSelected
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          color: Colors.white,
                        ),
                        onPressed: _toggleSelectAll,
                      ),
                      ValueListenableBuilder<Set<String>>(
                        valueListenable: _selectedIdsNotifier,
                        builder: (_, selected, __) {
                          if (selected.isEmpty) return const SizedBox.shrink();
                          return IconButton(
                            icon: _isDeletingSelection
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white),
                                  )
                                : const Icon(Icons.delete_outline,
                                    color: Colors.white),
                            onPressed:
                                _isDeletingSelection ? null : _deleteSelected,
                          );
                        },
                      ),
                      TextButton(
                        onPressed: _isDeletingSelection
                            ? null
                            : () => setState(() {
                                  _isSelectionMode = false;
                                  _selectedIdsNotifier.value = <String>{};
                                }),
                        child: Text(_s().cancel,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 15)),
                      ),
                    ],
                  )
                : TextButton(
                    onPressed: () => setState(() => _isSelectionMode = true),
                    child: Text(_s().select,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 15)),
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
              child: const Icon(Icons.camera_alt_outlined,
                  color: Color(0xFFFF8C00), size: 40),
            ),
            const SizedBox(height: 16),
            Text(_s().noPhotos,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(_s().noPhotosHint,
                style: const TextStyle(color: Colors.grey, fontSize: 14)),
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
      cacheExtent: 1600,
      // 关键优化：addRepaintBoundaries=true 让每个 cell 独立重绘，避免全局重绘
      addRepaintBoundaries: true,
      itemBuilder: (ctx, index) {
        if (index == 0) {
          return GestureDetector(
            onTap: () => openImageImportFlow(context),
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
                    child: const Icon(Icons.add_photo_alternate_outlined,
                        color: Color(0xFFFF8C00), size: 28),
                  ),
                  const SizedBox(height: 8),
                  Text(_s().importPhoto,
                      style: const TextStyle(
                          color: Color(0xFFFF8C00), fontSize: 12)),
                ],
              ),
            ),
          );
        }

        final asset = _assets[index - 1];
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
              });
              _toggleSelection(asset.id);
            }
          },
          child: _RetroPhotoCell(
            asset: asset,
            selectedListenable: _selectedIdsNotifier,
            isSelectionMode: _isSelectionMode,
          ),
        );
      },
    );
  }

  Widget _buildAlbumDropdown() {
    final mq = MediaQuery.of(context);
    return Positioned.fill(
      child: GestureDetector(
        onTap: () => setState(() => _showAlbumDropdown = false),
        child: Stack(
          children: [
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Container(
                  color: Colors.black.withValues(alpha: 0.45),
                ),
              ),
            ),
            SafeArea(
              bottom: false,
              child: Align(
                alignment: Alignment.topCenter,
                child: GestureDetector(
                  onTap: () {},
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    height: mq.size.height * 0.78,
                    decoration: BoxDecoration(
                      color: const Color(0xCC111111),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        Container(
                          height: 54,
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          alignment: Alignment.centerLeft,
                          child: Text(
                            _s().allPhotos,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Divider(
                          height: 1,
                          thickness: 0.5,
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                        Expanded(
                          child: ListView.separated(
                            physics: const BouncingScrollPhysics(),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            itemCount: _cameraAlbumEntries.length,
                            separatorBuilder: (_, __) => Divider(
                              height: 1,
                              thickness: 0.5,
                              color: Colors.white.withValues(alpha: 0.06),
                              indent: 96,
                              endIndent: 16,
                            ),
                            itemBuilder: (_, i) =>
                                _buildDropdownItem(_cameraAlbumEntries[i]),
                          ),
                        ),
                      ],
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
                        color:
                            isActive ? const Color(0xFFFF8C00) : Colors.white54,
                        size: 32,
                      ),
                    )
                  : Icon(
                      entry.icon ?? Icons.photo_library_outlined,
                      color:
                          isActive ? const Color(0xFFFF8C00) : Colors.white54,
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
  final ValueNotifier<Set<String>> selectedListenable;
  final bool isSelectionMode;

  const _RetroPhotoCell({
    required this.asset,
    required this.selectedListenable,
    required this.isSelectionMode,
  });

  @override
  State<_RetroPhotoCell> createState() => _RetroPhotoCellState();
}

class _RetroPhotoCellState extends State<_RetroPhotoCell> {
  Uint8List? _thumb;
  bool _isLivePhoto = false;

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
    _loadLiveFlag();
  }

  Future<void> _loadThumb() async {
    final data = await _ThumbLoadQueue.load(
      widget.asset,
      size: const ThumbnailSize(300, 300),
    );
    if (data != null) {
      if (mounted) setState(() => _thumb = data);
    }
  }

  Future<void> _loadLiveFlag() async {
    final cached = _LivePhotoSupport.getCachedLiveFlag(widget.asset.id);
    if (cached) {
      _isLivePhoto = true;
      return;
    }
    final isLive = await _LivePhotoSupport.isLiveAsset(widget.asset);
    if (!mounted || isLive == _isLivePhoto) return;
    setState(() => _isLivePhoto = isLive);
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
        if (_isLivePhoto)
          Positioned(
            top: 6,
            left: 6,
            child: _LiveBadge(compact: true),
          ),
        if (widget.isSelectionMode)
          ValueListenableBuilder<Set<String>>(
            valueListenable: widget.selectedListenable,
            builder: (_, selected, __) {
              final isSelected = selected.contains(widget.asset.id);
              return Positioned(
                top: 4,
                right: 4,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                        isSelected ? Colors.blue : Colors.black.withAlpha(100),
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: isSelected
                      ? const Icon(Icons.check, color: Colors.white, size: 14)
                      : null,
                ),
              );
            },
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
  bool _currentAssetIsLivePhoto = false;
  bool _isPreparingLiveVideo = false;
  bool _isPlayingLiveVideo = false;
  bool _isHoldingLivePlayback = false;
  bool _hasEditableOriginal = false;
  String? _editableOriginalPath;
  Timer? _livePressTimer;
  Offset? _livePressDownPosition;
  VideoPlayerController? _videoCtrl;
  final Map<String, ImageProvider<Object>> _detailImageProviderCache =
      <String, ImageProvider<Object>>{};

  S _s() => sOf(ProviderScope.containerOf(context).read(languageProvider));

  bool _isZoomed = false; // 当前页是否已缩放（缩放时禁用滑动返回）

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.allAssets.indexOf(widget.asset);
    if (_currentIndex < 0) _currentIndex = 0;
    _pageController = PageController(initialPage: _currentIndex);
    _parseCameraName(widget.asset);
    _syncCurrentAssetLiveFlag();
    unawaited(_syncEditableOriginalFlag());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_precacheAround(_currentIndex));
    });
  }

  AssetEntity get _safeCurrentAsset {
    if (widget.allAssets.isEmpty) return widget.asset;
    final safeIndex = _currentIndex.clamp(0, widget.allAssets.length - 1);
    return widget.allAssets[safeIndex];
  }

  @override
  void dispose() {
    _livePressTimer?.cancel();
    _disposeVideoController();
    _pageController.dispose();
    _detailImageProviderCache.clear();
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

  String? _cameraIdForAsset(AssetEntity asset) {
    final title = (asset.title ?? '').toLowerCase();
    for (final cam in kAllCameras) {
      if (title.contains(cam.id.toLowerCase())) {
        return cam.id;
      }
    }
    return null;
  }

  Future<void> _syncCurrentAssetLiveFlag() async {
    final asset = _safeCurrentAsset;
    final isLive = await _LivePhotoSupport.isLiveAsset(asset);
    if (!mounted || asset.id != _currentDisplayedAsset.id) return;
    if (isLive != _currentAssetIsLivePhoto) {
      setState(() => _currentAssetIsLivePhoto = isLive);
    }
  }

  Future<void> _syncEditableOriginalFlag() async {
    final asset = _safeCurrentAsset;
    final path = await OriginalAssetService.instance.getOriginalPath(asset.id);
    if (!mounted || asset.id != _currentDisplayedAsset.id) return;
    setState(() {
      _editableOriginalPath = path;
      _hasEditableOriginal = path != null;
    });
  }

  AssetEntity get _currentDisplayedAsset => _safeCurrentAsset;

  ImageProvider<Object> _imageProviderFor(AssetEntity asset) {
    return _detailImageProviderCache.putIfAbsent(
      asset.id,
      () => AssetEntityImageProvider(
        asset,
        isOriginal: false,
        thumbnailSize: const ThumbnailSize(2048, 2048),
      ),
    );
  }

  Future<void> _precacheAround(int index) async {
    final assets = widget.allAssets.isEmpty
        ? <AssetEntity>[widget.asset]
        : widget.allAssets;
    final indices = <int>[index - 1, index, index + 1]
        .where((i) => i >= 0 && i < assets.length)
        .toList();
    for (final i in indices) {
      final provider = _imageProviderFor(assets[i]);
      try {
        await precacheImage(provider, context);
      } catch (e) {
        debugPrint(
            '[PhotoDetailPage] _precacheAround failed: ${assets[i].id}, $e');
      }
    }
  }

  Future<void> _shareAsset() async {
    try {
      final asset = widget.allAssets.isEmpty ? widget.asset : _safeCurrentAsset;
      final file = await asset.originFile;
      if (file == null) return;
      await Share.shareXFiles(
        [XFile(file.path)],
        text:
            'Shot with DAZZ${_cameraName.isNotEmpty ? " · $_cameraName" : ""}',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(_s().shareFailed),
            backgroundColor: const Color(0xFF2C2C2E)),
      );
    }
  }

  Future<void> _saveToGallery() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_s().photoSaved),
        backgroundColor: const Color(0xFF2C2C2E),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _deleteAsset() async {
    final asset = _safeCurrentAsset;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title:
            Text(_s().deletePhoto, style: const TextStyle(color: Colors.white)),
        content: Text(_s().deletePhotoConfirm,
            style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(_s().cancel,
                style: const TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(_s().delete, style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await OriginalAssetService.instance.removeOriginal(asset.id);
      await PhotoManager.editor.deleteWithIds([asset.id]);
      _ThumbCache.remove(asset.id);
      _GalleryCache.invalidate();
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _openEditScreen() async {
    final asset = _safeCurrentAsset;
    final originalPath = _editableOriginalPath ??
        await OriginalAssetService.instance.getOriginalPath(asset.id);
    if (!mounted) return;
    if (originalPath == null || originalPath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_s().saveOriginalOff),
          backgroundColor: const Color(0xFF2C2C2E),
        ),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => UncontrolledProviderScope(
          container: ProviderScope.containerOf(context),
          child: ImageEditScreen(
            imagePath: originalPath,
            initialCameraId: _cameraIdForAsset(asset),
          ),
        ),
      ),
    );
  }

  Future<bool> _ensureLiveVideoReady(AssetEntity asset) async {
    if (_videoCtrl == null) {
      if (mounted) {
        setState(() => _isPreparingLiveVideo = true);
      }
      final path = await _LivePhotoSupport.resolvePlaybackPath(asset);
      if (!mounted || asset.id != _safeCurrentAsset.id) {
        if (mounted && _isPreparingLiveVideo) {
          setState(() => _isPreparingLiveVideo = false);
        }
        return false;
      }
      if (path == null || path.isEmpty) {
        setState(() => _isPreparingLiveVideo = false);
        return false;
      }
      try {
        final controller = VideoPlayerController.file(File(path));
        await controller.initialize();
        await controller.setLooping(false);
        controller.addListener(_handleVideoState);
        if (!mounted) {
          await controller.dispose();
          return false;
        }
        setState(() {
          _videoCtrl = controller;
          _isPreparingLiveVideo = false;
        });
      } catch (_) {
        if (mounted) {
          setState(() => _isPreparingLiveVideo = false);
        }
        return false;
      }
    }
    return _videoCtrl != null;
  }

  Future<void> _startLivePlaybackHold() async {
    if (!_currentAssetIsLivePhoto) return;
    _isHoldingLivePlayback = true;
    final asset = _safeCurrentAsset;
    final ready = await _ensureLiveVideoReady(asset);
    if (!ready) return;
    if (!_isHoldingLivePlayback) return;
    HapticFeedback.selectionClick();
    await _videoCtrl?.seekTo(Duration.zero);
    await _videoCtrl?.play();
    if (!mounted) return;
    setState(() => _isPlayingLiveVideo = true);
  }

  Future<void> _playLiveOnce() async {
    if (!_currentAssetIsLivePhoto) return;
    _isHoldingLivePlayback = false;
    final asset = _safeCurrentAsset;
    final ready = await _ensureLiveVideoReady(asset);
    if (!ready) return;
    HapticFeedback.selectionClick();
    await _videoCtrl?.seekTo(Duration.zero);
    await _videoCtrl?.play();
    if (!mounted) return;
    setState(() => _isPlayingLiveVideo = true);
  }

  Future<void> _stopLivePlaybackHold() async {
    _isHoldingLivePlayback = false;
    _livePressTimer?.cancel();
    await _stopPlayback();
  }

  Future<void> _stopPlayback() async {
    await _videoCtrl?.pause();
    await _videoCtrl?.seekTo(Duration.zero);
    if (!mounted) return;
    if (_isPlayingLiveVideo) {
      setState(() => _isPlayingLiveVideo = false);
    }
  }

  void _handleVideoState() {
    if (!mounted) return;
    final controller = _videoCtrl;
    if (controller == null) return;
    final value = controller.value;
    if (!value.isInitialized) return;
    final ended = !value.isPlaying &&
        value.duration > Duration.zero &&
        value.position >= value.duration - const Duration(milliseconds: 60);
    if (ended && _isPlayingLiveVideo && mounted) {
      setState(() => _isPlayingLiveVideo = false);
    }
  }

  void _disposeVideoController() {
    _livePressTimer?.cancel();
    _videoCtrl?.removeListener(_handleVideoState);
    _videoCtrl?.dispose();
    _videoCtrl = null;
    _isHoldingLivePlayback = false;
    _isPreparingLiveVideo = false;
    _isPlayingLiveVideo = false;
  }

  void _handleLivePointerDown(PointerDownEvent event) {
    if (!_currentAssetIsLivePhoto || _isZoomed || _isPreparingLiveVideo) return;
    _livePressDownPosition = event.position;
    _livePressTimer?.cancel();
    _livePressTimer = Timer(const Duration(milliseconds: 260), () {
      unawaited(_startLivePlaybackHold());
    });
  }

  void _handleLivePointerMove(PointerMoveEvent event) {
    final start = _livePressDownPosition;
    if (start == null) return;
    final dx = (event.position.dx - start.dx).abs();
    final dy = (event.position.dy - start.dy).abs();
    if (dx > 12 || dy > 12) {
      _livePressTimer?.cancel();
      _livePressDownPosition = null;
    }
  }

  void _handleLivePointerUp(PointerEvent event) {
    _livePressTimer?.cancel();
    _livePressDownPosition = null;
    if (_isHoldingLivePlayback ||
        _isPreparingLiveVideo ||
        _isPlayingLiveVideo) {
      unawaited(_stopLivePlaybackHold());
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final galleryAssets = widget.allAssets.isEmpty
        ? <AssetEntity>[widget.asset]
        : widget.allAssets;

    return Scaffold(
      backgroundColor: Colors.black,
      body: DismissiblePage(
        direction: DismissiblePageDismissDirection.down,
        isFullScreen: true,
        disabled: _isZoomed || _isPlayingLiveVideo,
        minRadius: 12,
        maxTransformValue: 0.15,
        dragSensitivity: 1.0,
        backgroundColor: Colors.black,
        onDismissed: () => Navigator.of(context).pop(),
        child: Stack(
          children: [
            Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _handleLivePointerDown,
              onPointerMove: _handleLivePointerMove,
              onPointerUp: _handleLivePointerUp,
              onPointerCancel: _handleLivePointerUp,
              child: PhotoViewGallery.builder(
                pageController: _pageController,
                itemCount: galleryAssets.length,
                backgroundDecoration: const BoxDecoration(color: Colors.black),
                scrollPhysics: _isZoomed
                    ? const NeverScrollableScrollPhysics()
                    : const BouncingScrollPhysics(),
                loadingBuilder: (_, __) => const Center(
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                ),
                scaleStateChangedCallback: (state) {
                  final zoomed = state == PhotoViewScaleState.zoomedIn ||
                      state == PhotoViewScaleState.covering ||
                      state == PhotoViewScaleState.originalSize;
                  if (zoomed != _isZoomed && mounted) {
                    setState(() => _isZoomed = zoomed);
                  }
                },
                onPageChanged: (i) {
                  setState(() {
                    _currentIndex = i;
                    _isZoomed = false;
                  });
                  _disposeVideoController();
                  _parseCameraName(galleryAssets[i]);
                  _syncCurrentAssetLiveFlag();
                  _syncEditableOriginalFlag();
                  unawaited(_precacheAround(i));
                },
                builder: (ctx, i) {
                  final pageAsset = galleryAssets[i];
                  return PhotoViewGalleryPageOptions(
                    imageProvider: _imageProviderFor(pageAsset),
                    minScale: PhotoViewComputedScale.contained,
                    initialScale: PhotoViewComputedScale.contained,
                    maxScale: PhotoViewComputedScale.contained * 5.0,
                    tightMode: true,
                    basePosition: Alignment.center,
                    filterQuality: FilterQuality.medium,
                    gestureDetectorBehavior: HitTestBehavior.opaque,
                    heroAttributes: PhotoViewHeroAttributes(tag: pageAsset.id),
                  );
                },
              ),
            ),
            if (_videoCtrl?.value.isInitialized == true)
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: !_isPlayingLiveVideo,
                  child: AnimatedOpacity(
                    opacity: _isPlayingLiveVideo ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: SizedBox(
                        width: _videoCtrl!.value.size.width,
                        height: _videoCtrl!.value.size.height,
                        child: VideoPlayer(_videoCtrl!),
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: mq.padding.top,
              child: Container(color: Colors.black),
            ),
            if (_currentAssetIsLivePhoto)
              Positioned(
                top: mq.padding.top + 14,
                left: 16,
                child: const _LiveBadge(),
              ),
            if (_currentAssetIsLivePhoto && !_isZoomed && !_isPlayingLiveVideo)
              Positioned(
                right: 20,
                bottom: mq.padding.bottom + 110,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _isPreparingLiveVideo
                      ? null
                      : () {
                          if (_isPlayingLiveVideo) {
                            unawaited(_stopPlayback());
                          } else {
                            unawaited(_playLiveOnce());
                          }
                        },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(160),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: Colors.white.withAlpha(35),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_isPreparingLiveVideo)
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        else
                          Icon(
                            _isPlayingLiveVideo
                                ? Icons.stop_rounded
                                : Icons.play_arrow_rounded,
                            color: const Color(0xFFFF9F0A),
                            size: 18,
                          ),
                        const SizedBox(width: 6),
                        Text(
                          _isPreparingLiveVideo
                              ? '加载中'
                              : (_isPlayingLiveVideo ? '停止实况' : '播放实况'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_isPlayingLiveVideo)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _stopPlayback,
                ),
              ),
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
                          const Icon(
                            Icons.camera_alt_outlined,
                            color: Colors.white54,
                            size: 14,
                          ),
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
                        if (_hasEditableOriginal) ...[
                          _ActionBtn(
                            icon: Icons.edit_outlined,
                            onTap: _openEditScreen,
                          ),
                          const SizedBox(width: 12),
                        ],
                        _ActionBtn(
                          icon: Icons.ios_share_outlined,
                          onTap: _shareAsset,
                        ),
                        const SizedBox(width: 12),
                        _ActionBtn(
                          icon: Icons.download_outlined,
                          onTap: _saveToGallery,
                        ),
                        const SizedBox(width: 12),
                        _ActionBtn(
                          icon: Icons.delete_outline,
                          onTap: _deleteAsset,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Live Photo 标识
// ─────────────────────────────────────────────────────────────────────────────
class _LiveBadge extends StatelessWidget {
  final bool compact;

  const _LiveBadge({this.compact = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 10,
        vertical: compact ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(150),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withAlpha(30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.motion_photos_on_outlined,
            color: const Color(0xFFFF9F0A),
            size: compact ? 12 : 15,
          ),
          SizedBox(width: compact ? 3 : 5),
          Text(
            'LIVE',
            style: TextStyle(
              color: Colors.white,
              fontSize: compact ? 10 : 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
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
