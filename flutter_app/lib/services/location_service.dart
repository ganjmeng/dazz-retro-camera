import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

/// 位置服务
/// 封装 GPS 权限请求、位置获取，供拍照管线写入 EXIF 使用
class LocationService {
  LocationService._();

  static final LocationService instance = LocationService._();

  /// 检查并请求位置权限
  /// 返回：
  ///   true  → 已授权，可以获取位置
  ///   false → 用户拒绝或设备不支持
  Future<bool> requestPermission() async {
    // 检查设备是否支持位置服务
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint('[LocationService] Location service disabled');
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        debugPrint('[LocationService] Permission denied');
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      debugPrint('[LocationService] Permission denied forever');
      return false;
    }

    return true;
  }

  /// 检查当前权限状态（不弹出请求弹窗）
  Future<LocationPermissionStatus> checkStatus() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return LocationPermissionStatus.serviceDisabled;

    final permission = await Geolocator.checkPermission();
    switch (permission) {
      case LocationPermission.always:
      case LocationPermission.whileInUse:
        return LocationPermissionStatus.granted;
      case LocationPermission.denied:
        return LocationPermissionStatus.denied;
      case LocationPermission.deniedForever:
        return LocationPermissionStatus.deniedForever;
      case LocationPermission.unableToDetermine:
        return LocationPermissionStatus.denied;
    }
  }

  /// 获取当前位置（低精度，快速）
  /// 拍照时调用，超时 5 秒，失败返回 null
  Future<Position?> getCurrentPosition() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium, // 中等精度，节省电量
          timeLimit: Duration(seconds: 5),
        ),
      );
      debugPrint('[LocationService] Got position: ${position.latitude}, ${position.longitude}');
      return position;
    } catch (e) {
      debugPrint('[LocationService] Failed to get position: $e');
      return null;
    }
  }

  /// 打开系统设置（权限被永久拒绝时引导用户）
  Future<void> openSettings() => Geolocator.openAppSettings();
}

/// 位置权限状态枚举
enum LocationPermissionStatus {
  granted,
  denied,
  deniedForever,
  serviceDisabled,
}

/// 位置开关切换结果
enum LocationToggleResult {
  enabled,           // 开启成功
  disabled,          // 关闭成功
  permissionDenied,  // 权限被拒绝
  permissionDeniedForever, // 权限被永久拒绝，需引导到设置
}
