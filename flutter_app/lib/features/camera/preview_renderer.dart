// preview_renderer.dart
// Real-time preview rendering pipeline for GRD R camera.
// Applies: temperature shift, contrast, saturation, vignette, chromatic aberration,
// bloom, soft-focus, and lens distortion using Flutter CustomPainter + ColorFilter.
//
// Design: Darkroom Aesthetics — deep brown-black, amber highlights, film grain texture.

import 'package:flutter/material.dart';
import '../../models/camera_definition.dart';

enum SceneClass {
  balanced,
  indoor,
  outdoor,
  lowLight,
  backlit,
  highDynamic,
}

class DeviceColorProfile {
  static const String calibrationVersion = 'v3.2';
  final String id;
  final double temperatureOffset;
  final double tintOffset;
  final double contrastScale;
  final double saturationScale;
  final double colorBiasROffset;
  final double colorBiasGOffset;
  final double colorBiasBOffset;
  // Device-level calibration core (for native/dart unified pipeline).
  // Row-major 3x3 CCM: [m00,m01,m02,m10,m11,m12,m20,m21,m22]
  final List<double> ccm;
  final double whiteScaleR;
  final double whiteScaleG;
  final double whiteScaleB;
  final double gamma;

  const DeviceColorProfile({
    required this.id,
    this.temperatureOffset = 0.0,
    this.tintOffset = 0.0,
    this.contrastScale = 1.0,
    this.saturationScale = 1.0,
    this.colorBiasROffset = 0.0,
    this.colorBiasGOffset = 0.0,
    this.colorBiasBOffset = 0.0,
    this.ccm = const [1, 0, 0, 0, 1, 0, 0, 0, 1],
    this.whiteScaleR = 1.0,
    this.whiteScaleG = 1.0,
    this.whiteScaleB = 1.0,
    this.gamma = 2.2,
  });

  static const neutral = DeviceColorProfile(id: 'neutral');

  static DeviceColorProfile resolve({
    required String brand,
    required String model,
    required double sensorMp,
  }) {
    final b = brand.toLowerCase();
    final m = model.toLowerCase();
    if (b.contains('xiaomi') || b.contains('redmi') || b.contains('poco')) {
      return DeviceColorProfile(
        id: 'xiaomi_family',
        temperatureOffset: -5.0,
        tintOffset: -2.5,
        contrastScale: 1.02,
        saturationScale: 0.97,
        colorBiasROffset: -0.008,
        colorBiasGOffset: 0.003,
        colorBiasBOffset: 0.006,
        ccm: const [
          1.018,
          -0.014,
          -0.004,
          -0.008,
          1.012,
          -0.004,
          -0.010,
          -0.006,
          1.016
        ],
        whiteScaleR: 1.012,
        whiteScaleG: 1.000,
        whiteScaleB: 0.992,
        gamma: 2.24,
      );
    }
    if (b.contains('samsung')) {
      return DeviceColorProfile(
        id: 'samsung_family',
        temperatureOffset: 2.0,
        tintOffset: -0.8,
        contrastScale: 0.99,
        saturationScale: 0.98,
        colorBiasROffset: -0.003,
        colorBiasGOffset: 0.001,
        colorBiasBOffset: 0.002,
        ccm: const [
          1.010,
          -0.007,
          -0.003,
          -0.006,
          1.008,
          -0.002,
          -0.004,
          -0.004,
          1.012
        ],
        whiteScaleR: 1.006,
        whiteScaleG: 1.000,
        whiteScaleB: 0.996,
        gamma: 2.20,
      );
    }
    if (b.contains('vivo') || b.contains('oppo') || b.contains('oneplus')) {
      return DeviceColorProfile(
        id: 'bbk_family',
        temperatureOffset: -2.0,
        tintOffset: -1.0,
        contrastScale: 1.00,
        saturationScale: 0.98,
        colorBiasROffset: -0.004,
        colorBiasGOffset: 0.001,
        colorBiasBOffset: 0.002,
        ccm: const [
          1.012,
          -0.009,
          -0.003,
          -0.007,
          1.010,
          -0.003,
          -0.006,
          -0.003,
          1.012
        ],
        whiteScaleR: 1.008,
        whiteScaleG: 1.000,
        whiteScaleB: 0.995,
        gamma: 2.22,
      );
    }
    if (b.contains('huawei') || b.contains('honor')) {
      return DeviceColorProfile(
        id: 'huawei_family',
        temperatureOffset: 1.2,
        tintOffset: -0.6,
        contrastScale: 0.99,
        saturationScale: 0.99,
        ccm: const [
          1.008,
          -0.006,
          -0.002,
          -0.004,
          1.006,
          -0.002,
          -0.004,
          -0.002,
          1.009
        ],
        whiteScaleR: 1.004,
        whiteScaleG: 1.000,
        whiteScaleB: 0.998,
        gamma: 2.20,
      );
    }
    if (b.contains('apple') || m.contains('iphone')) {
      return DeviceColorProfile(
        id: 'apple_iphone',
        temperatureOffset: 0.6,
        tintOffset: 0.2,
        contrastScale: 1.0,
        saturationScale: 1.0,
        ccm: const [
          1.004,
          -0.003,
          -0.001,
          -0.002,
          1.003,
          -0.001,
          -0.002,
          -0.001,
          1.004
        ],
        whiteScaleR: 1.002,
        whiteScaleG: 1.000,
        whiteScaleB: 0.999,
        gamma: 2.18,
      );
    }
    if (sensorMp >= 150.0) {
      // 高频高像素传感器泛型补偿
      return DeviceColorProfile(
        id: 'generic_200mp',
        temperatureOffset: -2.0,
        tintOffset: -0.8,
        saturationScale: 0.98,
        colorBiasROffset: -0.004,
        colorBiasBOffset: 0.003,
        ccm: const [
          1.014,
          -0.010,
          -0.004,
          -0.007,
          1.010,
          -0.003,
          -0.008,
          -0.004,
          1.014
        ],
        whiteScaleR: 1.009,
        whiteScaleG: 1.000,
        whiteScaleB: 0.994,
        gamma: 2.24,
      );
    }
    return neutral;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PreviewRenderParams — all parameters needed for one frame render
// ─────────────────────────────────────────────────────────────────────────────

class PreviewRenderParams {
  final DefaultLook defaultLook;
  final FilterDefinition? activeFilter;
  final LensDefinition? activeLens;
  final double temperatureOffset; // user-adjusted, -100..100
  final double exposureOffset; // user-adjusted, -2.0..2.0
  final PreviewPolicy policy;
  final String wbMode;
  final int colorTempK;
  final bool isFrontCamera;
  final String runtimeDeviceBrand;
  final String runtimeDeviceModel;
  final String runtimeCameraId;
  final double runtimeSensorMp;

  const PreviewRenderParams({
    DefaultLook? defaultLook,
    this.activeFilter,
    this.activeLens,
    this.temperatureOffset = 0,
    this.exposureOffset = 0,
    PreviewPolicy? policy,
    this.wbMode = 'auto',
    this.colorTempK = 6300,
    this.isFrontCamera = false,
    this.runtimeDeviceBrand = '',
    this.runtimeDeviceModel = '',
    this.runtimeCameraId = '',
    this.runtimeSensorMp = 0,
  })  : defaultLook = defaultLook ??
            const DefaultLook(
              temperature: 0,
              contrast: 1.0,
              saturation: 1.0,
              vignette: 0,
              distortion: 0,
              chromaticAberration: 0,
              bloom: 0,
              flare: 0,
            ),
        policy = policy ??
            const PreviewPolicy(
              enableLut: false,
              enableTemperature: false,
              enableContrast: false,
              enableSaturation: false,
              enableVignette: false,
              enableLightLensEffect: false,
              enableGrain: false,
              enableBloom: false,
              enableHalation: false,
              enablePaperTexture: false,
              enableChromaticAberration: false,
              enableFrameComposite: false,
              enableWatermarkComposite: false,
            );

  DeviceColorProfile get _deviceProfile => DeviceColorProfile.resolve(
        brand: runtimeDeviceBrand,
        model: runtimeDeviceModel,
        sensorMp: runtimeSensorMp,
      );

  SceneClass get sceneClass {
    if (isFrontCamera) return SceneClass.indoor;
    if (exposureOffset >= 1.0) return SceneClass.lowLight;
    if (exposureOffset <= -0.9) return SceneClass.backlit;
    if (defaultLook.highlights <= -20 && defaultLook.shadows >= 20) {
      return SceneClass.highDynamic;
    }
    if (wbMode == 'incandescent' || colorTempK < 4300) {
      return SceneClass.indoor;
    }
    if (wbMode == 'daylight' || colorTempK > 6200) {
      return SceneClass.outdoor;
    }
    return SceneClass.balanced;
  }

  String get protectionMode {
    switch (sceneClass) {
      case SceneClass.lowLight:
        return 'noise_first';
      case SceneClass.backlit:
      case SceneClass.highDynamic:
        return 'skin_first';
      default:
        return 'balanced';
    }
  }

  String? get effectiveBaseLut {
    switch (sceneClass) {
      case SceneClass.lowLight:
        return defaultLook.baseLutNight ??
            defaultLook.baseLutIndoor ??
            defaultLook.baseLut;
      case SceneClass.indoor:
        return defaultLook.baseLutIndoor ??
            defaultLook.baseLutNight ??
            defaultLook.baseLut;
      case SceneClass.outdoor:
        return defaultLook.baseLutDaylight ?? defaultLook.baseLut;
      case SceneClass.backlit:
      case SceneClass.highDynamic:
      case SceneClass.balanced:
        return defaultLook.baseLut;
    }
  }

  // Effective vignette = defaultLook + lens override
  double get effectiveVignette {
    final base = defaultLook.vignette;
    final lens = activeLens?.vignette ?? 0;
    return (base + lens).clamp(0.0, 1.0);
  }

  double get effectiveChromaticAberration {
    final base = defaultLook.chromaticAberration;
    final lens = activeLens?.chromaticAberration ?? 0;
    return (base + lens).clamp(0.0, 0.1);
  }

  double get effectiveBloom {
    final base = defaultLook.bloom;
    final lens = activeLens?.bloom ?? 0;
    return (base + lens).clamp(0.0, 1.0);
  }

  double get effectiveHalation => defaultLook.halation.clamp(0.0, 1.0);

  double get effectiveSoftFocus {
    return (activeLens?.softFocus ?? 0).clamp(0.0, 1.0);
  }

  /// 真实镜头畸变：负值=桶形(barrel/fisheye)，正值=枕形(pincushion/tele)
  /// 来源：defaultLook.distortion + lens.distortion 叠加
  double get effectiveDistortion {
    final base = defaultLook.distortion;
    final lens = activeLens?.distortion ?? 0;
    return (base + lens).clamp(-1.0, 1.0);
  }

  double get effectiveContrast {
    final base = defaultLook.contrast;
    final filter = activeFilter?.contrast ?? 1.0;
    final lens =
        activeLens?.contrast ?? 0.0; // lens.contrast is additive offset
    final adapted = _sceneContrastScale(sceneClass);
    final gammaComp =
        ((2.2 / _deviceProfile.gamma) * 0.06 + 1.0).clamp(0.96, 1.04);
    return ((base * filter + lens) *
            _deviceProfile.contrastScale *
            adapted *
            gammaComp)
        .clamp(0.5, 2.0);
  }

  double get effectiveSaturation {
    final base = defaultLook.saturation;
    final filter = activeFilter?.saturation ?? 1.0;
    final lens =
        activeLens?.saturation ?? 0.0; // lens.saturation is additive offset
    final adapted = _sceneSaturationScale(sceneClass);
    return ((base * filter + lens) * _deviceProfile.saturationScale * adapted)
        .clamp(0.0, 2.0);
  }

  /// 镜头曝光偏移（叠加到 exposureOffset 上）
  double get effectiveLensExposure => activeLens?.exposure ?? 0.0;

  // Temperature: combine defaultLook + user offset
  // defaultLook.temperature is in Kelvin offset (-100 = cool, +100 = warm)
  double get effectiveTemperature {
    return (defaultLook.temperature +
            temperatureOffset +
            _deviceProfile.temperatureOffset +
            _sceneTemperatureOffset(sceneClass))
        .clamp(-100.0, 100.0);
  }

  double get effectiveTint =>
      (defaultLook.tint + _deviceProfile.tintOffset).clamp(-100.0, 100.0);
  double get effectiveHighlights =>
      (defaultLook.highlights + _sceneHighlightOffset(sceneClass))
          .clamp(-100.0, 100.0);
  double get effectiveShadows =>
      (defaultLook.shadows + _sceneShadowsOffset(sceneClass))
          .clamp(-100.0, 100.0);
  double get effectiveWhites =>
      (defaultLook.whites + _sceneWhitesOffset(sceneClass))
          .clamp(-100.0, 100.0);
  double get effectiveBlacks => defaultLook.blacks.clamp(-100.0, 100.0);
  double get effectiveClarity =>
      (defaultLook.clarity + _sceneClarityOffset(sceneClass))
          .clamp(-100.0, 100.0);
  double get effectiveVibrance =>
      (defaultLook.vibrance + _sceneVibranceOffset(sceneClass))
          .clamp(-100.0, 100.0);
  double get effectiveGrain =>
      (defaultLook.grain * _sceneGrainScale(sceneClass)).clamp(0.0, 1.0);
  double get effectiveColorBiasR => (defaultLook.colorBiasR +
          _deviceProfile.colorBiasROffset +
          _ccmBiasR() +
          (_deviceProfile.whiteScaleR - 1.0) * 0.40)
      .clamp(-1.0, 1.0);
  double get effectiveColorBiasG => (defaultLook.colorBiasG +
          _deviceProfile.colorBiasGOffset +
          _ccmBiasG() +
          (_deviceProfile.whiteScaleG - 1.0) * 0.40)
      .clamp(-1.0, 1.0);
  double get effectiveColorBiasB => (defaultLook.colorBiasB +
          _deviceProfile.colorBiasBOffset +
          _ccmBiasB() +
          (_deviceProfile.whiteScaleB - 1.0) * 0.40)
      .clamp(-1.0, 1.0);

  double _ccmBiasR() {
    final c = _deviceProfile.ccm;
    return ((c[0] - 1.0) * 0.25 + (c[1] + c[2]) * 0.5).clamp(-0.05, 0.05);
  }

  double _ccmBiasG() {
    final c = _deviceProfile.ccm;
    return ((c[4] - 1.0) * 0.25 + (c[3] + c[5]) * 0.5).clamp(-0.05, 0.05);
  }

  double _ccmBiasB() {
    final c = _deviceProfile.ccm;
    return ((c[8] - 1.0) * 0.25 + (c[6] + c[7]) * 0.5).clamp(-0.05, 0.05);
  }

  // ── 拍立得即时成像专属参数 getter ──────────────────────────────────────────────
  double get highlightRolloff =>
      (defaultLook.highlightRolloff + _sceneHighlightRolloffBoost(sceneClass))
          .clamp(0.0, 1.0);
  double get centerGain => defaultLook.centerGain.clamp(0.0, 0.2);
  double get edgeFalloff => defaultLook.edgeFalloff.clamp(0.0, 1.0);
  double get cornerWarmShift => defaultLook.cornerWarmShift.clamp(0.0, 5.0);
  double get skinHueProtect => defaultLook.skinHueProtect ? 1.0 : 0.0;
  double get chemicalIrregularity =>
      defaultLook.chemicalIrregularity.clamp(0.0, 0.1);

  /// FIX: noiseAmount 现已添加到 DefaultLook
  double get noiseAmount => defaultLook.noiseAmount.clamp(0.0, 1.0);
  double get skinSatProtect =>
      (defaultLook.skinSatProtect - _dynamicSkinSatDelta()).clamp(0.0, 1.0);
  double get skinLumaSoften =>
      (defaultLook.skinLumaSoften + _dynamicSkinLumaDelta()).clamp(0.0, 0.2);
  double get skinRedLimit =>
      (defaultLook.skinRedLimit - _dynamicSkinRedLimitDelta()).clamp(0.9, 1.2);

  double _sceneHighlightRolloffBoost(SceneClass scene) {
    switch (scene) {
      case SceneClass.backlit:
        return 0.18;
      case SceneClass.highDynamic:
        return 0.16;
      case SceneClass.lowLight:
        return 0.10;
      case SceneClass.indoor:
        return 0.06;
      case SceneClass.outdoor:
        return 0.04;
      case SceneClass.balanced:
        return 0.0;
    }
  }

  double _sceneHighlightOffset(SceneClass scene) {
    switch (scene) {
      case SceneClass.backlit:
        return -20.0;
      case SceneClass.highDynamic:
        return -16.0;
      case SceneClass.lowLight:
        return -8.0;
      case SceneClass.indoor:
        return -6.0;
      case SceneClass.outdoor:
        return -2.0;
      case SceneClass.balanced:
        return 0.0;
    }
  }

  double _sceneShadowsOffset(SceneClass scene) {
    switch (scene) {
      case SceneClass.backlit:
        return 18.0;
      case SceneClass.highDynamic:
        return 16.0;
      case SceneClass.lowLight:
        return 12.0;
      case SceneClass.indoor:
        return 8.0;
      case SceneClass.outdoor:
        return 3.0;
      case SceneClass.balanced:
        return 0.0;
    }
  }

  double _sceneWhitesOffset(SceneClass scene) {
    switch (scene) {
      case SceneClass.backlit:
        return -16.0;
      case SceneClass.highDynamic:
        return -12.0;
      case SceneClass.lowLight:
        return -8.0;
      case SceneClass.indoor:
        return -5.0;
      case SceneClass.outdoor:
        return -2.0;
      case SceneClass.balanced:
        return 0.0;
    }
  }

  double _sceneContrastScale(SceneClass scene) {
    switch (scene) {
      case SceneClass.lowLight:
        return 0.98;
      case SceneClass.backlit:
      case SceneClass.highDynamic:
        return 0.96;
      default:
        return 1.0;
    }
  }

  double _sceneSaturationScale(SceneClass scene) {
    switch (scene) {
      case SceneClass.indoor:
        return 0.97;
      case SceneClass.lowLight:
        return 0.93;
      case SceneClass.outdoor:
        return 1.01;
      default:
        return 1.0;
    }
  }

  double _sceneClarityOffset(SceneClass scene) {
    switch (scene) {
      case SceneClass.lowLight:
        return -8.0;
      case SceneClass.indoor:
        return -3.0;
      default:
        return 0.0;
    }
  }

  double _sceneVibranceOffset(SceneClass scene) {
    switch (scene) {
      case SceneClass.lowLight:
        return -10.0;
      case SceneClass.indoor:
        return -4.0;
      default:
        return 0.0;
    }
  }

  double _sceneGrainScale(SceneClass scene) {
    switch (scene) {
      case SceneClass.lowLight:
        return 0.68;
      case SceneClass.indoor:
        return 0.85;
      default:
        return 1.0;
    }
  }

  double _sceneLutStrengthScale(SceneClass scene) {
    switch (scene) {
      case SceneClass.lowLight:
        return 0.92;
      case SceneClass.backlit:
      case SceneClass.highDynamic:
        return 0.94;
      case SceneClass.indoor:
        return 0.97;
      case SceneClass.outdoor:
        return 1.0;
      case SceneClass.balanced:
        return 1.0;
    }
  }

  double get effectiveLutStrength {
    final base = defaultLook.lutStrength.clamp(0.0, 1.0);
    final sceneScale = _sceneLutStrengthScale(sceneClass);
    final frontScale = isFrontCamera ? 0.97 : 1.0;
    return (base * sceneScale * frontScale).clamp(0.55, 1.0);
  }

  double _sceneTemperatureOffset(SceneClass scene) {
    switch (scene) {
      case SceneClass.lowLight:
        return -2.0;
      case SceneClass.outdoor:
        return 1.0;
      default:
        return 0.0;
    }
  }

  double _dynamicSkinSatDelta() {
    if (skinHueProtect < 0.5) return 0.0;
    final warmWeight = ((5200 - colorTempK) / 2600.0).clamp(0.0, 1.0);
    final lowLightWeight = (exposureOffset / 1.4).clamp(0.0, 1.0);
    final sceneBoost = switch (sceneClass) {
      SceneClass.backlit || SceneClass.highDynamic => 0.05,
      SceneClass.lowLight => 0.03,
      _ => 0.0,
    };
    return 0.10 * warmWeight + 0.06 * lowLightWeight + sceneBoost;
  }

  double _dynamicSkinLumaDelta() {
    if (skinHueProtect < 0.5) return 0.0;
    final lowLightWeight = (exposureOffset / 1.5).clamp(0.0, 1.0);
    final sceneBoost = switch (sceneClass) {
      SceneClass.backlit || SceneClass.highDynamic => 0.02,
      SceneClass.lowLight => 0.03,
      _ => 0.0,
    };
    return 0.03 * lowLightWeight + sceneBoost;
  }

  double _dynamicSkinRedLimitDelta() {
    if (skinHueProtect < 0.5) return 0.0;
    final warmWeight = ((5200 - colorTempK) / 2600.0).clamp(0.0, 1.0);
    final dynamicWeight =
        sceneClass == SceneClass.backlit || sceneClass == SceneClass.highDynamic
            ? 1.0
            : 0.0;
    final lowLightBoost = sceneClass == SceneClass.lowLight ? 0.02 : 0.0;
    return 0.03 * warmWeight + 0.02 * dynamicWeight + lowLightBoost;
  }

  double get paperTexture => defaultLook.paperTexture.clamp(0.0, 1.0);
  double get developmentSoftness =>
      defaultLook.developmentSoftness.clamp(0.0, 1.0);

  // 化学不规则感参数
  double get irregUvScale => defaultLook.irregUvScale;
  double get irregFreq1 => defaultLook.irregFreq1;
  double get irregFreq2 => defaultLook.irregFreq2;
  double get irregWeight1 => defaultLook.irregWeight1;
  double get irregWeight2 => defaultLook.irregWeight2;

  // 相纸纹理参数
  double get paperUvScale1 => defaultLook.paperUvScale1;
  double get paperUvScale2 => defaultLook.paperUvScale2;
  double get paperWeight1 => defaultLook.paperWeight1;
  double get paperWeight2 => defaultLook.paperWeight2;

  Map<String, dynamic> toJson() => {
        'contrast': effectiveContrast,
        'saturation': effectiveSaturation,
        'temperatureShift': effectiveTemperature,
        'tintShift': effectiveTint,
        'highlights': effectiveHighlights,
        'shadows': effectiveShadows,
        'whites': effectiveWhites,
        'blacks': effectiveBlacks,
        'clarity': effectiveClarity,
        'vibrance': effectiveVibrance,
        'colorBiasR': effectiveColorBiasR,
        'colorBiasG': effectiveColorBiasG,
        'colorBiasB': effectiveColorBiasB,
        'grainAmount': effectiveGrain,
        'noiseAmount': noiseAmount,
        'vignetteAmount': effectiveVignette,
        'chromaticAberration': effectiveChromaticAberration,
        'bloomAmount': effectiveBloom,
        'highlightRolloff': highlightRolloff,
        'paperTexture': paperTexture,
        'edgeFalloff': edgeFalloff,
        'cornerWarmShift': cornerWarmShift,
        'centerGain': centerGain,
        'developmentSoftness': developmentSoftness,
        'chemicalIrregularity': chemicalIrregularity,
        'skinHueProtect': skinHueProtect,
        'skinSatProtect': skinSatProtect,
        'skinLumaSoften': skinLumaSoften,
        'skinRedLimit': skinRedLimit,

        'irregUvScale': irregUvScale,
        'irregFreq1': irregFreq1,
        'irregFreq2': irregFreq2,
        'irregWeight1': irregWeight1,
        'irregWeight2': irregWeight2,

        'paperUvScale1': paperUvScale1,
        'paperUvScale2': paperUvScale2,
        'paperWeight1': paperWeight1,
        'paperWeight2': paperWeight2,
        if (effectiveBaseLut?.isNotEmpty == true) 'baseLut': effectiveBaseLut,
        if (effectiveBaseLut?.isNotEmpty == true)
          'lutStrength': effectiveLutStrength,
        'highlightRolloff2': defaultLook.highlightRolloff2.clamp(0.0, 1.0),
        'toneCurveStrength': defaultLook.toneCurveStrength.clamp(0.0, 1.0),
        'halationAmount': effectiveHalation,
        'lensVignette': effectiveVignette,
        'exposureOffset': exposureOffset + effectiveLensExposure,
        'softFocus': effectiveSoftFocus,
        'distortion': effectiveDistortion,
        'grainSize': defaultLook.grainSize.clamp(0.5, 3.0),
        'luminanceNoise': defaultLook.luminanceNoise.clamp(0.0, 0.5),
        'chromaNoise': defaultLook.chromaNoise.clamp(0.0, 0.5),
        'exposureVariation': defaultLook.exposureVariation.clamp(0.0, 0.1),
        // ── 新增：Fade / Split Toning / Light Leak ──
        'fadeAmount': defaultLook.fadeAmount.clamp(0.0, 0.5),
        'fade': defaultLook.fadeAmount.clamp(0.0, 0.5),
        'shadowTintR': defaultLook.shadowTintR.clamp(-0.2, 0.2),
        'shadowTintG': defaultLook.shadowTintG.clamp(-0.2, 0.2),
        'shadowTintB': defaultLook.shadowTintB.clamp(-0.2, 0.2),
        'highlightTintR': defaultLook.highlightTintR.clamp(-0.2, 0.2),
        'highlightTintG': defaultLook.highlightTintG.clamp(-0.2, 0.2),
        'highlightTintB': defaultLook.highlightTintB.clamp(-0.2, 0.2),
        'splitToneBalance': defaultLook.splitToneBalance.clamp(0.0, 1.0),
        'lightLeakAmount': defaultLook.lightLeakAmount.clamp(0.0, 1.0),
        // runtime calibration/debug context
        'sceneClass': sceneClass.name,
        'protectionMode': protectionMode,
        'deviceProfileId': _deviceProfile.id,
        'runtimeCameraId': runtimeCameraId,
        'runtimeSensorMp': runtimeSensorMp,
        'calibrationVersion': DeviceColorProfile.calibrationVersion,
        'deviceGamma': _deviceProfile.gamma,
        'deviceWhiteScaleR': _deviceProfile.whiteScaleR,
        'deviceWhiteScaleG': _deviceProfile.whiteScaleG,
        'deviceWhiteScaleB': _deviceProfile.whiteScaleB,
        'deviceCcm00': _deviceProfile.ccm[0],
        'deviceCcm01': _deviceProfile.ccm[1],
        'deviceCcm02': _deviceProfile.ccm[2],
        'deviceCcm10': _deviceProfile.ccm[3],
        'deviceCcm11': _deviceProfile.ccm[4],
        'deviceCcm12': _deviceProfile.ccm[5],
        'deviceCcm20': _deviceProfile.ccm[6],
        'deviceCcm21': _deviceProfile.ccm[7],
        'deviceCcm22': _deviceProfile.ccm[8],
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// PreviewFilterWidget — wraps camera Texture with render effects
// ─────────────────────────────────────────────────────────────────────────────

class PreviewFilterWidget extends StatelessWidget {
  final int textureId;
  final PreviewRenderParams params;

  /// 目标比例（用户选择，如 1:1/3:4/9:16）——只用于取景框容器大小计算
  final double aspectRatio;

  /// 相机传感器实际输出比例（固定为 3/4）——用于 cover 缩放计算
  static const double _kSensorAspect = 3.0 / 4.0; // CameraX 默认输出 4:3

  const PreviewFilterWidget({
    super.key,
    required this.textureId,
    required this.params,
    this.aspectRatio = 3 / 4,
  });

  @override
  Widget build(BuildContext context) {
    // 预览始终充满容器（BoxFit.cover 效果）
    // cover 计算基于传感器实际比例（_kSensorAspect = 3/4）
    // 而不是目标比例（aspectRatio），避免 1:1 等比例切换时画面被拉伸
    return LayoutBuilder(
      builder: (context, constraints) {
        final containerW = constraints.maxWidth;
        final containerH = constraints.maxHeight;
        // 使用传感器实际比例计算 cover
        const sensorAspect = _kSensorAspect;
        // BoxFit.cover：选择让内容充满容器的最小缩放
        final containerAspect = containerW / containerH;
        double overflowW, overflowH;
        if (containerAspect >= sensorAspect) {
          // 容器更宽 → 宽度铺满，高度可能超出
          overflowW = containerW;
          overflowH = containerW / sensorAspect;
        } else {
          // 容器更高 → 高度铺满，宽度可能超出
          overflowH = containerH;
          overflowW = containerH * sensorAspect;
        }
        return ClipRect(
          child: OverflowBox(
            maxWidth: overflowW,
            maxHeight: overflowH,
            // Phase 2 重构：所有渲染特效已下沉到 Native GPU Shader
            // Flutter 层仅显示纯 Texture，不再做像素级渲染
            // 色彩调整、色差、Bloom、Halation、相纸纹理、暗角等全部由 Native Shader 处理
            child: Texture(textureId: textureId),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// WatermarkOverlay — renders date/time watermark on preview
// ─────────────────────────────────────────────────────────────────────────────

class WatermarkOverlay extends StatelessWidget {
  final WatermarkPreset? preset;

  const WatermarkOverlay({super.key, this.preset});

  @override
  Widget build(BuildContext context) {
    if (preset == null || preset!.isNone) return const SizedBox.shrink();

    final color = _parseColor(preset!.color ?? '#FF8A3D');
    final now = DateTime.now();
    final dateStr =
        '${now.month} ${now.day.toString().padLeft(2, ' ')} \'${now.year.toString().substring(2)}';

    return Positioned(
      right: 16,
      bottom: 16,
      child: Text(
        dateStr,
        style: TextStyle(
          color: color,
          fontSize: preset!.fontSize ?? 14,
          fontFamily: 'monospace',
          fontWeight: FontWeight.bold,
          shadows: [
            Shadow(
              color: Colors.black.withAlpha(120),
              blurRadius: 4,
              offset: const Offset(1, 1),
            ),
          ],
        ),
      ),
    );
  }

  Color _parseColor(String hex) {
    try {
      final h = hex.replaceAll('#', '');
      return Color(int.parse('FF$h', radix: 16));
    } catch (_) {
      return const Color(0xFFFF8A3D);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// GridOverlay — rule-of-thirds grid
// ─────────────────────────────────────────────────────────────────────────────

class GridOverlay extends StatelessWidget {
  const GridOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _GridPainter(),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withAlpha(60)
      ..strokeWidth = 0.5;

    // Vertical lines at 1/3 and 2/3
    canvas.drawLine(
      Offset(size.width / 3, 0),
      Offset(size.width / 3, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(size.width * 2 / 3, 0),
      Offset(size.width * 2 / 3, size.height),
      paint,
    );

    // Horizontal lines at 1/3 and 2/3
    canvas.drawLine(
      Offset(0, size.height / 3),
      Offset(size.width, size.height / 3),
      paint,
    );
    canvas.drawLine(
      Offset(0, size.height * 2 / 3),
      Offset(size.width, size.height * 2 / 3),
      paint,
    );
  }

  @override
  bool shouldRepaint(_GridPainter old) => false;
}
