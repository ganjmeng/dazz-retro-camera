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
  /// 样片图片 asset 路径列表（用于样片页面展示）
  final List<String> samplePhotos;
  /// 相机简短描述
  final String description;
  /// 风格标签
  final List<String> tags;

  const CameraEntry({
    required this.id,
    required this.name,
    required this.assetPath,
    required this.category,
    this.focalLengthLabel,
    this.premium = false,
    this.sortOrder = 0,
    this.iconPath,
    this.samplePhotos = const [],
    this.description = '',
    this.tags = const [],
  });
}

/// 默认相机排序（用户未自定义时使用，重置时恢复此顺序）
/// 顺序：FXN-R, CPM35, Inst C, U300, CCD-R, D Classic, GRD-R, FQS, BW Classic, Inst SQC
/// 其余相机（fisheye, inst_s 等）追加到末尾
const List<String> kDefaultCameraOrder = [
  'fxn_r',
  'cpm35',
  'inst_c',
  'u300',
  'ccd_r',
  'd_classic',
  'grd_r',
  'fqs',
  'bw_classic',
  'sqc',
  // 其余相机
  'fisheye',
  'inst_s',
];

/// All registered cameras. Add new cameras here.
const List<CameraEntry> kAllCameras = [
  CameraEntry(
    id: 'fxn_r',
    name: 'FXN R',
    assetPath: 'assets/cameras/fxn_r.json',
    category: 'film',
    focalLengthLabel: '35mm',
    premium: false,
    sortOrder: 10,
    iconPath: 'assets/thumbnails/cameras/fxn_r_icon.png',
    description: '模拟 Fujifilm 胶片机质感，暖调色彩，颗粒感丰富。',
    tags: ['胶片', '暖调', '颗粒', 'Fujifilm'],
    samplePhotos: [
      'assets/samples/fxn_r_sample_1.jpg',
      'assets/samples/fxn_r_sample_2.jpg',
      'assets/samples/fxn_r_sample_3.jpg',
    ],
  ),
  CameraEntry(
    id: 'cpm35',
    name: 'CPM35',
    assetPath: 'assets/cameras/cpm35.json',
    category: 'film',
    focalLengthLabel: '35mm',
    premium: false,
    sortOrder: 20,
    iconPath: 'assets/thumbnails/cameras/cpm35_icon.png',
    description: 'Kodak Gold 200 / ColorPlus 200 风格，暖色复古，轻颗粒，干净出片。90s 傻瓜机日常胶片质感，旅行、街拍、人像通吃。',
    tags: ['胶片', '暖色', '复古', 'Kodak', '35mm', '傻瓜机', '日常'],
    samplePhotos: [
      'assets/samples/fxn_r_sample_1.jpg',
      'assets/samples/fxn_r_sample_2.jpg',
      'assets/samples/fxn_r_sample_3.jpg',
    ],
  ),
  CameraEntry(
    id: 'inst_c',
    name: 'INST C',
    assetPath: 'assets/cameras/inst_c.json',
    category: 'instant',
    focalLengthLabel: '60mm',
    premium: false,
    sortOrder: 30,
    iconPath: 'assets/thumbnails/cameras/inst_c_icon.png',
    description: '彩色拍立得风格，饱和鲜艳，复古彩色边框加持。',
    tags: ['彩色', '饱和', '边框', '拍立得'],
    samplePhotos: [
      'assets/samples/inst_c_sample_1.jpg',
      'assets/samples/inst_c_sample_2.jpg',
      'assets/samples/inst_c_sample_3.jpg',
    ],
  ),
  CameraEntry(
    id: 'u300',
    name: 'U300',
    assetPath: 'assets/cameras/u300.json',
    category: 'film',
    focalLengthLabel: '32mm',
    premium: false,
    sortOrder: 40,
    iconPath: 'assets/thumbnails/cameras/u300_icon.png',
    description: '一次性相机质感，轻微漏光，边角暗角，胶片颗粒感强烈。',
    tags: ['一次性', '漏光', '颗粒', '胶片'],
    samplePhotos: [
      'assets/samples/u300_sample_1.jpg',
      'assets/samples/u300_sample_2.jpg',
      'assets/samples/u300_sample_3.jpg',
    ],
  ),
  CameraEntry(
    id: 'ccd_r',
    name: 'CCD R',
    assetPath: 'assets/cameras/ccd_r.json',
    category: 'ccd',
    focalLengthLabel: '35mm',
    premium: false,
    sortOrder: 50,
    iconPath: 'assets/thumbnails/cameras/ccd_r_icon.png',
    description: '2003-2006 早期 CCD 卡片机色调，蓝绿偏色，噪点明显，CCD 味重。',
    tags: ['CCD', '蓝绿', '噪点', '早期数码', '2003'],
    samplePhotos: [
      'assets/samples/ccd_m_sample_1.jpg',
      'assets/samples/ccd_m_sample_2.jpg',
      'assets/samples/ccd_m_sample_3.jpg',
    ],
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
    description: '经典数码相机色彩风格，自然还原，日常随拍利器。',
    tags: ['自然', '日常', '清晰', '数码'],
    samplePhotos: [
      'assets/samples/d_classic_sample_1.jpg',
      'assets/samples/d_classic_sample_2.jpg',
      'assets/samples/d_classic_sample_3.jpg',
    ],
  ),
  CameraEntry(
    id: 'grd_r',
    name: 'GRD R',
    assetPath: 'assets/cameras/grd_r.json',
    category: 'ccd',
    focalLengthLabel: '28mm',
    premium: false,
    sortOrder: 70,
    iconPath: 'assets/thumbnails/cameras/grd_r_icon.png',
    description: '经典 GR 数码相机风格，锐利通透，街头纪实首选。',
    tags: ['街头', '纪实', '锐利', 'CCD'],
    samplePhotos: [
      'assets/samples/grd_r_sample_1.jpg',
      'assets/samples/grd_r_sample_2.jpg',
      'assets/samples/grd_r_sample_3.jpg',
    ],
  ),
  CameraEntry(
    id: 'fqs',
    name: 'FQS',
    assetPath: 'assets/cameras/fqs.json',
    category: 'film',
    focalLengthLabel: '50mm',
    premium: false,
    sortOrder: 80,
    iconPath: 'assets/thumbnails/cameras/fqs_icon.png',
    description: 'Fuji Superia 400 + Kodak Portra 400 双胶卷融合，柔和绿调，肤色自然，颗粒感明显。2000年代 35mm SLR 经典质感。',
    tags: ['胶片', '绿调', '柔和', 'Fuji', 'Kodak', '35mm', 'SLR'],
    samplePhotos: [
      'assets/samples/fxn_r_sample_1.jpg',
      'assets/samples/fxn_r_sample_2.jpg',
      'assets/samples/fxn_r_sample_3.jpg',
    ],
  ),
  CameraEntry(
    id: 'bw_classic',
    name: 'BW Classic',
    assetPath: 'assets/cameras/bw_classic.json',
    category: 'film',
    focalLengthLabel: '35mm',
    premium: false,
    sortOrder: 90,
    iconPath: 'assets/thumbnails/cameras/bw_classic_icon.png',
    description: '黑白胶片经典模拟，高对比度，光影层次极致表达。',
    tags: ['黑白', '高对比', '经典', '胶片'],
    samplePhotos: [
      'assets/samples/bw_classic_sample_1.jpg',
      'assets/samples/bw_classic_sample_2.jpg',
      'assets/samples/bw_classic_sample_3.jpg',
    ],
  ),
  CameraEntry(
    id: 'sqc',
    name: 'INST SQC',
    assetPath: 'assets/cameras/sqc.json',
    category: 'instant',
    focalLengthLabel: '35mm',
    premium: false,
    sortOrder: 100,
    iconPath: 'assets/thumbnails/cameras/inst_sq_icon.png',
    description: '方形构图拍立得风格，复古边框，即拍即得的温暖感。',
    tags: ['方形', '边框', '复古', '拍立得'],
    samplePhotos: [
      'assets/samples/sqc_sample_1.jpg',
      'assets/samples/sqc_sample_2.jpg',
      'assets/samples/sqc_sample_3.jpg',
    ],
  ),
  CameraEntry(
    id: 'fisheye',
    name: 'FISHEYE',
    assetPath: 'assets/cameras/fisheye.json',
    category: 'creative',
    focalLengthLabel: '10mm',
    premium: false,
    sortOrder: 110,
    iconPath: 'assets/thumbnails/cameras/fisheye_icon.png',
    description: '鱼眼镜头极致畸变，超广角视野，街头滑板文化美学。',
    tags: ['鱼眼', '畸变', '创意', '超广角'],
    samplePhotos: [
      'assets/samples/fisheye_sample_1.jpg',
      'assets/samples/fisheye_sample_2.jpg',
      'assets/samples/fisheye_sample_3.jpg',
    ],
  ),
  CameraEntry(
    id: 'inst_s',
    name: 'INST S',
    assetPath: 'assets/cameras/inst_s.json',
    category: 'instant',
    focalLengthLabel: '60mm',
    premium: false,
    sortOrder: 120,
    iconPath: 'assets/thumbnails/cameras/inst_s_icon.png',
    description: 'Instax 系列宽幅拍立得，横版构图，柔和粉调色彩。',
    tags: ['宽幅', '粉调', '柔和', '拍立得'],
    samplePhotos: [
      'assets/samples/inst_s_sample_1.jpg',
      'assets/samples/inst_s_sample_2.jpg',
      'assets/samples/inst_s_sample_3.jpg',
    ],
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
