// app_prefs_service.dart
// 全局应用偏好持久化服务
// 负责：清晰度、地理位置、网格、小窗、快门声、快门振动、最后选择的相机

import 'package:shared_preferences/shared_preferences.dart';

const _kSharpenLevel        = 'pref_sharpen_level';
const _kLocationEnabled     = 'pref_location_enabled';
const _kGridEnabled         = 'pref_grid_enabled';
const _kMinimapEnabled      = 'pref_minimap_enabled';
const _kShutterSound        = 'pref_shutter_sound';
const _kShutterVibration    = 'pref_shutter_vibration';
const _kLastCameraId        = 'pref_last_camera_id';
const _kMirrorFrontCamera   = 'pref_mirror_front_camera';

class AppPrefs {
  final int    sharpenLevel;        // 0=低 1=中 2=高，默认1
  final bool   locationEnabled;     // 默认 false
  final bool   gridEnabled;         // 默认 false
  final bool   minimapEnabled;      // 默认 false
  final bool   shutterSoundEnabled; // 默认 true
  final bool   shutterVibrationEnabled; // 默认 true
  final String lastCameraId;        // 默认 'grd_r'
  final bool   mirrorFrontCamera;   // 默认 true

  const AppPrefs({
    this.sharpenLevel           = 1,
    this.locationEnabled        = false,
    this.gridEnabled            = false,
    this.minimapEnabled         = false,
    this.shutterSoundEnabled    = true,
    this.shutterVibrationEnabled = true,
    this.lastCameraId           = 'grd_r',
    this.mirrorFrontCamera      = true,
  });
}

class AppPrefsService {
  AppPrefsService._();
  static final AppPrefsService instance = AppPrefsService._();

  Future<AppPrefs> load() async {
    final p = await SharedPreferences.getInstance();
    return AppPrefs(
      sharpenLevel:            p.getInt(_kSharpenLevel)          ?? 1,
      locationEnabled:         p.getBool(_kLocationEnabled)       ?? false,
      gridEnabled:             p.getBool(_kGridEnabled)           ?? false,
      minimapEnabled:          p.getBool(_kMinimapEnabled)        ?? false,
      shutterSoundEnabled:     p.getBool(_kShutterSound)          ?? true,
      shutterVibrationEnabled: p.getBool(_kShutterVibration)      ?? true,
      lastCameraId:            p.getString(_kLastCameraId)        ?? 'grd_r',
      mirrorFrontCamera:       p.getBool(_kMirrorFrontCamera)     ?? true,
    );
  }

  Future<void> setSharpenLevel(int v) async =>
      (await SharedPreferences.getInstance()).setInt(_kSharpenLevel, v);

  Future<void> setLocationEnabled(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kLocationEnabled, v);

  Future<void> setGridEnabled(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kGridEnabled, v);

  Future<void> setMinimapEnabled(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kMinimapEnabled, v);

  Future<void> setShutterSoundEnabled(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kShutterSound, v);

  Future<void> setShutterVibrationEnabled(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kShutterVibration, v);

  Future<void> setLastCameraId(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kLastCameraId, v);

  Future<void> setMirrorFrontCamera(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kMirrorFrontCamera, v);
}
