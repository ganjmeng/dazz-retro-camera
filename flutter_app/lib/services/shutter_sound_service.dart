// shutter_sound_service.dart
// 快门声音服务：按相机类型播放对应的快门声音
// 设计：单例 + 预加载，确保快门按下时零延迟播放

import 'package:audioplayers/audioplayers.dart';

// ─── 快门声音类型 ──────────────────────────────────────────────────────────────

enum ShutterSoundType {
  mechanical, // GRD / 胶片 SLR：机械快门咔哒声
  instax,     // Instax / 拍立得：软哒 + 马达声
  ccd,        // CCD 数码相机：电子哔哒声
  fisheye,    // Lomo / 鱼眼玩具机：塑料咔嚓声
  silent,     // 静音：极轻微的咔声
}

// ─── 相机 ID → 声音类型映射 ───────────────────────────────────────────────────

const _kCameraToSound = <String, ShutterSoundType>{
  'grd_r':     ShutterSoundType.mechanical,
  'bw_classic': ShutterSoundType.mechanical,
  'fxn_r':     ShutterSoundType.mechanical,
  'sqc':       ShutterSoundType.instax,
  'inst_c':    ShutterSoundType.instax,
  'ccd_m':     ShutterSoundType.ccd,
  'ccd_r':     ShutterSoundType.ccd,
  'd_classic': ShutterSoundType.ccd,
  'u300':      ShutterSoundType.ccd,
  'fisheye':   ShutterSoundType.fisheye,
};

// ─── 声音类型 → 资源路径 ──────────────────────────────────────────────────────

const _kSoundAssets = <ShutterSoundType, String>{
  ShutterSoundType.mechanical: 'sounds/shutter_mechanical.wav',
  ShutterSoundType.instax:     'sounds/shutter_instax.wav',
  ShutterSoundType.ccd:        'sounds/shutter_ccd.wav',
  ShutterSoundType.fisheye:    'sounds/shutter_fisheye.wav',
  ShutterSoundType.silent:     'sounds/shutter_silent.wav',
};

// ─── 服务类 ───────────────────────────────────────────────────────────────────

class ShutterSoundService {
  ShutterSoundService._();
  static final ShutterSoundService instance = ShutterSoundService._();

  // 每种声音类型一个独立的 AudioPlayer，避免并发冲突
  final Map<ShutterSoundType, AudioPlayer> _players = {};
  bool _initialized = false;

  /// 预加载所有声音（在 App 启动时调用一次）
  Future<void> initialize() async {
    if (_initialized) return;
    for (final type in ShutterSoundType.values) {
      final player = AudioPlayer();
      await player.setReleaseMode(ReleaseMode.stop);
      await player.setVolume(1.0);
      // 预加载到缓存
      final assetPath = _kSoundAssets[type]!;
      await player.setSource(AssetSource(assetPath));
      _players[type] = player;
    }
    _initialized = true;
  }

  /// 按相机 ID 播放对应快门声音
  /// [cameraId] 当前相机的 ID
  Future<void> play(String cameraId) async {
    if (!_initialized) await initialize();
    final type = _kCameraToSound[cameraId] ?? ShutterSoundType.mechanical;
    final player = _players[type];
    if (player == null) return;
    try {
      // 停止上一次播放（防止连拍时重叠）
      await player.stop();
      await player.resume();
    } catch (_) {
      // 忽略播放错误，不影响拍照流程
    }
  }

  /// 释放所有资源
  Future<void> dispose() async {
    for (final player in _players.values) {
      await player.dispose();
    }
    _players.clear();
    _initialized = false;
  }

  /// 获取相机对应的声音类型（用于 UI 展示）
  static ShutterSoundType soundTypeForCamera(String cameraId) {
    return _kCameraToSound[cameraId] ?? ShutterSoundType.mechanical;
  }

  /// 声音类型的中文名称
  static String soundTypeName(ShutterSoundType type) {
    switch (type) {
      case ShutterSoundType.mechanical: return '机械快门';
      case ShutterSoundType.instax:     return '拍立得';
      case ShutterSoundType.ccd:        return '数码相机';
      case ShutterSoundType.fisheye:    return '玩具相机';
      case ShutterSoundType.silent:     return '静音';
    }
  }
}
