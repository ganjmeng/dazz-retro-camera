// camera_registry.dart
// Central registry for all available cameras.
// Each camera is loaded from its JSON asset file.

import 'package:flutter/services.dart';
import 'camera_definition.dart';

/// Metadata for a camera entry in the registry (lightweight, no full parse).
class CameraEntry {
  final String id;
  final String name;
  final String assetPath;
  final String category; // 'ccd' | 'film' | 'digital'
  final String? focalLengthLabel;
  final bool premium;
  final int sortOrder;
  /// 相机图标 asset 路径（用于相机选择器和快门行）
  final String? iconPath;

  const CameraEntry({
    required this.id,
    required this.name,
    required this.assetPath,
    required this.category,
    this.focalLengthLabel,
    this.premium = false,
    this.sortOrder = 0,
    this.iconPath,
  });
}

/// All registered cameras. Add new cameras here.
const List<CameraEntry> kAllCameras = [
  CameraEntry(
    id: 'grd_r',
    name: 'GRD R',
    assetPath: 'assets/cameras/grd_r.json',
    category: 'ccd',
    focalLengthLabel: '28mm',
    premium: false,
    sortOrder: 0,
    iconPath: 'assets/thumbnails/cameras/grd_r_icon.png',
  ),
  CameraEntry(
    id: 'inst_sq',
    name: 'INST SQ',
    assetPath: 'assets/cameras/inst_sq.json',
    category: 'instant',
    focalLengthLabel: '35mm',
    premium: false,
    sortOrder: 20,
    iconPath: 'assets/thumbnails/cameras/inst_sq_icon.png',
  ),
  CameraEntry(
    id: 'fxn_r',
    name: 'FXN R',
    assetPath: 'assets/cameras/fxn_r.json',
    category: 'film',
    focalLengthLabel: '35mm',
    premium: false,
    sortOrder: 30,
    iconPath: 'assets/thumbnails/cameras/fxn_r_icon.png',
  ),
  CameraEntry(
    id: 'bw_classic',
    name: 'BW Classic',
    assetPath: 'assets/cameras/bw_classic.json',
    category: 'film',
    focalLengthLabel: '35mm',
    premium: false,
    sortOrder: 40,
    iconPath: 'assets/thumbnails/cameras/bw_classic_icon.png',
  ),
];

/// Load a full CameraDefinition by camera id.
Future<CameraDefinition> loadCamera(String cameraId) async {
  final entry = kAllCameras.firstWhere(
    (e) => e.id == cameraId,
    orElse: () => kAllCameras.first,
  );
  final jsonStr = await rootBundle.loadString(entry.assetPath);
  return CameraDefinition.fromJsonString(jsonStr);
}
