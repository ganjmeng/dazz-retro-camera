import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../models/camera_registry.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 相机分类数据（动态根据实际有成片的相机生成）
// ─────────────────────────────────────────────────────────────────────────────
class _AlbumEntry {
  final String id;
  final String name;
  final IconData? icon;
  const _AlbumEntry({required this.id, required this.name, this.icon});
}

// ─────────────────────────────────────────────────────────────────────────────
// GalleryScreen — 相册列表主页
// 截图 13084.jpg：3列网格，黄色边框相片卡片，左上角"导入图片"，顶部"全部照片 ▼"
// ─────────────────────────────────────────────────────────────────────────────
class GalleryScreen extends StatefulWidget {
  /// 如果传入 initialAsset，进入时直接打开该相片详情（长按触发）
  final AssetEntity? initialAsset;

  const GalleryScreen({super.key, this.initialAsset});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  List<AssetEntity> _allDazzAssets = []; // DAZZ 相册所有照片
  List<AssetEntity> _assets = [];        // 当前显示的照片（已按相机过滤）
  bool _isLoading = true;
  bool _isSelectionMode = false;
  Set<String> _selectedIds = {};
  bool _showAlbumDropdown = false;
  String _currentAlbumId = 'all';
  String _currentAlbumName = '全部照片';
  Map<String, int> _albumCounts = {};
  // 动态相机分类列表（只包含实际有成片的相机）
  List<_AlbumEntry> _cameraAlbumEntries = [
    const _AlbumEntry(id: 'all', name: '全部照片', icon: Icons.photo_library_outlined),
  ];

  @override
  void initState() {
    super.initState();
    _fetchAssets();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 如果有 initialAsset，在第一帧后直接打开详情页
    if (widget.initialAsset != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openDetail(widget.initialAsset!, fromLongPress: true);
      });
    }
  }

  Future<void> _fetchAssets() async {
    setState(() => _isLoading = true);
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.isAuth) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    // 策略：查询所有图片（根相册 hasAll=true），然后按文件名 DAZZ_ 前缀过滤
    // 不依赖相册名匹配，避免 BUCKET_DISPLAY_NAME 在不同厂商 ROM 上的差异
    final allPaths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      hasAll: true,
      onlyAll: true, // 只返回根相册（所有照片），不返回子相册
      filterOption: FilterOptionGroup(
        orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
      ),
    );

    if (allPaths.isEmpty) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    // 取根相册（所有照片）
    final rootPath = allPaths.first;
    final totalCount = await rootPath.assetCountAsync;
    // 最多查最近 2000 张，避免全量扫描
    final rawAssets = await rootPath.getAssetListRange(
      start: 0,
      end: totalCount.clamp(0, 2000),
    );

    // 按文件名 DAZZ_ 前缀过滤（文件命名格式: DAZZ_{cameraId}_{timestamp}.jpg）
    final allAssets = rawAssets
        .where((a) => (a.title ?? '').toUpperCase().startsWith('DAZZ_'))
        .toList();

    // 按文件名中的 cameraId 动态统计各相机成片数量
    // 文件命名格式: DAZZ_{cameraId}_{timestamp}.jpg
    final counts = <String, int>{'all': allAssets.length};
    final cameraIdsFound = <String>{};

    for (final asset in allAssets) {
      final title = (asset.title ?? '').toLowerCase();
      for (final cam in kAllCameras) {
        if (title.contains(cam.id.toLowerCase())) {
          cameraIdsFound.add(cam.id);
          counts[cam.id] = (counts[cam.id] ?? 0) + 1;
          break;
        }
      }
    }

    // 构建动态相机分类列表：全部照片 + 有成片的相机
    final entries = <_AlbumEntry>[
      const _AlbumEntry(id: 'all', name: '全部照片', icon: Icons.photo_library_outlined),
    ];
    // 按 kAllCameras 顺序添加有成片的相机
    for (final cam in kAllCameras) {
      if (cameraIdsFound.contains(cam.id)) {
        entries.add(_AlbumEntry(id: cam.id, name: cam.name, icon: Icons.camera_alt_outlined));
      }
    }

    if (mounted) {
      setState(() {
        _allDazzAssets = allAssets;
        _assets = allAssets;
        _albumCounts = counts;
        _cameraAlbumEntries = entries;
        _isLoading = false;
      });
    }
  }

  // 按当前选中的相机 ID 过滤照片
  void _filterByCamera(String cameraId) {
    setState(() {
      _currentAlbumId = cameraId;
      _currentAlbumName = _cameraAlbumEntries
          .firstWhere((e) => e.id == cameraId,
              orElse: () => const _AlbumEntry(id: 'all', name: '全部照片'))
          .name;
      _showAlbumDropdown = false;
      if (cameraId == 'all') {
        _assets = _allDazzAssets;
      } else {
        _assets = _allDazzAssets.where((asset) {
          final title = (asset.title ?? '').toLowerCase();
          return title.contains(cameraId.toLowerCase());
        }).toList();
      }
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
    setState(() {
      _assets.removeWhere((a) => _selectedIds.contains(a.id));
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
          // ── 主内容 ──
          Column(
            children: [
              // 顶部导航栏
              _buildAppBar(),
              // 网格
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : _buildGrid(),
              ),
            ],
          ),
          // ── 相机按钮（左下角，截图中有）──
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
          // ── 相册分类下拉（截图 13085.jpg）──
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
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 左侧返回按钮
            Positioned(
              left: 8,
              child: IconButton(
                icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 20),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            // 中间标题（只有多个相机分类时才显示下拉箭头）
            GestureDetector(
              onTap: _cameraAlbumEntries.length > 1
                  ? () => setState(() => _showAlbumDropdown = !_showAlbumDropdown)
                  : null,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _currentAlbumName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
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
            // 右侧操作按钮
            Positioned(
              right: 8,
              child: _isSelectionMode
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

    // 总 item 数 = 导入按钮(1) + 照片数
    final itemCount = _assets.length + 1;
    // 每行3列，计算每格宽度
    return GridView.builder(
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 0,
        mainAxisSpacing: 0,
      ),
      itemCount: itemCount,
      itemBuilder: (ctx, index) {
        // 第一格：导入图片（截图左上角黑色格，橙色图标+文字）
        if (index == 0) {
          return GestureDetector(
            onTap: () {}, // TODO: 导入图片
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

  // ── 相册分类下拉（截图 13085.jpg）──────────────────────────────────────────
  // 半透明背景，背景模糊，列表显示相机分类+数量
  Widget _buildAlbumDropdown() {
    return GestureDetector(
      onTap: () => setState(() => _showAlbumDropdown = false),
      child: Container(
        color: Colors.transparent,
        child: Stack(
          children: [
            // 背景模糊遮罩（截图中可以看到背景网格透过来）
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Container(color: Colors.black.withAlpha(80)),
              ),
            ),
            // 下拉列表（从顶部导航栏下方开始）
            Positioned(
              top: MediaQuery.of(context).padding.top + 52,
              left: 0,
              right: 0,
              child: GestureDetector(
                onTap: () {}, // 阻止穿透
                child: Container(
                  color: Colors.transparent,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: _cameraAlbumEntries.map((entry) {
                      final count = _albumCounts[entry.id] ?? 0;
                      final isActive = entry.id == _currentAlbumId;
                      return GestureDetector(
                        onTap: () => _filterByCamera(entry.id),
                        child: Container(
                          color: Colors.transparent,
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                          child: Row(
                            children: [
                              // 相机图标（截图中是相机缩略图，这里用图标代替）
                              Container(
                                width: 64,
                                height: 64,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF2C2C2E),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(
                                  entry.icon ?? Icons.camera_alt_outlined,
                                  color: isActive ? const Color(0xFFFF8C00) : Colors.white70,
                                  size: 32,
                                ),
                              ),
                              const SizedBox(width: 16),
                              // 相机名称
                              Expanded(
                                child: Text(
                                  entry.name,
                                  style: TextStyle(
                                    color: isActive ? Colors.white : Colors.white,
                                    fontSize: 18,
                                    fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                                  ),
                                ),
                              ),
                              // 数量
                              Text(
                                '$count',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 18,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
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

// ─────────────────────────────────────────────────────────────────────────────
// 复古相片格子（截图 13084.jpg：黄色边框卡片）
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
    _load();
  }

  Future<void> _load() async {
    final data = await widget.asset.thumbnailDataWithSize(const ThumbnailSize(300, 300));
    if (mounted && data != null) setState(() => _thumb = data);
  }

  @override
  Widget build(BuildContext context) {
    // 截图 12915.jpg：直接显示原图，无边框装饰
    return Stack(
      fit: StackFit.expand,
      children: [
        // 照片内容
        _thumb != null
            ? Image.memory(_thumb!, fit: BoxFit.cover)
            : Container(color: const Color(0xFF1C1C1E)),
          // 视频时长标记
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
          // 选择模式勾选框
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
// PhotoDetailPage — 相片详情页
// 截图 12916.jpg：黑色背景，居中带相框照片，底部 # FQS、下载、删除
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
  Uint8List? _fullData;
  late int _currentIndex;
  late PageController _pageController;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.allAssets.indexOf(widget.asset);
    if (_currentIndex < 0) _currentIndex = 0;
    _pageController = PageController(initialPage: _currentIndex);
    _loadAsset(widget.asset);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadAsset(AssetEntity asset) async {
    final data = await asset.originBytes;
    if (mounted && data != null) setState(() => _fullData = data);
  }

  Future<void> _saveToGallery() async {
    // 已在相册中，提示用户
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
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final asset = widget.allAssets.isNotEmpty ? widget.allAssets[_currentIndex] : widget.asset;
    final cameraTag = '#${asset.title?.split('.').first ?? "DAZZ"}';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── 照片内容（可左右滑动）──
          PageView.builder(
            controller: _pageController,
            itemCount: widget.allAssets.isEmpty ? 1 : widget.allAssets.length,
            onPageChanged: (i) {
              setState(() {
                _currentIndex = i;
                _fullData = null;
              });
              _loadAsset(widget.allAssets[i]);
            },
            itemBuilder: (ctx, i) {
              final pageAsset = widget.allAssets.isEmpty ? widget.asset : widget.allAssets[i];
              return _PhotoFrame(asset: pageAsset, fullData: i == _currentIndex ? _fullData : null);
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

          // ── 底部操作栏（截图：# FQS + 下载 + 删除）──
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
                  // 左侧：相机标签（截图中显示 # FQS）
                  Text(
                    cameraTag,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 16,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  // 右侧：下载 + 删除
                  Row(
                    children: [
                      // 下载按钮
                      GestureDetector(
                        onTap: _saveToGallery,
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: const Color(0xFF2C2C2E),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.download_outlined, color: Colors.white, size: 24),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // 删除按钮
                      GestureDetector(
                        onTap: _deleteAsset,
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: const Color(0xFF2C2C2E),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.delete_outline, color: Colors.white, size: 24),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 相片相框组件（截图 12916.jpg：照片居中，带花纹相框背景）
// ─────────────────────────────────────────────────────────────────────────────
class _PhotoFrame extends StatefulWidget {
  final AssetEntity asset;
  final Uint8List? fullData;

  const _PhotoFrame({required this.asset, this.fullData});

  @override
  State<_PhotoFrame> createState() => _PhotoFrameState();
}

class _PhotoFrameState extends State<_PhotoFrame> {
  Uint8List? _data;

  @override
  void initState() {
    super.initState();
    if (widget.fullData != null) {
      _data = widget.fullData;
    } else {
      _load();
    }
  }

  @override
  void didUpdateWidget(_PhotoFrame old) {
    super.didUpdateWidget(old);
    if (widget.fullData != null && widget.fullData != _data) {
      setState(() => _data = widget.fullData);
    } else if (widget.fullData == null && old.asset != widget.asset) {
      setState(() => _data = null);
      _load();
    }
  }

  Future<void> _load() async {
    final data = await widget.asset.originBytes;
    if (mounted && data != null) setState(() => _data = data);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // 可用高度 = 屏幕高度 - 状态栏 - 底部操作栏(~90px)
    final availH = mq.size.height - mq.padding.top - 90;
    final availW = mq.size.width;

    return Container(
      color: Colors.black,
      child: Column(
        children: [
          SizedBox(height: mq.padding.top),
          Expanded(
            child: Center(
              child: SizedBox(
                width: availW * 0.88,
                height: availH * 0.88,
                child: _buildFramedPhoto(),
              ),
            ),
          ),
          const SizedBox(height: 90), // 底部操作栏占位
        ],
      ),
    );
  }

  Widget _buildFramedPhoto() {
    // 截图 12916.jpg：直接显示成片原图（成片本身已带相框/滤镜效果，不需要再套框）
    if (_data == null) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        ),
      );
    }
    return Image.memory(
      _data!,
      fit: BoxFit.contain,
      width: double.infinity,
      height: double.infinity,
    );
  }
}
