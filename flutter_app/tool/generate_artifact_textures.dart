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
      ? 90 + random.nextInt(60)
      : isLightPlus
          ? 130 + random.nextInt(80)
          : 220 + random.nextInt(120);
  for (var i = 0; i < speckCount; i++) {
    final x = random.nextInt(width);
    final y = random.nextInt(height);
    final radius = random.nextDouble() < 0.88
        ? 0.8 +
            random.nextDouble() *
                (isLight
                    ? 1.8
                    : isLightPlus
                        ? 2.3
                        : 3.0)
        : (isLight
                ? 2.2
                : isLightPlus
                    ? 3.0
                    : 4.0) +
            random.nextDouble() *
                (isLight
                    ? 5.0
                    : isLightPlus
                        ? 7.5
                        : 10.0);
    final alpha = random.nextDouble() < 0.9
        ? (isLight
                ? 7
                : isLightPlus
                    ? 10
                    : 12) +
            random.nextInt(
              isLight
                  ? 14
                  : isLightPlus
                      ? 22
                      : 30,
            )
        : (isLight
                ? 18
                : isLightPlus
                    ? 30
                    : 40) +
            random.nextInt(
              isLight
                  ? 24
                  : isLightPlus
                      ? 40
                      : 70,
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
              ? 3
              : isLightPlus
                  ? 4
                  : 5) +
          random.nextInt(
            isLight
                ? 8
                : isLightPlus
                    ? 12
                    : 20,
          );
      for (var t = 0; t < trailLength; t++) {
        final dx = cos(trailAngle) * t * 0.7;
        final dy = sin(trailAngle) * t * 0.7;
        _paintSoftDot(
          image,
          x + dx,
          y + dy,
          max(0.8, radius * 0.35),
          (alpha * 0.16).round(),
        );
      }
    }
  }

  final hazeClusters = isLight
      ? 3 + random.nextInt(4)
      : isLightPlus
          ? 6 + random.nextInt(5)
          : 10 + random.nextInt(8);
  for (var i = 0; i < hazeClusters; i++) {
    final x = random.nextInt(width).toDouble();
    final y = random.nextInt(height).toDouble();
    final radius = (isLight
            ? 10
            : isLightPlus
                ? 12
                : 18) +
        random.nextDouble() *
            (isLight
                ? 20
                : isLightPlus
                    ? 28
                    : 45);
    _paintSoftDot(
      image,
      x,
      y,
      radius,
      (isLight
              ? 4
              : isLightPlus
                  ? 7
                  : 10) +
          random.nextInt(
            isLight
                ? 7
                : isLightPlus
                    ? 10
                    : 16,
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
      ? 8 + random.nextInt(6)
      : isLightPlus
          ? 12 + random.nextInt(8)
          : 22 + random.nextInt(12);
  for (var i = 0; i < scratchCount; i++) {
    final points = <Point<double>>[];
    final startX = random.nextDouble() * width;
    final startY = random.nextDouble() * height;
    final angle = random.nextDouble() * pi;
    final segments = 2 + random.nextInt(4);
    final step = (isLight
            ? 14
            : isLightPlus
                ? 17
                : 20) +
        random.nextDouble() *
            (isLight
                ? 34
                : isLightPlus
                    ? 42
                    : 60);
    points.add(Point(startX, startY));
    for (var s = 0; s < segments; s++) {
      final last = points.last;
      final jitter = (random.nextDouble() - 0.5) * 0.7;
      final bend = angle + jitter;
      points.add(
        Point(
          last.x + cos(bend) * step,
          last.y + sin(bend) * step,
        ),
      );
    }

    final alpha = (isLight
            ? 8
            : isLightPlus
                ? 12
                : 18) +
        random.nextInt(
          isLight
              ? 20
              : isLightPlus
                  ? 30
                  : 60,
        );
    final thickness = random.nextDouble() < 0.75
        ? (isLight
                ? 0.6
                : isLightPlus
                    ? 0.8
                    : 1.0) +
            random.nextDouble() *
                (isLight
                    ? 0.8
                    : isLightPlus
                        ? 0.95
                        : 1.2)
        : (isLight
                ? 1.3
                : isLightPlus
                    ? 1.6
                    : 2.2) +
            random.nextDouble() *
                (isLight
                    ? 1.0
                    : isLightPlus
                        ? 1.2
                        : 2.0);
    _paintPolyline(image, points, thickness, alpha);

    if (random.nextDouble() <
        (isLight
            ? 0.25
            : isLightPlus
                ? 0.34
                : 0.45)) {
      _paintPolyline(image, points, thickness + 1.4, (alpha * 0.18).round());
    }
  }

  final fiberCount = isLight
      ? 6 + random.nextInt(5)
      : isLightPlus
          ? 9 + random.nextInt(6)
          : 14 + random.nextInt(10);
  for (var i = 0; i < fiberCount; i++) {
    final startX = random.nextDouble() * width;
    final startY = random.nextDouble() * height;
    final angle = random.nextDouble() * pi;
    final length = (isLight
            ? 24
            : isLightPlus
                ? 30
                : 40) +
        random.nextDouble() *
            (isLight
                ? 50
                : isLightPlus
                    ? 65
                    : 90);
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
              ? 0.55
              : isLightPlus
                  ? 0.72
                  : 0.9) +
          random.nextDouble(),
      (isLight
              ? 5
              : isLightPlus
                  ? 7
                  : 10) +
          random.nextInt(
            isLight
                ? 10
                : isLightPlus
                    ? 14
                    : 20,
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
      final localAlpha = (effectiveAlpha * falloff * falloff).round();
      if (localAlpha <= 0) continue;
      _blendWhite(image, x, y, localAlpha);
    }
  }
}

void _blendWhite(img.Image image, int x, int y, int alpha) {
  final pixel = image.getPixel(x, y);
  final existingAlpha = pixel.a.toInt();
  final outAlpha = max(existingAlpha, alpha.clamp(0, 255));
  image.setPixelRgba(x, y, 255, 255, 255, outAlpha);
}
