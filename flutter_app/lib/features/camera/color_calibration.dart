import 'dart:math' as math;

class RgbSample {
  final String id;
  final double r;
  final double g;
  final double b;

  const RgbSample({
    required this.id,
    required this.r,
    required this.g,
    required this.b,
  });

  RgbSample normalized() => RgbSample(
        id: id,
        r: r.clamp(0.0, 255.0) / 255.0,
        g: g.clamp(0.0, 255.0) / 255.0,
        b: b.clamp(0.0, 255.0) / 255.0,
      );
}

class ColorCalibrationReport {
  final double deltaEAvg;
  final double deltaEMax;
  final double skinDeltaEAvg;
  final double wbBiasAvg;
  final int count;

  const ColorCalibrationReport({
    required this.deltaEAvg,
    required this.deltaEMax,
    required this.skinDeltaEAvg,
    required this.wbBiasAvg,
    required this.count,
  });

  Map<String, dynamic> toJson() => {
        'count': count,
        'deltaEAvg': deltaEAvg,
        'deltaEMax': deltaEMax,
        'skinDeltaEAvg': skinDeltaEAvg,
        'wbBiasAvg': wbBiasAvg,
      };
}

class ColorCalibration {
  static const Set<String> _defaultSkinPatchIds = {
    'patch11',
    'patch12',
    'patch13',
    'patch14',
    'patch15',
    'patch16',
  };

  static ColorCalibrationReport evaluate({
    required List<RgbSample> reference,
    required List<RgbSample> measured,
    Set<String>? skinPatchIds,
  }) {
    final measuredMap = <String, RgbSample>{
      for (final s in measured) s.id: s,
    };
    final skinIds = skinPatchIds ?? _defaultSkinPatchIds;

    double sumDe = 0.0;
    double maxDe = 0.0;
    double skinSum = 0.0;
    int skinCount = 0;
    double wbBias = 0.0;
    int wbCount = 0;
    int count = 0;

    for (final ref in reference) {
      final m = measuredMap[ref.id];
      if (m == null) continue;
      final de = deltaE76(ref, m);
      sumDe += de;
      maxDe = math.max(maxDe, de);
      count += 1;
      if (skinIds.contains(ref.id)) {
        skinSum += de;
        skinCount += 1;
      }
      if (_isGrayPatch(ref.id)) {
        final rn = ref.normalized();
        final mn = m.normalized();
        wbBias += ((mn.r - mn.g) - (rn.r - rn.g)).abs() +
            ((mn.b - mn.g) - (rn.b - rn.g)).abs();
        wbCount += 1;
      }
    }

    return ColorCalibrationReport(
      deltaEAvg: count == 0 ? 0.0 : sumDe / count,
      deltaEMax: maxDe,
      skinDeltaEAvg: skinCount == 0 ? 0.0 : skinSum / skinCount,
      wbBiasAvg: wbCount == 0 ? 0.0 : wbBias / wbCount,
      count: count,
    );
  }

  static bool _isGrayPatch(String id) {
    final lower = id.toLowerCase();
    return lower.contains('gray') ||
        lower.contains('grey') ||
        lower.contains('patch19') ||
        lower.contains('patch20') ||
        lower.contains('patch21') ||
        lower.contains('patch22') ||
        lower.contains('patch23') ||
        lower.contains('patch24');
  }

  static double deltaE76(RgbSample a, RgbSample b) {
    final la = _rgbToLab(a.normalized());
    final lb = _rgbToLab(b.normalized());
    final dl = la[0] - lb[0];
    final da = la[1] - lb[1];
    final db = la[2] - lb[2];
    return math.sqrt(dl * dl + da * da + db * db);
  }

  static List<double> _rgbToLab(RgbSample rgb) {
    final xyz = _rgbToXyz(rgb);
    return _xyzToLab(xyz[0], xyz[1], xyz[2]);
  }

  static List<double> _rgbToXyz(RgbSample rgb) {
    double pivot(double c) {
      if (c <= 0.04045) return c / 12.92;
      return math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    }

    final r = pivot(rgb.r);
    final g = pivot(rgb.g);
    final b = pivot(rgb.b);
    final x = r * 0.4124 + g * 0.3576 + b * 0.1805;
    final y = r * 0.2126 + g * 0.7152 + b * 0.0722;
    final z = r * 0.0193 + g * 0.1192 + b * 0.9505;
    return [x, y, z];
  }

  static List<double> _xyzToLab(double x, double y, double z) {
    // D65
    const xn = 0.95047;
    const yn = 1.0;
    const zn = 1.08883;

    double f(double t) {
      const eps = 216.0 / 24389.0;
      const kappa = 24389.0 / 27.0;
      if (t > eps) return math.pow(t, 1.0 / 3.0).toDouble();
      return (kappa * t + 16.0) / 116.0;
    }

    final fx = f(x / xn);
    final fy = f(y / yn);
    final fz = f(z / zn);
    final l = 116.0 * fy - 16.0;
    final a = 500.0 * (fx - fy);
    final b = 200.0 * (fy - fz);
    return [l, a, b];
  }
}
