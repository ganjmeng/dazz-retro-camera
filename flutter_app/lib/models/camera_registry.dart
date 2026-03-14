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
  final String category; // 'ccd' | 'film' | 'digital' | 'instant' | 'creative'
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
  // ── 原有相机 ──────────────────────────────────────────────────────────────
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

  // ── 新增相机 ──────────────────────────────────────────────────────────────
  CameraEntry(
    id: 'ccd_m',
    name: 'CCD M',
    assetPath: 'assets/cameras/ccd_m.json',
    category: 'ccd',
    focalLengthLabel: '35mm',
    premium: false,
    sortOrder: 50,
    iconPath: 'assets/thumbnails/cameras/ccd_m_icon.png',
  ),
  CameraEntry(
    id: 'd_classic',
    name: 'D Classic',
    assetPath: 'assets/cameras/d_classic.json',
    category: 'digital',
    focalLengthLabel: '38mm',
    premium: false,
    sortOrder: 60,
    iconPath: 'assets/thumbnails/cameras/d_classic_icon.png',
  ),
  CameraEntry(
    id: 'inst_c',
    name: 'INST C',
    assetPath: 'assets/cameras/inst_c.json',
    category: 'instant',
    focalLengthLabel: '60mm',
    premium: false,
    sortOrder: 70,
    iconPath: 'assets/thumbnails/cameras/inst_c_icon.png',
  ),
  CameraEntry(
    id: 'inst_s',
    name: 'INST S',
    assetPath: 'assets/cameras/inst_s.json',
    category: 'instant',
    focalLengthLabel: '60mm',
    premium: false,
    sortOrder: 80,
    iconPath: 'assets/thumbnails/cameras/inst_s_icon.png',
  ),
  CameraEntry(
    id: 'u300',
    name: 'U300',
    assetPath: 'assets/cameras/u300.json',
    category: 'film',
    focalLengthLabel: '32mm',
    premium: false,
    sortOrder: 90,
    iconPath: 'assets/thumbnails/cameras/u300_icon.png',
  ),
  CameraEntry(
    id: 'fisheye',
    name: 'FISHEYE',
    assetPath: 'assets/cameras/fisheye.json',
    category: 'creative',
    focalLengthLabel: '10mm',
    premium: false,
    sortOrder: 100,
    iconPath: 'assets/thumbnails/cameras/fisheye_icon.png',
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
