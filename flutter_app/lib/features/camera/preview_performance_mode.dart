enum PreviewPerformanceMode {
  lightweight,
  performance,
}

extension PreviewPerformanceModeX on PreviewPerformanceMode {
  String get storageValue => switch (this) {
        PreviewPerformanceMode.lightweight => 'lightweight',
        PreviewPerformanceMode.performance => 'performance',
      };

  String get resolutionTag => switch (this) {
        PreviewPerformanceMode.lightweight => '720p',
        PreviewPerformanceMode.performance => '1080p',
      };

  bool get isLightweight => this == PreviewPerformanceMode.lightweight;

  static PreviewPerformanceMode fromStorage(String? raw) {
    return switch (raw) {
      'performance' => PreviewPerformanceMode.performance,
      _ => PreviewPerformanceMode.lightweight,
    };
  }
}
