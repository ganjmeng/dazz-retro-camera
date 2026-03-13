import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';

/// 应用内作品列表页 — 只显示 DAZZ 相册照片
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});
  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  List<AssetEntity> _assets = [];
  Set<String> _selectedAssetIds = {};
  bool _isLoading = true;
  bool _isSelectionMode = false;

  @override
  void initState() {
    super.initState();
    _fetchDazzAssets();
  }

  // 只加载 DAZZ 相册中的照片
  Future<void> _fetchDazzAssets() async {
    setState(() => _isLoading = true);
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.isAuth) {
      setState(() => _isLoading = false);
      return;
    }

    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      filterOption: FilterOptionGroup(
        orders: [
          const OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );

    // 优先找 DAZZ 相册
    AssetPathEntity? dazzPath;
    for (final p in paths) {
      if (p.name.toUpperCase().contains('DAZZ')) {
        dazzPath = p;
        break;
      }
    }

    if (dazzPath != null) {
      final entities = await dazzPath.getAssetListPaged(page: 0, size: 200);
      if (mounted) {
        setState(() {
          _assets = entities;
          _isLoading = false;
        });
      }
    } else {
      // 没有 DAZZ 相册时显示空列表
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _shareAsset(AssetEntity asset) async {
    final file = await asset.file;
    if (file != null) {
      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'Captured with DAZZ Retro Camera',
      );
    }
  }

  Future<void> _shareSelected() async {
    if (_selectedAssetIds.isEmpty) return;
    final List<XFile> files = [];
    for (final asset in _assets.where((a) => _selectedAssetIds.contains(a.id))) {
      final file = await asset.file;
      if (file != null) files.add(XFile(file.path));
    }
    if (files.isNotEmpty) {
      await Share.shareXFiles(files, text: 'Captured with DAZZ Retro Camera');
      setState(() {
        _isSelectionMode = false;
        _selectedAssetIds.clear();
      });
    }
  }

  Future<void> _deleteSelected() async {
    if (_selectedAssetIds.isEmpty) return;
    final toDelete = _assets
        .where((a) => _selectedAssetIds.contains(a.id))
        .toList();
    await PhotoManager.editor.deleteWithIds(
      toDelete.map((a) => a.id).toList(),
    );
    setState(() {
      _assets.removeWhere((a) => _selectedAssetIds.contains(a.id));
      _selectedAssetIds.clear();
      _isSelectionMode = false;
    });
  }

  void _toggleSelection(AssetEntity asset) {
    setState(() {
      if (_selectedAssetIds.contains(asset.id)) {
        _selectedAssetIds.remove(asset.id);
      } else {
        _selectedAssetIds.add(asset.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Text(
              '全部照片',
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(width: 4),
            Icon(Icons.keyboard_arrow_down, color: Colors.white, size: 20),
          ],
        ),
        centerTitle: true,
        actions: [
          if (_isSelectionMode) ...[
            IconButton(
              icon: const Icon(Icons.share_outlined, color: Colors.white),
              onPressed: _selectedAssetIds.isNotEmpty ? _shareSelected : null,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.white),
              onPressed: _selectedAssetIds.isNotEmpty ? _deleteSelected : null,
            ),
          ],
          TextButton(
            onPressed: () {
              setState(() {
                _isSelectionMode = !_isSelectionMode;
                if (!_isSelectionMode) _selectedAssetIds.clear();
              });
            },
            child: Text(
              _isSelectionMode ? '取消' : '选择',
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2,
              ),
            )
          : _assets.isEmpty
              ? _buildEmptyState()
              : _buildGrid(),
    );
  }

  Widget _buildEmptyState() {
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
            child: const Icon(
              Icons.camera_alt_outlined,
              color: Color(0xFFFF8C00),
              size: 40,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '还没有照片',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '用 DAZZ 拍摄的照片会出现在这里',
            style: TextStyle(color: Colors.grey, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    return GridView.builder(
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 2,
        mainAxisSpacing: 2,
      ),
      itemCount: _assets.length + 1, // +1 for import button
      itemBuilder: (context, index) {
        // 第一格：导入图片按钮
        if (index == 0) {
          return GestureDetector(
            onTap: () {}, // TODO: 导入图片
            child: Container(
              color: const Color(0xFF1C1C1E),
              child: const Center(
                child: Icon(
                  Icons.add_photo_alternate_outlined,
                  color: Color(0xFFFF8C00),
                  size: 36,
                ),
              ),
            ),
          );
        }

        final asset = _assets[index - 1];
        final isSelected = _selectedAssetIds.contains(asset.id);

        return GestureDetector(
          onTap: () {
            if (_isSelectionMode) {
              _toggleSelection(asset);
            } else {
              HapticFeedback.selectionClick();
              _showPhotoPreview(asset);
            }
          },
          onLongPress: () {
            if (!_isSelectionMode) {
              HapticFeedback.mediumImpact();
              setState(() {
                _isSelectionMode = true;
                _selectedAssetIds.add(asset.id);
              });
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              FutureBuilder<Uint8List?>(
                future: asset.thumbnailDataWithSize(
                    const ThumbnailSize(200, 200)),
                builder: (ctx, snap) {
                  if (snap.hasData && snap.data != null) {
                    return Image.memory(
                      snap.data!,
                      fit: BoxFit.cover,
                    );
                  }
                  return Container(color: Colors.grey[900]);
                },
              ),
              if (asset.type == AssetType.video)
                const Positioned(
                  bottom: 4,
                  right: 4,
                  child: Icon(Icons.play_circle_fill,
                      color: Colors.white, size: 20),
                ),
              if (_isSelectionMode)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isSelected
                          ? Colors.blue
                          : Colors.black.withAlpha(100),
                      border: Border.all(
                        color: Colors.white,
                        width: 1.5,
                      ),
                    ),
                    child: isSelected
                        ? const Icon(Icons.check,
                            color: Colors.white, size: 14)
                        : null,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  void _showPhotoPreview(AssetEntity asset) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black,
      builder: (ctx) => _PhotoPreviewSheet(
        asset: asset,
        onDelete: () async {
          await PhotoManager.editor.deleteWithIds([asset.id]);
          setState(() => _assets.remove(asset));
          Navigator.of(ctx).pop();
        },
        onShare: () async {
          Navigator.of(ctx).pop();
          await _shareAsset(asset);
        },
      ),
    );
  }
}

// ─── 照片预览底部弹窗 ─────────────────────────────────────────────────────────

class _PhotoPreviewSheet extends StatelessWidget {
  final AssetEntity asset;
  final VoidCallback onDelete;
  final VoidCallback onShare;

  const _PhotoPreviewSheet({
    required this.asset,
    required this.onDelete,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.85,
      child: Column(
        children: [
          // 拖动条
          Container(
            margin: const EdgeInsets.only(top: 8),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey[700],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // 照片预览
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FutureBuilder<Uint8List?>(
                future: asset.originBytes,
                builder: (ctx, snap) {
                  if (snap.hasData && snap.data != null) {
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(
                        snap.data!,
                        fit: BoxFit.contain,
                      ),
                    );
                  }
                  return const Center(
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2),
                  );
                },
              ),
            ),
          ),
          // 底部操作栏
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // 相机型号标签
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2C2C2E),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    '# DAZZ',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                ),
                Row(
                  children: [
                    // 下载/分享
                    GestureDetector(
                      onTap: onShare,
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF2C2C2E),
                        ),
                        child: const Icon(Icons.download_outlined,
                            color: Colors.white, size: 22),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // 删除
                    GestureDetector(
                      onTap: () {
                        showDialog(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            backgroundColor: const Color(0xFF2C2C2E),
                            title: const Text('删除照片',
                                style: TextStyle(color: Colors.white)),
                            content: const Text('确定要删除这张照片吗？',
                                style: TextStyle(color: Colors.white70)),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(ctx).pop(),
                                child: const Text('取消',
                                    style: TextStyle(color: Colors.white54)),
                              ),
                              TextButton(
                                onPressed: () {
                                  Navigator.of(ctx).pop();
                                  onDelete();
                                },
                                child: const Text('删除',
                                    style: TextStyle(color: Colors.red)),
                              ),
                            ],
                          ),
                        );
                      },
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF2C2C2E),
                        ),
                        child: const Icon(Icons.delete_outline,
                            color: Colors.white, size: 22),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
