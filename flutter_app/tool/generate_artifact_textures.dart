import 'dart:io';
import 'dart:math';

import 'package:image/image.dart' as img;

void main(List<String> args) async {
  final outputDir = Directory(
    args.isNotEmpty ? args.first : 'assets/textures/artifacts',
  );
  if (!outputDir.existsSync()) {
    outputDir.createSync(recursive: true);
  }

  const size = 2048;
  _generateSet(outputDir, size: size, variant: _TextureVariant.standard);
  _generateSet(
    Directory('${outputDir.path}/light'),
    size: size,
    variant: _TextureVariant.light,
  );
  _generateSet(
    Directory('${outputDir.path}/light_plus'),
    size: size,
    variant: _TextureVariant.lightPlus,
  );

  stdout.writeln('Generated textures in ${outputDir.path}');
}

String _index(int value) => (value + 1).toString().padLeft(2, '0');

enum _TextureVariant { standard, light, lightPlus }

void _generateSet(
  Directory outputDir, {
  required int size,
  required _TextureVariant variant,
}) {
  if (!outputDir.existsSync()) {
    outputDir.createSync(recursive: true);
  }

  for (var i = 0; i < 6; i++) {
    final dust = _generateDustTexture(
      size,
      size,
      seed: 1000 + i,
      variant: variant,
    );
    final dustFile = File('${outputDir.path}/dust_${_index(i)}.png');
    dustFile.writeAsBytesSync(img.encodePng(dust, level: 6));

    final scratch = _generateScratchTexture(
      size,
      size,
      seed: 2000 + i,
      variant: variant,
    );
    final scratchFile = File('${outputDir.path}/scratch_${_index(i)}.png');
    scratchFile.writeAsBytesSync(img.encodePng(scratch, level: 6));
  }
}

img.Image _generateDustTexture(
  int width,
  int height, {
  required int seed,
  required _TextureVariant variant,
}) {
  final random = Random(seed);
  final image = img.Image(width: width, height: height, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(0, 0, 0, 0));

  final isLight = variant == _TextureVariant.light;
  final isLightPlus = variant == _TextureVariant.lightPlus;
  final speckCount = isLight
      ? 140 + random.nextInt(90)
      : isLightPlus
          ? 190 + random.nextInt(110)
          : 320 + random.nextInt(180);
  for (var i = 0; i < speckCount; i++) {
    final x = random.nextInt(width);
    final y = random.nextInt(height);
    final radius = random.nextDouble() < 0.90
        ? 0.55 +
            random.nextDouble() *
                (isLight
                    ? 1.15
                    : isLightPlus
                        ? 1.35
                        : 1.65)
        : (isLight
                ? 1.2
                : isLightPlus
                    ? 1.45
                    : 1.85) +
            random.nextDouble() *
                (isLight
                    ? 1.7
                    : isLightPlus
                        ? 2.1
                        : 2.7);
    final alpha = random.nextDouble() < 0.9
        ? (isLight
                ? 34
                : isLightPlus
                    ? 48
                    : 64) +
            random.nextInt(
              isLight
                  ? 46
                  : isLightPlus
                      ? 64
                      : 96,
            )
        : (isLight
                ? 62
                : isLightPlus
                    ? 82
                    : 110) +
            random.nextInt(
              isLight
                  ? 54
                  : isLightPlus
                      ? 70
                      : 95,
            );
    _paintSoftDot(image, x.toDouble(), y.toDouble(), radius, alpha);

    if (random.nextDouble() <
        (isLight
            ? 0.05
            : isLightPlus
                ? 0.08
                : 0.12)) {
      final trailAngle = random.nextDouble() * pi;
      final trailLength = (isLight
              ? 2
              : isLightPlus
                  ? 3
                  : 4) +
          random.nextInt(
            isLight
                ? 6
                : isLightPlus
                    ? 8
                    : 12,
          );
      for (var t = 0; t < trailLength; t++) {
        final dx = cos(trailAngle) * t * 0.7;
        final dy = sin(trailAngle) * t * 0.7;
        _paintSoftDot(
          image,
          x + dx,
          y + dy,
          max(0.55, radius * 0.28),
          (alpha * 0.22).round(),
        );
      }
    }
  }

  // 叠加一层高亮硬点：提升肉眼可见度，但半径很小避免“大片发雾”。
  final hardSpeckCount = isLight
      ? 55 + random.nextInt(40)
      : isLightPlus
          ? 80 + random.nextInt(50)
          : 120 + random.nextInt(80);
  for (var i = 0; i < hardSpeckCount; i++) {
    final x = random.nextInt(width);
    final y = random.nextInt(height);
    final radius = 0.45 +
        random.nextDouble() *
            (isLight
                ? 0.7
                : isLightPlus
                    ? 0.9
                    : 1.2);
    final alpha = (isLight
            ? 190
            : isLightPlus
                ? 210
                : 225) +
        random.nextInt(
          isLight
              ? 45
              : isLightPlus
                  ? 35
                  : 30,
        );
    _paintHardDot(image, x.toDouble(), y.toDouble(), radius, alpha);
  }

  final hazeClusters = isLight
      ? 2 + random.nextInt(2)
      : isLightPlus
          ? 3 + random.nextInt(2)
          : 4 + random.nextInt(3);
  for (var i = 0; i < hazeClusters; i++) {
    final x = random.nextInt(width).toDouble();
    final y = random.nextInt(height).toDouble();
    final radius = (isLight
            ? 6
            : isLightPlus
                ? 8
                : 10) +
        random.nextDouble() *
            (isLight
                ? 10
                : isLightPlus
                    ? 14
                    : 18);
    _paintSoftDot(
      image,
      x,
      y,
      radius,
      (isLight
              ? 8
              : isLightPlus
                  ? 12
                  : 16) +
          random.nextInt(
            isLight
                ? 8
                : isLightPlus
                    ? 10
                    : 14,
          ),
    );
  }

  return image;
}

img.Image _generateScratchTexture(
  int width,
  int height, {
  required int seed,
  required _TextureVariant variant,
}) {
  final random = Random(seed);
  final image = img.Image(width: width, height: height, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(0, 0, 0, 0));

  final isLight = variant == _TextureVariant.light;
  final isLightPlus = variant == _TextureVariant.lightPlus;
  final scratchCount = isLight
      ? 14 + random.nextInt(8)
      : isLightPlus
          ? 20 + random.nextInt(12)
          : 34 + random.nextInt(18);
  for (var i = 0; i < scratchCount; i++) {
    final points = <Point<double>>[];
    final startX = random.nextDouble() * width;
    final startY = random.nextDouble() * height;
    final angle = random.nextDouble() * pi;
    final segments = 1 + random.nextInt(2);
    final step = (isLight
            ? 6
            : isLightPlus
                ? 8
                : 10) +
        random.nextDouble() *
            (isLight
                ? 10
                : isLightPlus
                    ? 14
                    : 18);
    points.add(Point(startX, startY));
    for (var s = 0; s < segments; s++) {
      final last = points.last;
      final jitter = (random.nextDouble() - 0.5) * 2.6;
      final bend = angle + jitter;
      points.add(
        Point(
          last.x + cos(bend) * step,
          last.y + sin(bend) * step,
        ),
      );
    }

    final alpha = (isLight
            ? 120
            : isLightPlus
                ? 145
                : 170) +
        random.nextInt(
          isLight
              ? 90
              : isLightPlus
                  ? 85
                  : 80,
        );
    final thickness = random.nextDouble() < 0.75
        ? (isLight
                ? 1.8
                : isLightPlus
                    ? 2.2
                    : 2.8) +
            random.nextDouble() *
                (isLight
                    ? 1.3
                    : isLightPlus
                        ? 1.6
                        : 1.9)
        : (isLight
                ? 3.0
                : isLightPlus
                    ? 3.8
                    : 4.6) +
            random.nextDouble() *
                (isLight
                    ? 1.8
                    : isLightPlus
                        ? 2.1
                        : 2.5);
    _paintPolyline(image, points, thickness, alpha);
    if (random.nextDouble() < 0.55) {
      // 叠加短亮白“断裂段”，增强不规则感和可见度
      final p0 = points.first;
      final angle = random.nextDouble() * pi;
      final len = (isLight
              ? 5.0
              : isLightPlus
                  ? 7.0
                  : 9.0) +
          random.nextDouble() *
              (isLight
                  ? 8.0
                  : isLightPlus
                      ? 10.0
                      : 14.0);
      final p1 = Point(
        p0.x + cos(angle) * len,
        p0.y + sin(angle) * len,
      );
      _paintSegment(
        image,
        p0,
        p1,
        thickness * (0.85 + random.nextDouble() * 0.4),
        (alpha * 0.95).round(),
      );
    }
    if (points.length >= 2 && random.nextDouble() < 0.86) {
      final head = points.first;
      final neck = points[1];
      _paintSegment(
        image,
        head,
        Point(
          head.x + (neck.x - head.x) * 0.45,
          head.y + (neck.y - head.y) * 0.45,
        ),
        thickness * (0.95 + random.nextDouble() * 0.45),
        (alpha * 0.92).round(),
      );
    }

    if (random.nextDouble() <
        (isLight
            ? 0.34
            : isLightPlus
                ? 0.46
                : 0.58)) {
      _paintPolyline(image, points, thickness + 1.6, (alpha * 0.28).round());
    }
  }

  final fiberCount = isLight
      ? 7 + random.nextInt(6)
      : isLightPlus
          ? 10 + random.nextInt(7)
          : 16 + random.nextInt(10);
  for (var i = 0; i < fiberCount; i++) {
    final startX = random.nextDouble() * width;
    final startY = random.nextDouble() * height;
    final angle = random.nextDouble() * pi;
    final length = (isLight
            ? 14
            : isLightPlus
                ? 18
                : 22) +
        random.nextDouble() *
            (isLight
                ? 24
                : isLightPlus
                    ? 30
                    : 38);
    final controlJitter = (isLight
            ? 8
            : isLightPlus
                ? 10
                : 12) +
        random.nextDouble() *
            (isLight
                ? 14
                : isLightPlus
                    ? 18
                    : 24);
    final points = <Point<double>>[
      Point(startX, startY),
      Point(
        startX +
            cos(angle) * length * 0.35 +
            (random.nextDouble() - 0.5) * controlJitter,
        startY +
            sin(angle) * length * 0.35 +
            (random.nextDouble() - 0.5) * controlJitter,
      ),
      Point(
        startX +
            cos(angle) * length * 0.7 +
            (random.nextDouble() - 0.5) * controlJitter,
        startY +
            sin(angle) * length * 0.7 +
            (random.nextDouble() - 0.5) * controlJitter,
      ),
      Point(
        startX + cos(angle) * length,
        startY + sin(angle) * length,
      ),
    ];
    _paintPolyline(
      image,
      points,
      (isLight
              ? 0.7
              : isLightPlus
                  ? 0.9
                  : 1.2) +
          random.nextDouble(),
      (isLight
              ? 10
              : isLightPlus
                  ? 14
                  : 20) +
          random.nextInt(
            isLight
                ? 12
                : isLightPlus
                    ? 18
                    : 24,
          ),
    );
  }

  return image;
}

void _paintPolyline(
  img.Image image,
  List<Point<double>> points,
  double thickness,
  int alpha,
) {
  for (var i = 0; i < points.length - 1; i++) {
    _paintSegment(image, points[i], points[i + 1], thickness, alpha);
  }
}

void _paintSegment(
  img.Image image,
  Point<double> a,
  Point<double> b,
  double thickness,
  int alpha,
) {
  final dx = b.x - a.x;
  final dy = b.y - a.y;
  final distance = sqrt(dx * dx + dy * dy);
  final steps = max(1, distance.ceil());
  for (var i = 0; i <= steps; i++) {
    final t = i / steps;
    final x = a.x + dx * t;
    final y = a.y + dy * t;
    _paintSoftDot(image, x, y, thickness, alpha);
  }
}

void _paintSoftDot(
  img.Image image,
  double cx,
  double cy,
  double radius,
  int alpha,
) {
  final minX = max(0, (cx - radius - 1).floor());
  final maxX = min(image.width - 1, (cx + radius + 1).ceil());
  final minY = max(0, (cy - radius - 1).floor());
  final maxY = min(image.height - 1, (cy + radius + 1).ceil());
  final effectiveAlpha = alpha.clamp(0, 255);

  for (var y = minY; y <= maxY; y++) {
    for (var x = minX; x <= maxX; x++) {
      final dx = x - cx;
      final dy = y - cy;
      final distance = sqrt(dx * dx + dy * dy);
      if (distance > radius * 1.35) continue;
      final falloff = max(0.0, 1.0 - (distance / (radius * 1.35)));
      final localAlpha = (effectiveAlpha * pow(falloff, 1.25)).round();
      if (localAlpha <= 0) continue;
      _blendWhite(image, x, y, localAlpha);
    }
  }
}

void _paintHardDot(
  img.Image image,
  double cx,
  double cy,
  double radius,
  int alpha,
) {
  final minX = max(0, (cx - radius - 1).floor());
  final maxX = min(image.width - 1, (cx + radius + 1).ceil());
  final minY = max(0, (cy - radius - 1).floor());
  final maxY = min(image.height - 1, (cy + radius + 1).ceil());
  final effectiveAlpha = alpha.clamp(0, 255);
  for (var y = minY; y <= maxY; y++) {
    for (var x = minX; x <= maxX; x++) {
      final dx = x - cx;
      final dy = y - cy;
      final distance = sqrt(dx * dx + dy * dy);
      if (distance > radius) continue;
      _blendWhite(image, x, y, effectiveAlpha);
    }
  }
}

void _blendWhite(img.Image image, int x, int y, int alpha) {
  final pixel = image.getPixel(x, y);
  final existingAlpha = pixel.a.toInt();
  final addAlpha = alpha.clamp(0, 255);
  final outAlpha = (existingAlpha + ((255 - existingAlpha) * addAlpha) / 255.0)
      .round()
      .clamp(0, 255);
  image.setPixelRgba(x, y, 255, 255, 255, outAlpha);
}
