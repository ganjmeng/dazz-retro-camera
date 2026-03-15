#!/usr/bin/env python3
"""
Patch _WatermarkPreviewOverlay and _WatermarkPainter in image_edit_screen.dart
to support styleId parameter.
"""

with open('/home/ubuntu/retro_cam_project/flutter_app/lib/features/image_edit/image_edit_screen.dart', 'r') as f:
    content = f.read()

# Find the start of _WatermarkPreviewOverlay
start_marker = 'class _WatermarkPreviewOverlay extends StatelessWidget {'
# Find the end of _WatermarkPainter
end_marker = '  @override\n  bool shouldRepaint(_WatermarkPainter old) =>\n      old.watermark != watermark ||\n      old.colorOverride != colorOverride ||\n      old.positionOverride != positionOverride ||\n      old.sizeOverride != sizeOverride ||\n      old.directionOverride != directionOverride;\n}'

start_idx = content.find(start_marker)
end_idx = content.find(end_marker)

if start_idx == -1:
    print("ERROR: start_marker not found")
    exit(1)
if end_idx == -1:
    print("ERROR: end_marker not found")
    # Debug
    idx = content.find('bool shouldRepaint(_WatermarkPainter old)')
    print(f"shouldRepaint found at: {idx}")
    if idx != -1:
        print(repr(content[idx:idx+300]))
    exit(1)

end_idx += len(end_marker)
print(f"Found section from {start_idx} to {end_idx}")

new_section = '''class _WatermarkPreviewOverlay extends StatelessWidget {
  final WatermarkPreset watermark;
  final String? colorOverride;
  final String? positionOverride;
  final String? sizeOverride;
  final String? directionOverride;
  final String? styleId; // 样式 ID，对应 kWatermarkStyles 中的 id

  const _WatermarkPreviewOverlay({
    required this.watermark,
    this.colorOverride,
    this.positionOverride,
    this.sizeOverride,
    this.directionOverride,
    this.styleId,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: CustomPaint(
        painter: _WatermarkPainter(
          watermark: watermark,
          colorOverride: colorOverride,
          positionOverride: positionOverride,
          sizeOverride: sizeOverride,
          directionOverride: directionOverride,
          styleId: styleId,
        ),
      ),
    );
  }
}

class _WatermarkPainter extends CustomPainter {
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

    Color textColor = const Color(0xFFFF8C00);
    final colorSrc = colorOverride ?? watermark.color;
    if (colorSrc != null && colorSrc.isNotEmpty) {
      try {
        final hex = colorSrc.replaceAll('#', '');
        textColor = Color(int.parse('FF$hex', radix: 16));
      } catch (_) {}
    }

    double baseFontSize;
    switch (sizeOverride) {
      case 'small':  baseFontSize = size.width * 0.028; break;
      case 'large':  baseFontSize = size.width * 0.055; break;
      default:       baseFontSize = size.width * 0.038; break;
    }

    // 样式定义的字体和字间距
    final fontFamily = styleDef.fontFamily ?? watermark.fontFamily;
    final letterSpacing = styleDef.letterSpacing;
    final fontWeight = styleDef.fontWeight;

    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: textColor,
          fontSize: baseFontSize,
          fontFamily: fontFamily,
          fontWeight: fontWeight,
          letterSpacing: letterSpacing,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();

    final pos = positionOverride ?? watermark.position ?? 'bottom_right';
    const margin = 16.0;
    double dx, dy;
    switch (pos) {
      case 'bottom_left':   dx = margin; dy = size.height - textPainter.height - margin; break;
      case 'top_right':     dx = size.width - textPainter.width - margin; dy = margin; break;
      case 'top_left':      dx = margin; dy = margin; break;
      case 'bottom_center': dx = (size.width - textPainter.width) / 2; dy = size.height - textPainter.height - margin; break;
      case 'top_center':    dx = (size.width - textPainter.width) / 2; dy = margin; break;
      default:              dx = size.width - textPainter.width - margin; dy = size.height - textPainter.height - margin; break;
    }

    final dir = directionOverride ?? 'horizontal';
    if (dir == 'vertical') {
      canvas.save();
      canvas.translate(dx + textPainter.height / 2, dy + textPainter.width / 2);
      canvas.rotate(-math.pi / 2);
      textPainter.paint(canvas, Offset(-textPainter.width / 2, -textPainter.height / 2));
      canvas.restore();
    } else {
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

new_content = content[:start_idx] + new_section + content[end_idx:]

with open('/home/ubuntu/retro_cam_project/flutter_app/lib/features/image_edit/image_edit_screen.dart', 'w') as f:
    f.write(new_content)

print(f"SUCCESS: Replaced watermark classes ({end_idx - start_idx} chars -> {len(new_section)} chars)")
