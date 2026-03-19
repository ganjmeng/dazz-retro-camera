// retain_settings_service.dart
// 「保留设定」功能服务层
// 负责持久化4个保留开关（色温/曝光/焦距/底片）以及各相机的设定快照
// 当用户切换相机时，camera_notifier 调用此服务保存/恢复设定

import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

double _retainToDouble(dynamic v, [double fallback = 0]) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim()) ?? fallback;
  return fallback;
}

int _retainToInt(dynamic v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String)
    return int.tryParse(v.trim()) ??
        (double.tryParse(v.trim())?.toInt() ?? fallback);
  return fallback;
}

bool _retainToBool(dynamic v, [bool fallback = false]) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final s = v.trim().toLowerCase();
    if (s == 'true' || s == '1' || s == 'yes' || s == 'on') return true;
    if (s == 'false' || s == '0' || s == 'no' || s == 'off') return false;
  }
  return fallback;
}

// ─── 保留设定开关状态 ──────────────────────────────────────────────────────────
class RetainSettingsState {
  final bool retainTemperature; // 色温
  final bool retainExposure; // 曝光设定
  final bool retainZoom; // 焦距（缩放）
  final bool retainFrame; // 底片（相框）

  const RetainSettingsState({
    this.retainTemperature = false,
    this.retainExposure = false,
    this.retainZoom = false,
    this.retainFrame = false,
  });

  RetainSettingsState copyWith({
    bool? retainTemperature,
    bool? retainExposure,
    bool? retainZoom,
    bool? retainFrame,
  }) =>
      RetainSettingsState(
        retainTemperature: retainTemperature ?? this.retainTemperature,
        retainExposure: retainExposure ?? this.retainExposure,
        retainZoom: retainZoom ?? this.retainZoom,
        retainFrame: retainFrame ?? this.retainFrame,
      );

  Map<String, dynamic> toJson() => {
        'retainTemperature': retainTemperature,
        'retainExposure': retainExposure,
        'retainZoom': retainZoom,
        'retainFrame': retainFrame,
      };

  factory RetainSettingsState.fromJson(Map<String, dynamic> json) =>
      RetainSettingsState(
        retainTemperature: _retainToBool(json['retainTemperature']),
        retainExposure: _retainToBool(json['retainExposure']),
        retainZoom: _retainToBool(json['retainZoom']),
        retainFrame: _retainToBool(json['retainFrame']),
      );
}

// ─── 各相机的设定快照 ──────────────────────────────────────────────────────────
class CameraSnapshot {
  final double temperatureOffset; // -100..100
  final int colorTempK; // 1800..8000
  final String wbMode; // 'auto'|'manual'
  final double exposureValue; // -2.0..2.0
  final double zoomLevel; // 0.6..20.0
  final String? frameId; // activeFrameId

  const CameraSnapshot({
    this.temperatureOffset = 0,
    this.colorTempK = 6300,
    this.wbMode = 'auto',
    this.exposureValue = 0,
    this.zoomLevel = 1.0,
    this.frameId,
  });

  Map<String, dynamic> toJson() => {
        'temperatureOffset': temperatureOffset,
        'colorTempK': colorTempK,
        'wbMode': wbMode,
        'exposureValue': exposureValue,
        'zoomLevel': zoomLevel,
        'frameId': frameId,
      };

  factory CameraSnapshot.fromJson(Map<String, dynamic> json) => CameraSnapshot(
        temperatureOffset: _retainToDouble(json['temperatureOffset'], 0),
        colorTempK: _retainToInt(json['colorTempK'], 6300),
        wbMode: json['wbMode'] as String? ?? 'auto',
        exposureValue: _retainToDouble(json['exposureValue'], 0),
        zoomLevel: _retainToDouble(json['zoomLevel'], 1.0),
        frameId: json['frameId'] as String?,
      );
}

// ─── Notifier ────────────────────────────────────────────────────────────────
const _kRetainSwitchKey = 'retain_settings_switches';
const _kSnapshotKeyPrefix = 'camera_snapshot_';

class RetainSettingsNotifier extends StateNotifier<RetainSettingsState> {
  RetainSettingsNotifier() : super(const RetainSettingsState()) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kRetainSwitchKey);
    if (raw != null) {
      try {
        state = RetainSettingsState.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRetainSwitchKey, jsonEncode(state.toJson()));
  }

  void toggle(String key) {
    switch (key) {
      case 'retainTemperature':
        state = state.copyWith(retainTemperature: !state.retainTemperature);
        break;
      case 'retainExposure':
        state = state.copyWith(retainExposure: !state.retainExposure);
        break;
      case 'retainZoom':
        state = state.copyWith(retainZoom: !state.retainZoom);
        break;
      case 'retainFrame':
        state = state.copyWith(retainFrame: !state.retainFrame);
        break;
    }
    _save();
  }

  // ── 快照操作（由 camera_notifier 调用）──────────────────────────────────────

  /// 保存指定相机的当前设定快照
  Future<void> saveSnapshot(String cameraId, CameraSnapshot snapshot) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_kSnapshotKeyPrefix$cameraId',
      jsonEncode(snapshot.toJson()),
    );
  }

  /// 读取指定相机的设定快照，无快照时返回 null
  Future<CameraSnapshot?> loadSnapshot(String cameraId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_kSnapshotKeyPrefix$cameraId');
    if (raw == null) return null;
    try {
      return CameraSnapshot.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}

// ─── Provider ────────────────────────────────────────────────────────────────
final retainSettingsProvider =
    StateNotifierProvider<RetainSettingsNotifier, RetainSettingsState>(
  (ref) => RetainSettingsNotifier(),
);
