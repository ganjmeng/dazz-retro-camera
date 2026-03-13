import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/preset.dart';

/// 负责加载和管理 Preset 配置列表
class PresetRepository {
  // 内置 Preset 资源路径列表
  static const _builtinPresetPaths = [
    'assets/presets/ccd_cool.json',
    'assets/presets/ccd_flash.json',
    'assets/presets/ccd_night.json',
  ];

  /// 加载所有内置 Preset
  Future<List<Preset>> loadBuiltinPresets() async {
    final presets = <Preset>[];
    for (final path in _builtinPresetPaths) {
      try {
        final jsonString = await rootBundle.loadString(path);
        final jsonMap = json.decode(jsonString) as Map<String, dynamic>;
        presets.add(Preset.fromJson(jsonMap));
      } catch (e) {
        print('Failed to load preset from $path: $e');
      }
    }
    return presets;
  }
}

// Provider 定义
final presetRepositoryProvider = Provider<PresetRepository>((ref) {
  return PresetRepository();
});

final presetListProvider = FutureProvider<List<Preset>>((ref) async {
  final repository = ref.watch(presetRepositoryProvider);
  return repository.loadBuiltinPresets();
});
