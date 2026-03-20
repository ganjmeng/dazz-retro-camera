import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kOriginalAssetIndex = 'pref_original_asset_index';

class OriginalAssetService {
  OriginalAssetService._();

  static final OriginalAssetService instance = OriginalAssetService._();

  Future<String?> saveOriginalCopy(
    String sourcePath, {
    required String cameraId,
  }) async {
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) return null;

    final dir = await _originalsDir();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final suffix = cameraId.isEmpty ? 'photo' : cameraId;
    final target = File('${dir.path}/dazz_original_${suffix}_$timestamp.jpg');
    await sourceFile.copy(target.path);
    return target.path;
  }

  Future<void> linkOriginal({
    required String assetId,
    required String originalPath,
  }) async {
    if (assetId.isEmpty || originalPath.isEmpty) return;
    final index = await _loadIndex();
    final previousPath = index[assetId];
    if (previousPath != null && previousPath != originalPath) {
      await _deleteFileIfExists(previousPath);
    }
    index[assetId] = originalPath;
    await _saveIndex(index);
  }

  Future<String?> getOriginalPath(String assetId) async {
    final index = await _loadIndex();
    final path = index[assetId];
    if (path == null || path.isEmpty) return null;
    if (!await File(path).exists()) {
      index.remove(assetId);
      await _saveIndex(index);
      return null;
    }
    return path;
  }

  Future<bool> hasOriginal(String assetId) async =>
      (await getOriginalPath(assetId)) != null;

  Future<void> removeOriginal(String assetId) async {
    final index = await _loadIndex();
    final path = index.remove(assetId);
    await _saveIndex(index);
    if (path != null) {
      await _deleteFileIfExists(path);
    }
  }

  Future<void> removeOriginals(Iterable<String> assetIds) async {
    final ids = assetIds.where((e) => e.isNotEmpty).toSet();
    if (ids.isEmpty) return;
    final index = await _loadIndex();
    final paths = <String>[];
    for (final id in ids) {
      final path = index.remove(id);
      if (path != null && path.isNotEmpty) {
        paths.add(path);
      }
    }
    await _saveIndex(index);
    for (final path in paths) {
      await _deleteFileIfExists(path);
    }
  }

  Future<void> deleteUnlinkedPath(String? path) async {
    if (path == null || path.isEmpty) return;
    await _deleteFileIfExists(path);
  }

  Future<Map<String, String>> _loadIndex() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kOriginalAssetIndex);
    if (raw == null || raw.isEmpty) return <String, String>{};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return <String, String>{};
    return decoded.map<String, String>(
      (key, value) => MapEntry(key.toString(), value.toString()),
    );
  }

  Future<void> _saveIndex(Map<String, String> index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kOriginalAssetIndex, jsonEncode(index));
  }

  Future<Directory> _originalsDir() async {
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory('${supportDir.path}/originals');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _deleteFileIfExists(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
