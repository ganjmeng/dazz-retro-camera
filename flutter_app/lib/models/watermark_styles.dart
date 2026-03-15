// ─────────────────────────────────────────────────────────────────────────────
// watermark_styles.dart
// 水印样式定义：6 种 LED 数字时钟风格
// 每种样式控制：日期格式、字体、字间距、字重、预览字号
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';

/// 水印日期格式枚举
enum WatermarkDateFormat {
  /// 2 25 22  （月 日 年，空格分隔）
  spaceSeparated,
  /// 2 25 '22 （月 日 '年，撇号年份）
  apostropheYear,
  /// 2 25'22  （月 日'年，紧凑撇号）
  compactApostrophe,
  /// 02.25.22 （点分隔，补零）
  dotSeparated,
  /// 25/02/22 （斜线分隔，日月年）
  slashDMY,
  /// 2026.03.15 （完整年份）
  fullYear,
}

/// 单种水印样式定义
class WatermarkStyleDef {
  final String id;
  final String label;
  final WatermarkDateFormat dateFormat;
  final String? fontFamily;
  final FontWeight fontWeight;
  final double letterSpacing;
  final double wordSpacing;
  /// 卡片预览字号（px），用于 camera_config_sheet 中的预览卡片
  final double fontSize;

  const WatermarkStyleDef({
    required this.id,
    required this.label,
    required this.dateFormat,
    this.fontFamily,
    this.fontWeight = FontWeight.w700,
    this.letterSpacing = 2.0,
    this.wordSpacing = 0.0,
    this.fontSize = 13.0,
  });

  /// 根据当前时间生成水印文字
  String buildText(DateTime now) {
    final y2 = now.year.toString().substring(2);
    final m = now.month.toString();
    final d = now.day.toString().padLeft(2, ' ');
    final mm = now.month.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');

    switch (dateFormat) {
      case WatermarkDateFormat.spaceSeparated:
        return '$m $d $y2';
      case WatermarkDateFormat.apostropheYear:
        return "$m $d '$y2";
      case WatermarkDateFormat.compactApostrophe:
        return "$m $d'$y2";
      case WatermarkDateFormat.dotSeparated:
        return '$mm.$dd.$y2';
      case WatermarkDateFormat.slashDMY:
        return '$dd/$mm/$y2';
      case WatermarkDateFormat.fullYear:
        return '${now.year}.$mm.$dd';
    }
  }
}

/// 所有可用水印样式
const List<WatermarkStyleDef> kWatermarkStyles = [
  WatermarkStyleDef(
    id: 's1',
    label: '经典',
    dateFormat: WatermarkDateFormat.spaceSeparated,
    fontFamily: 'monospace',
    fontWeight: FontWeight.w700,
    letterSpacing: 4.0,
    wordSpacing: 2.0,
    fontSize: 14.0,
  ),
  WatermarkStyleDef(
    id: 's2',
    label: '撇号',
    dateFormat: WatermarkDateFormat.apostropheYear,
    fontFamily: 'monospace',
    fontWeight: FontWeight.w700,
    letterSpacing: 3.0,
    wordSpacing: 1.0,
    fontSize: 13.0,
  ),
  WatermarkStyleDef(
    id: 's3',
    label: '紧凑',
    dateFormat: WatermarkDateFormat.compactApostrophe,
    fontFamily: 'monospace',
    fontWeight: FontWeight.w900,
    letterSpacing: 1.5,
    wordSpacing: 0.0,
    fontSize: 15.0,
  ),
  WatermarkStyleDef(
    id: 's4',
    label: '点分',
    dateFormat: WatermarkDateFormat.dotSeparated,
    fontFamily: 'monospace',
    fontWeight: FontWeight.w700,
    letterSpacing: 2.0,
    wordSpacing: 0.0,
    fontSize: 13.0,
  ),
  WatermarkStyleDef(
    id: 's5',
    label: '斜线',
    dateFormat: WatermarkDateFormat.slashDMY,
    fontFamily: 'monospace',
    fontWeight: FontWeight.w400,
    letterSpacing: 1.5,
    wordSpacing: 0.0,
    fontSize: 13.0,
  ),
  WatermarkStyleDef(
    id: 's6',
    label: '完整',
    dateFormat: WatermarkDateFormat.fullYear,
    fontFamily: 'monospace',
    fontWeight: FontWeight.w700,
    letterSpacing: 1.0,
    wordSpacing: 0.0,
    fontSize: 11.0,
  ),
];

/// 根据 ID 查找样式，找不到返回默认（s1）
WatermarkStyleDef getWatermarkStyle(String? styleId) {
  if (styleId == null) return kWatermarkStyles.first;
  return kWatermarkStyles.firstWhere(
    (s) => s.id == styleId,
    orElse: () => kWatermarkStyles.first,
  );
}
