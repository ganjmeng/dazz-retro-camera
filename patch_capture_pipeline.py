#!/usr/bin/env python3
"""
Patch _drawWatermark in capture_pipeline.dart to support styleOverride parameter.
"""

with open('/home/ubuntu/retro_cam_project/flutter_app/lib/features/camera/capture_pipeline.dart', 'r') as f:
    content = f.read()

# Find the _drawWatermark function
start_marker = '  void _drawWatermark(\n      Canvas canvas, double ox, double oy, double w, double h, String watermarkId, {\n    String? colorOverride,\n    String? positionOverride,\n    String? sizeOverride,\n    String? directionOverride,\n  }) {'
end_marker = '      textPainter.paint(canvas, Offset(dx, dy));\n    }\n  }'

start_idx = content.find(start_marker)
end_idx = content.find(end_marker)

if start_idx == -1:
    print("ERROR: start_marker not found")
    # Debug
    idx = content.find('void _drawWatermark')
    print(f"_drawWatermark found at: {idx}")
    if idx != -1:
        print(repr(content[idx:idx+300]))
    exit(1)

if end_idx == -1:
    print("ERROR: end_marker not found")
    # Debug
    idx = content.find('textPainter.paint(canvas, Offset(dx, dy))')
    print(f"textPainter.paint found at: {idx}")
    if idx != -1:
        print(repr(content[idx:idx+100]))
    exit(1)

end_idx += len(end_marker)
print(f"Found _drawWatermark from {start_idx} to {end_idx}")

new_func = '''  void _drawWatermark(
      Canvas canvas, double ox, double oy, double w, double h, String watermarkId, {
    String? colorOverride,
    String? positionOverride,
    String? sizeOverride,
    String? directionOverride,
    String? styleOverride, // 样式 ID，对应 kWatermarkStyles 中的 id
  }) {
    final wmPresets = camera.modules.watermarks.presets;
    if (wmPresets.isEmpty) return;

    WatermarkPreset? wmOpt;
    try {
      wmOpt = wmPresets.firstWhere((wm) => wm.id == watermarkId);
    } catch (_) {
      return;
    }

    if (wmOpt.isNone) return;

    final now = DateTime.now();
    // 获取样式定义（默认 s1）
    final styleDef = getWatermarkStyle(styleOverride);
    // 根据样式生成文本
    final text = styleDef.buildText(now);

    // 解析颜色：用户覆盖 > preset默认
    Color textColor = const Color(0xFFFF8C00);
    final colorSrc = colorOverride ?? wmOpt.color;
    if (colorSrc != null && colorSrc.isNotEmpty) {
      try {
        final hex = colorSrc.replaceAll('#', '');
        textColor = Color(int.parse('FF$hex', radix: 16));
      } catch (_) {}
    }

    // 解析大小：用户覆盖 > preset默认
    double baseFontSize;
    switch (sizeOverride) {
      case 'small':  baseFontSize = w * 0.028; break;
      case 'medium': baseFontSize = w * 0.038; break;
      case 'large':  baseFontSize = w * 0.055; break;
      default:
        // 使用 preset 的 fontSize 比例计算（preset.fontSize 是参考屏幕像素，这里按宽度比例缩放）
        baseFontSize = w * 0.038;
    }
    final fontSize = baseFontSize.clamp(12.0, 120.0);

    // 解析方向：用户覆盖 > 默认水平
    final isVertical = (directionOverride ?? 'horizontal') == 'vertical';

    // 解析位置：用户覆盖 > preset默认
    final position = positionOverride ?? wmOpt.position ?? 'bottom_right';
    final margin = w * 0.04;

    // 样式定义的字体和字间距
    final fontFamily = styleDef.fontFamily ?? wmOpt.fontFamily;
    final letterSpacing = styleDef.letterSpacing;
    final fontWeight = styleDef.fontWeight;

    if (isVertical) {
      // 垂直水印：每个字符单独绘制
      final charPainters = text.split('').map((c) {
        final p = TextPainter(
          text: TextSpan(text: c, style: TextStyle(
            color: textColor,
            fontSize: fontSize,
            fontFamily: fontFamily,
            fontWeight: fontWeight,
          )),
          textDirection: TextDirection.ltr,
        )..layout();
        return p;
      }).toList();

      final totalH = charPainters.fold(0.0, (s, p) => s + p.height);
      final charW = charPainters.fold(0.0, (s, p) => math.max(s, p.width));

      double startX, startY;
      switch (position) {
        case 'bottom_right':
          startX = ox + w - charW - margin;
          startY = oy + h - totalH - margin;
          break;
        case 'bottom_left':
          startX = ox + margin;
          startY = oy + h - totalH - margin;
          break;
        case 'top_right':
          startX = ox + w - charW - margin;
          startY = oy + margin;
          break;
        case 'top_left':
          startX = ox + margin;
          startY = oy + margin;
          break;
        case 'bottom_center':
          startX = ox + (w - charW) / 2;
          startY = oy + h - totalH - margin;
          break;
        case 'top_center':
          startX = ox + (w - charW) / 2;
          startY = oy + margin;
          break;
        default:
          startX = ox + w - charW - margin;
          startY = oy + h - totalH - margin;
      }

      double curY = startY;
      for (final p in charPainters) {
        p.paint(canvas, Offset(startX + (charW - p.width) / 2, curY));
        curY += p.height;
      }
    } else {
      // 水平水印
      final textPainter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: textColor,
            fontSize: fontSize,
            fontFamily: fontFamily,
            fontWeight: fontWeight,
            letterSpacing: letterSpacing,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: w);

      double dx, dy;
      switch (position) {
        case 'bottom_right':
          dx = ox + w - textPainter.width - margin;
          dy = oy + h - textPainter.height - margin;
          break;
        case 'bottom_left':
          dx = ox + margin;
          dy = oy + h - textPainter.height - margin;
          break;
        case 'top_right':
          dx = ox + w - textPainter.width - margin;
          dy = oy + margin;
          break;
        case 'top_left':
          dx = ox + margin;
          dy = oy + margin;
          break;
        case 'bottom_center':
          dx = ox + (w - textPainter.width) / 2;
          dy = oy + h - textPainter.height - margin;
          break;
        case 'top_center':
          dx = ox + (w - textPainter.width) / 2;
          dy = oy + margin;
          break;
        default:
          dx = ox + w - textPainter.width - margin;
          dy = oy + h - textPainter.height - margin;
      }

      textPainter.paint(canvas, Offset(dx, dy));
    }
  }'''

new_content = content[:start_idx] + new_func + content[end_idx:]

with open('/home/ubuntu/retro_cam_project/flutter_app/lib/features/camera/capture_pipeline.dart', 'w') as f:
    f.write(new_content)

print(f"SUCCESS: Replaced _drawWatermark function ({end_idx - start_idx} chars -> {len(new_func)} chars)")
