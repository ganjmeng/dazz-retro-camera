import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';

/// 应用内作品列表页
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
    _fetchAssets();
  }

  Future<void> _fetchAssets() async {
    final PermissionState ps = await PhotoManager.requestPermissionExtend();
    if (ps.isAuth) {
      final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList(type: RequestType.image | RequestType.video);
      if (paths.isNotEmpty) {
        final List<AssetEntity> entities = await paths.first.getAssetListPaged(page: 0, size: 60);
        setState(() {
          _assets = entities;
          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } else {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _shareAsset(AssetEntity asset) async {
    final file = await asset.file;
    if (file != null) {
      await Share.shareXFiles([XFile(file.path)], text: 'Captured with DAZZ Retro Camera');
    }
  }

  Future<void> _shareSelected() async {
    if (_selectedAssetIds.isEmpty) return;
    
    List<XFile> filesToShare = [];
    for (var asset in _assets.where((a) => _selectedAssetIds.contains(a.id))) {
      final file = await asset.file;
      if (file != null) {
        filesToShare.add(XFile(file.path));
      }
    }
    
    if (filesToShare.isNotEmpty) {
      await Share.shareXFiles(filesToShare, text: 'Captured with DAZZ Retro Camera');
      setState(() {
        _isSelectionMode = false;
        _selectedAssetIds.clear();
      });
    }
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
        title: const Text('全部照片'),
        backgroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          if (_isSelectionMode)
            IconButton(
              icon: const Icon(Icons.share, color: Colors.white),
              onPressed: _selectedAssetIds.isNotEmpty ? _shareSelected : null,
            ),
          TextButton(
            onPressed: () {
              setState(() {
                _isSelectionMode = !_isSelectionMode;
                if (!_isSelectionMode) {
                  _selectedAssetIds.clear();
                }
              });
            },
            child: Text(
              _isSelectionMode ? '取消' : '选择', 
              style: const TextStyle(color: Colors.white)
            ),
          ),
        ],
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator())
        : GridView.builder(
            padding: const EdgeInsets.all(2),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 2,
              mainAxisSpacing: 2,
            ),
            itemCount: _assets.length,
            itemBuilder: (context, index) {
              final asset = _assets[index];
              final isSelected = _selectedAssetIds.contains(asset.id);
              
              return GestureDetector(
                onTap: () {
                  if (_isSelectionMode) {
                    _toggleSelection(asset);
                  } else {
                    _shareAsset(asset); // Or open preview screen
                  }
                },
                onLongPress: () {
                  if (!_isSelectionMode) {
                    setState(() {
                      _isSelectionMode = true;
                      _selectedAssetIds.add(asset.id);
                    });
                  }
                },
                child: FutureBuilder<List<int>?>(
                  future: asset.thumbnailDataWithSize(const ThumbnailSize(200, 200)),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.done && snapshot.data != null) {
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.memory(
                            snapshot.data as Uint8List,
                            fit: BoxFit.cover,
                          ),
                          if (asset.type == AssetType.video)
                            const Positioned(
                              bottom: 4,
                              right: 4,
                              child: Icon(Icons.play_circle_fill, color: Colors.white, size: 20),
                            ),
                          if (_isSelectionMode)
                            Positioned(
                              top: 4,
                              right: 4,
                              child: Icon(
                                isSelected ? Icons.check_circle : Icons.circle_outlined,
                                color: isSelected ? Colors.amber : Colors.white70,
                                size: 24,
                              ),
                            ),
                        ],
                      );
                    }
                    return Container(color: Colors.grey[800]);
                  },
                ),
              );
            },
          ),
    );
  }
}
