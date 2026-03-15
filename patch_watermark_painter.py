#!/usr/bin/env python3
"""
Patch _WatermarkPainter in camera_screen.dart to support styleId parameter.
"""

with open('/home/ubuntu/retro_cam_project/flutter_app/lib/features/camera/camera_screen.dart', 'r') as f:
    content = f.read()

start_marker = 'class _WatermarkPainter extends CustomPainter {'
end_marker = '  @override\n  bool shouldRepaint(_WatermarkPainter old) =>\n      old.watermark != watermark ||\n      old.colorOverride != colorOverride ||\n      old.positionOverride != positionOverride ||\n      old.sizeOverride != sizeOverride ||\n      old.directionOverride != directionOverride;\n}'

start_idx = content.find(start_marker)
end_idx = content.find(end_marker)

if start_idx == -1 or end_idx == -1:
    print("ERROR: markers not found")
    exit(1)

end_idx += len(end_marker)

new_class = '''class _WatermarkPainter extends CustomPainter {
  final WatermarkPreset watermark;
  final String? colorOverride;
  final String? positionOverride;
  final String? sizeOverride;
  final String? directionOverride;
  final String? styleId; // 样式 ID，对应 kWatermarkStyles 中的 id

  _WatermarkPainter({
    required this.watermark,
    this.colorOverride,
    this.positionOverride,
    this.sizeOverride,
    this.directionOverride,
    this.styleId,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final now = DateTime.now();
    // 获取样式定义（默认 s1）
    final styleDef = getWatermarkStyle(styleId);
    // 根据样式生成文本
    final text = styleDef.buildText(now);
    // 解析颜色
    Color textColor = const Color(0xFFFF8C00);
    final colorSrc = colorOverride ?? watermark.color;
    if (colorSrc != null && colorSrc.isNotEmpty) {
      try {
        final hex = colorSrc.replaceAll('#', '');
        textColor = Color(int.parse('FF$hex', radix: 16));
      } catch (_) {}
    }

    // 解析大小
    double baseFontSize;
    switch (sizeOverride) {
      case 'small':
        baseFontSize = size.width * 0.028;
        break;
      case 'medium':
        baseFontSize = size.width * 0.038;
        break;
      case 'large':
        baseFontSize = size.width * 0.055;
        break;
      default:
        baseFontSize = size.width * 0.038;
    }
    final fontSize = baseFontSize.clamp(10.0, 60.0);

    // 解析方向
    final isVertical = (directionOverride ?? 'horizontal') == 'vertical';

    // 解析位置
    final position = positionOverride ?? watermark.position ?? 'bottom_right';
    final margin = size.width * 0.04;

    // 样式定义的字体和字间距
    final fontFamily = styleDef.fontFamily ?? watermark.fontFamily;
    final letterSpacing = styleDef.letterSpacing;
    final fontWeight = styleDef.fontWeight;

    if (isVertical) {
      // 垂直水印：逐字符绘制
      final style = TextStyle(
        color: textColor,
        fontSize: fontSize,
        fontFamily: fontFamily,
        fontWeight: fontWeight,
      );
      final charPainters = text.split('').map((c) {
        final p = TextPainter(
          text: TextSpan(text: c, style: style),
          textDirection: TextDirection.ltr,
        )..layout();
        return p;
      }).toList();

      final totalH = charPainters.fold(0.0, (s, p) => s + p.height);
      final charW = charPainters.fold(
          0.0, (s, p) => s > p.width ? s : p.width);

      double startX, startY;
      switch (position) {
        case 'bottom_right':
          startX = size.width - charW - margin;
          startY = size.height - totalH - margin;
          break;
        case 'bottom_left':
          startX = margin;
          startY = size.height - totalH - margin;
          break;
        case 'top_right':
          startX = size.width - charW - margin;
          startY = margin;
          break;
        case 'top_left':
          startX = margin;
          startY = margin;
          break;
        case 'bottom_center':
          startX = (size.width - charW) / 2;
          startY = size.height - totalH - margin;
          break;
        case 'top_center':
          startX = (size.width - charW) / 2;
          startY = margin;
          break;
        default:
          startX = size.width - charW - margin;
          startY = size.height - totalH - margin;
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
      )..layout(maxWidth: size.width);

      double dx, dy;
      switch (position) {
        case 'bottom_right':
          dx = size.width - textPainter.width - margin;
          dy = size.height - textPainter.height - margin;
          break;
        case 'bottom_left':
          dx = margin;
          dy = size.height - textPainter.height - margin;
          break;
        case 'top_right':
          dx = size.width - textPainter.width - margin;
          dy = margin;
          break;
        case 'top_left':
          dx = margin;
          dy = margin;
          break;
        case 'bottom_center':
          dx = (size.width - textPainter.width) / 2;
          dy = size.height - textPainter.height - margin;
          break;
        case 'top_center':
          dx = (size.width - textPainter.width) / 2;
          dy = margin;
          break;
        default:
          dx = size.width - textPainter.width - margin;
          dy = size.height - textPainter.height - margin;
      }

      textPainter.paint(canvas, Offset(dx, dy));
    }
  }

  @override
  bool shouldRepaint(_WatermarkPainter old) =>
      old.watermark != watermark ||
      old.colorOverride != colorOverride ||
      old.positionOverride != positionOverride ||
      old.sizeOverride != sizeOverride ||
      old.directionOverride != directionOverride ||
      old.styleId != styleId;
}'''

new_content = content[:start_idx] + new_class + content[end_idx:]

with open('/home/ubuntu/retro_cam_project/flutter_app/lib/features/camera/camera_screen.dart', 'w') as f:
    f.write(new_content)

print(f"SUCCESS: Replaced _WatermarkPainter class ({end_idx - start_idx} chars -> {len(new_class)} chars)")
