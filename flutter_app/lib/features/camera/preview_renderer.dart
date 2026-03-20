// preview_renderer.dart
// Real-time preview rendering pipeline for GRD R camera.
// Applies: temperature shift, contrast, saturation, vignette, chromatic aberration,
// bloom, soft-focus, and lens distortion using Flutter CustomPainter + ColorFilter.
//
// Design: Darkroom Aesthetics — deep brown-black, amber highlights, film grain texture.

import 'package:flutter/material.dart';
import '../../models/camera_definition.dart';
import 'device_calibration_profiles.dart';
import 'render_style_mode.dart';
import 'preview_performance_mode.dart';

enum SceneClass {
  balanced,
  indoor,
  outdoor,
  lowLight,
  backlit,
  highDynamic,
}

enum CalibrationScene {
  balanced,
  daylight,
  indoorWarm,
  backlit,
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

  factory DeviceColorProfile.fromExactProfile(
    ExactDeviceCalibrationProfile exact,
    SceneCalibrationDelta sceneDelta,
  ) {
    return DeviceColorProfile(
      id: 'exact:${exact.brand}/${exact.model}/${exact.runtimeCameraId.isEmpty ? "default" : exact.runtimeCameraId}',
      temperatureOffset: exact.temperatureOffset + sceneDelta.temperatureOffset,
      tintOffset: exact.tintOffset + sceneDelta.tintOffset,
      contrastScale: exact.contrastScale * sceneDelta.contrastScale,
      saturationScale: exact.saturationScale * sceneDelta.saturationScale,
      colorBiasROffset: exact.colorBiasROffset + sceneDelta.colorBiasROffset,
      colorBiasGOffset: exact.colorBiasGOffset + sceneDelta.colorBiasGOffset,
      colorBiasBOffset: exact.colorBiasBOffset + sceneDelta.colorBiasBOffset,
      ccm: exact.ccm,
      whiteScaleR: exact.whiteScaleR,
      whiteScaleG: exact.whiteScaleG,
      whiteScaleB: exact.whiteScaleB,
      gamma: exact.gamma,
    );
  }

  factory DeviceColorProfile.fromFamilyProfile(
    DeviceFamilyCalibrationProfile family,
  ) {
    return DeviceColorProfile(
      id: family.id,
      temperatureOffset: family.temperatureOffset,
      tintOffset: family.tintOffset,
      contrastScale: family.contrastScale,
      saturationScale: family.saturationScale,
      colorBiasROffset: family.colorBiasROffset,
      colorBiasGOffset: family.colorBiasGOffset,
      colorBiasBOffset: family.colorBiasBOffset,
      ccm: family.ccm,
      whiteScaleR: family.whiteScaleR,
      whiteScaleG: family.whiteScaleG,
      whiteScaleB: family.whiteScaleB,
      gamma: family.gamma,
    );
  }

  static DeviceColorProfile resolve({
    required String brand,
    required String model,
    required String cameraId,
    required String runtimeCameraId,
    required double sensorMp,
    required CalibrationScene calibrationScene,
  }) {
    final fingerprint = DeviceFingerprint.normalized(
      brand: brand,
      model: model,
      cameraId: cameraId,
      runtimeCameraId: runtimeCameraId,
      sensorMp: sensorMp,
    );

    for (final exact in kLocalExactDeviceCalibrationProfiles) {
      if (!exact.matches(fingerprint)) continue;
      final sceneDelta = switch (calibrationScene) {
        CalibrationScene.daylight => exact.daylight,
        CalibrationScene.indoorWarm => exact.indoor,
        CalibrationScene.backlit => exact.backlit,
        CalibrationScene.balanced => const SceneCalibrationDelta(),
      };
      return DeviceColorProfile.fromExactProfile(exact, sceneDelta);
    }

    for (final family in kDeviceFamilyCalibrationProfiles) {
      if (family.matches(fingerprint)) {
        return DeviceColorProfile.fromFamilyProfile(family);
      }
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
  final double beautyStrength; // user-adjusted, 0.0..1.0
  final PreviewPolicy policy;
  final String wbMode;
  final int colorTempK;
  final bool isFrontCamera;
  final String cameraId;
  final String runtimeDeviceBrand;
  final String runtimeDeviceModel;
  final String runtimeCameraId;
  final double runtimeSensorMp;
  final double rtLightIndex;
  final double rtIso;
  final double rtExposureMs;
  final double rtLuma;
  final RenderStyleMode renderStyleMode;

  const PreviewRenderParams({
    DefaultLook? defaultLook,
    this.activeFilter,
    this.activeLens,
    this.temperatureOffset = 0,
    this.exposureOffset = 0,
    this.beautyStrength = 0,
    PreviewPolicy? policy,
    this.wbMode = 'auto',
    this.colorTempK = 6300,
    this.isFrontCamera = false,
    this.cameraId = '',
    this.runtimeDeviceBrand = '',
    this.runtimeDeviceModel = '',
    this.runtimeCameraId = '',
    this.runtimeSensorMp = 0,
    this.rtLightIndex = -1.0,
    this.rtIso = -1.0,
    this.rtExposureMs = -1.0,
    this.rtLuma = -1.0,
    this.renderStyleMode = RenderStyleMode.replica,
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
        cameraId: cameraId,
        runtimeCameraId: runtimeCameraId,
        sensorMp: runtimeSensorMp,
        calibrationScene: calibrationScene,
      );

  CalibrationScene get calibrationScene {
    return switch (sceneClass) {
      SceneClass.outdoor => CalibrationScene.daylight,
      SceneClass.indoor => CalibrationScene.indoorWarm,
      SceneClass.backlit || SceneClass.highDynamic => CalibrationScene.backlit,
      _ => CalibrationScene.balanced,
    };
  }

  double get _normalizedRtLuma {
    if (rtLuma < 0) return rtLuma;
    if (rtLuma > 1.5) return (rtLuma / 255.0).clamp(0.0, 1.0);
    return rtLuma.clamp(0.0, 1.0);
  }

  SceneClass get sceneClass {
    if (isFrontCamera) return SceneClass.indoor;
    final hasRealtime = rtLightIndex >= 0 || rtIso > 0 || rtExposureMs > 0;
    final rtLumaNorm = _normalizedRtLuma;

    if (hasRealtime) {
      final realtimeLowLight = rtLightIndex >= 4.2 ||
          (rtIso >= 800 && rtExposureMs >= 20) ||
          (rtIso >= 1200 && rtExposureMs >= 12);
      if (realtimeLowLight || exposureOffset >= 1.0) return SceneClass.lowLight;

      // 强逆光：亮场景 + 低 ISO/短曝光 + 预览 EV 明显往负方向补偿
      final realtimeBacklit = rtLumaNorm >= 0.66 &&
          rtIso > 0 &&
          rtIso <= 320 &&
          rtExposureMs > 0 &&
          rtExposureMs <= 10;
      if (exposureOffset <= -0.75 || realtimeBacklit) return SceneClass.backlit;

      final realtimeHighDynamic = rtLumaNorm >= 0.78 &&
          rtIso > 0 &&
          rtIso <= 260 &&
          rtExposureMs > 0 &&
          rtExposureMs <= 8;
      if (realtimeHighDynamic ||
          (defaultLook.highlights <= -20 && defaultLook.shadows >= 20)) {
        return SceneClass.highDynamic;
      }

      final likelyIndoorByRealtime =
          rtLightIndex >= 3.1 || (rtLightIndex > 2.2 && colorTempK < 5200);
      if (wbMode == 'incandescent' ||
          colorTempK < 4300 ||
          likelyIndoorByRealtime) {
        return SceneClass.indoor;
      }

      final likelyOutdoorByRealtime =
          rtLightIndex > 0 && rtLightIndex <= 2.1 && colorTempK >= 5600;
      if (likelyOutdoorByRealtime ||
          (wbMode == 'daylight' && colorTempK > 6200)) {
        return SceneClass.outdoor;
      }
      return SceneClass.balanced;
    }

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
    if (renderStyleMode == RenderStyleMode.replica) {
      return defaultLook.baseLut;
    }
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
    final filter = activeFilter?.vignette ?? 0;
    final lens = activeLens?.vignette ?? 0;
    return (base + filter + lens).clamp(0.0, 1.0);
  }

  double get effectiveChromaticAberration {
    final base = defaultLook.chromaticAberration;
    final lens = activeLens?.chromaticAberration ?? 0;
    return (base + lens).clamp(0.0, 0.1);
  }

  double get effectiveBloom {
    final base = defaultLook.bloom;
    final lens = activeLens?.bloom ?? 0;
    final sceneScale = switch (sceneClass) {
      SceneClass.lowLight => 0.52,
      SceneClass.backlit || SceneClass.highDynamic => 0.44,
      SceneClass.indoor => 0.78,
      _ => 1.0,
    };
    return ((base + lens) * defaultLook.bloomResponse * sceneScale)
        .clamp(0.0, 1.0);
  }

  double get effectiveHalation {
    final filterHalation = activeFilter?.halation ?? 0.0;
    final sceneScale = switch (sceneClass) {
      SceneClass.lowLight => 0.56,
      SceneClass.backlit || SceneClass.highDynamic => 0.48,
      SceneClass.indoor => 0.82,
      _ => 1.0,
    };
    return ((defaultLook.halation + filterHalation) *
            defaultLook.halationResponse *
            sceneScale)
        .clamp(0.0, 1.0);
  }

  double get effectiveBeautyStrength {
    final cameraWeight = isFrontCamera ? 1.35 : 0.72;
    return (beautyStrength * cameraWeight).clamp(0.0, 1.0);
  }

  double get effectiveSoftFocus {
    return ((activeLens?.softFocus ?? 0) + effectiveBeautyStrength * 0.24)
        .clamp(0.0, 1.0);
  }

  /// 真实镜头畸变：负值=桶形(barrel/fisheye)，正值=枕形(pincushion/tele)
  /// 来源：defaultLook.distortion + lens.distortion 叠加
  double get effectiveDistortion {
    final base = defaultLook.distortion;
    final lens = activeLens?.distortion ?? 0;
    return (base + lens).clamp(-1.0, 1.0);
  }

  bool get effectiveFisheyeMode =>
      activeLens?.fisheyeMode ?? cameraId.toLowerCase().contains('fisheye');

  double get effectiveContrast {
    final base = defaultLook.contrast;
    final filter = activeFilter?.contrast ?? 1.0;
    final lens =
        activeLens?.contrast ?? 0.0; // lens.contrast is additive offset
    final adapted = _auditedSceneContrastScale(sceneClass);
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
    final adapted = _auditedSceneSaturationScale(sceneClass);
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
            _auditedSceneTemperatureOffset(sceneClass) * _sceneAdaptiveMix)
        .clamp(-100.0, 100.0);
  }

  double get effectiveTint =>
      (defaultLook.tint + _deviceProfile.tintOffset).clamp(-100.0, 100.0);
  double get effectiveHighlights => (defaultLook.highlights +
          _auditedSceneHighlightOffset(sceneClass) *
              defaultLook.sceneHighlightResponse *
              _exposureProtectionMix)
      .clamp(-100.0, 100.0);
  double get effectiveShadows => (defaultLook.shadows +
          _auditedSceneShadowsOffset(sceneClass) *
              defaultLook.sceneShadowResponse *
              _exposureProtectionMix)
      .clamp(-100.0, 100.0);
  double get effectiveWhites => (defaultLook.whites +
          _auditedSceneWhitesOffset(sceneClass) *
              defaultLook.sceneWhitesResponse *
              _exposureProtectionMix)
      .clamp(-100.0, 100.0);
  double get effectiveBlacks => defaultLook.blacks.clamp(-100.0, 100.0);
  double get effectiveClarity => (defaultLook.clarity +
          _auditedSceneClarityOffset(sceneClass) * _sceneAdaptiveMix -
          effectiveBeautyStrength * 22.0)
      .clamp(-100.0, 100.0);
  double get effectiveVibrance => (defaultLook.vibrance +
          _auditedSceneVibranceOffset(sceneClass) * _sceneAdaptiveMix)
      .clamp(-100.0, 100.0);
  double get effectiveGrain =>
      ((defaultLook.grain + _filterGrainAmount(activeFilter?.grain)) *
              _auditedSceneGrainScale(sceneClass))
          .clamp(0.0, 1.0);
  double get effectiveGrainSize {
    final filterSize = activeFilter?.grainSize ?? defaultLook.grainSize;
    return filterSize.clamp(0.5, 3.0);
  }

  double get effectiveSharpen {
    final filterDelta = (activeFilter?.sharpness ?? 1.0) - 1.0;
    return (defaultLook.sharpen +
            filterDelta * 0.18 -
            effectiveBeautyStrength * 0.36)
        .clamp(0.0, 2.0);
  }

  double get effectiveSharpness => (defaultLook.sharpness *
          (activeFilter?.sharpness ?? 1.0) *
          (1.0 - effectiveBeautyStrength * 0.26))
      .clamp(0.5, 2.0);
  double get effectiveDehaze => (defaultLook.dehaze / 10.0).clamp(0.0, 1.0);
  double get highlightWarmAmount =>
      defaultLook.highlightWarmAmount.clamp(0.0, 1.0);
  double get topBottomBias => defaultLook.topBottomBias.clamp(-1.0, 1.0);
  double get leftRightBias => defaultLook.leftRightBias.clamp(-1.0, 1.0);
  bool get hasCustomToneCurve => defaultLook.toneCurvePoints.isNotEmpty;
  List<List<double>> get toneCurvePoints => defaultLook.toneCurvePoints;
  bool get hasBwMixer =>
      defaultLook.bwChannelR != 0 ||
      defaultLook.bwChannelG != 0 ||
      defaultLook.bwChannelB != 0;
  List<double> get bwChannelMixer {
    final sum = defaultLook.bwChannelR +
        defaultLook.bwChannelG +
        defaultLook.bwChannelB;
    if (sum <= 0.0001) {
      return const [0.299, 0.587, 0.114];
    }
    return [
      defaultLook.bwChannelR / sum,
      defaultLook.bwChannelG / sum,
      defaultLook.bwChannelB / sum,
    ];
  }

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
  double get highlightRolloff => ((defaultLook.highlightRolloff +
              _sceneHighlightRolloffBoost(sceneClass) *
                  _exposureProtectionMix) *
          defaultLook.highlightRolloffResponse)
      .clamp(0.0, 1.0);

  double get effectiveHighlightRolloff2 {
    final sceneScale = switch (sceneClass) {
      SceneClass.lowLight => 0.84,
      SceneClass.backlit || SceneClass.highDynamic => 0.76,
      _ => 1.0,
    };
    return (defaultLook.highlightRolloff2 *
            defaultLook.highlightRolloffResponse *
            sceneScale)
        .clamp(0.0, 1.0);
  }

  double get effectiveToneCurveStrength {
    final sceneScale = switch (sceneClass) {
      SceneClass.lowLight => 0.95,
      SceneClass.backlit || SceneClass.highDynamic => 0.88,
      _ => 1.0,
    };
    return (defaultLook.toneCurveStrength *
            defaultLook.toneCurveResponse *
            sceneScale)
        .clamp(0.0, 1.0);
  }

  double get effectiveFadeAmount {
    final sceneScale = switch (sceneClass) {
      SceneClass.lowLight => 0.42,
      SceneClass.backlit || SceneClass.highDynamic => 0.36,
      SceneClass.indoor => 0.72,
      _ => 1.0,
    };
    return (defaultLook.fadeAmount * defaultLook.fadeResponse * sceneScale)
        .clamp(0.0, 0.5);
  }

  double get centerGain => defaultLook.centerGain.clamp(0.0, 0.2);
  double get edgeFalloff => defaultLook.edgeFalloff.clamp(0.0, 1.0);
  double get cornerWarmShift => defaultLook.cornerWarmShift.clamp(0.0, 5.0);
  double get skinHueProtect =>
      (defaultLook.skinHueProtect || effectiveBeautyStrength > 0.02)
          ? 1.0
          : 0.0;
  double get chemicalIrregularity =>
      defaultLook.chemicalIrregularity.clamp(0.0, 0.1);

  /// FIX: noiseAmount 现已添加到 DefaultLook
  double get noiseAmount => defaultLook.noiseAmount.clamp(0.0, 1.0);
  double get skinSatProtect => (defaultLook.skinSatProtect -
          _dynamicSkinSatDelta() -
          effectiveBeautyStrength * 0.08)
      .clamp(0.0, 1.0);
  double get skinLumaSoften => (defaultLook.skinLumaSoften +
          _dynamicSkinLumaDelta() +
          effectiveBeautyStrength * 0.10)
      .clamp(0.0, 0.30);
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
    if (renderStyleMode == RenderStyleMode.replica) return 1.0;
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
    if (renderStyleMode == RenderStyleMode.replica) return 1.0;
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
    if (renderStyleMode == RenderStyleMode.replica) return 0.0;
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
    if (renderStyleMode == RenderStyleMode.replica) return 0.0;
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
    if (renderStyleMode == RenderStyleMode.replica) return 1.0;
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
    if (renderStyleMode == RenderStyleMode.replica) return 1.0;
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
    final sceneScale = _auditedSceneLutStrengthScale(sceneClass);
    final frontScale = isFrontCamera ? 0.97 : 1.0;
    return (base * sceneScale * frontScale).clamp(0.55, 1.0);
  }

  double _sceneTemperatureOffset(SceneClass scene) {
    if (renderStyleMode == RenderStyleMode.replica) return 0.0;
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
    if (renderStyleMode == RenderStyleMode.replica) return 0.0;
    if (skinHueProtect < 0.5) return 0.0;
    final warmWeight = ((5200 - colorTempK) / 2600.0).clamp(0.0, 1.0);
    final lowLightWeight = (exposureOffset / 1.4).clamp(0.0, 1.0);
    final sceneBoost = switch (sceneClass) {
      SceneClass.backlit || SceneClass.highDynamic => 0.05,
      SceneClass.lowLight => 0.03,
      _ => 0.0,
    };
    return _auditSmartSkinDelta(
      0.10 * warmWeight + 0.06 * lowLightWeight + sceneBoost,
      maxDelta: 0.12,
    );
  }

  double _dynamicSkinLumaDelta() {
    if (renderStyleMode == RenderStyleMode.replica) return 0.0;
    if (skinHueProtect < 0.5) return 0.0;
    final lowLightWeight = (exposureOffset / 1.5).clamp(0.0, 1.0);
    final sceneBoost = switch (sceneClass) {
      SceneClass.backlit || SceneClass.highDynamic => 0.02,
      SceneClass.lowLight => 0.03,
      _ => 0.0,
    };
    return _auditSmartSkinDelta(
      0.03 * lowLightWeight + sceneBoost,
      maxDelta: 0.045,
    );
  }

  double _dynamicSkinRedLimitDelta() {
    if (renderStyleMode == RenderStyleMode.replica) return 0.0;
    if (skinHueProtect < 0.5) return 0.0;
    final warmWeight = ((5200 - colorTempK) / 2600.0).clamp(0.0, 1.0);
    final dynamicWeight =
        sceneClass == SceneClass.backlit || sceneClass == SceneClass.highDynamic
            ? 1.0
            : 0.0;
    final lowLightBoost = sceneClass == SceneClass.lowLight ? 0.02 : 0.0;
    return _auditSmartSkinDelta(
      0.03 * warmWeight + 0.02 * dynamicWeight + lowLightBoost,
      maxDelta: 0.05,
    );
  }

  double get paperTexture {
    final sceneScale = switch (sceneClass) {
      SceneClass.lowLight => 0.7,
      SceneClass.backlit || SceneClass.highDynamic => 0.82,
      _ => 1.0,
    };
    return (defaultLook.paperTexture * sceneScale).clamp(0.0, 1.0);
  }

  double get developmentSoftness {
    final sceneScale = switch (sceneClass) {
      SceneClass.lowLight => 0.55,
      SceneClass.backlit || SceneClass.highDynamic => 0.68,
      SceneClass.indoor => 0.86,
      _ => 1.0,
    };
    return (defaultLook.developmentSoftness * sceneScale +
            effectiveBeautyStrength * 0.28)
        .clamp(0.0, 1.0);
  }

  double get _sceneAdaptiveMix =>
      renderStyleMode == RenderStyleMode.smart ? 1.0 : 0.0;
  double get _exposureProtectionMix =>
      renderStyleMode == RenderStyleMode.smart ? 1.0 : 0.22;
  bool get _isSmartMode => renderStyleMode == RenderStyleMode.smart;

  double _auditSmartOffset(
    double value, {
    required double min,
    required double max,
  }) {
    if (!_isSmartMode) return value;
    return value.clamp(min, max);
  }

  double _auditSmartScale(
    double value, {
    required double min,
    required double max,
  }) {
    if (!_isSmartMode) return value;
    return value.clamp(min, max);
  }

  double _auditSmartSkinDelta(double value, {required double maxDelta}) {
    if (!_isSmartMode) return value;
    return value.clamp(0.0, maxDelta);
  }

  double _auditedSceneHighlightOffset(SceneClass scene) =>
      _auditSmartOffset(_sceneHighlightOffset(scene), min: -18.0, max: 0.0);

  double _auditedSceneShadowsOffset(SceneClass scene) =>
      _auditSmartOffset(_sceneShadowsOffset(scene), min: 0.0, max: 14.0);

  double _auditedSceneWhitesOffset(SceneClass scene) =>
      _auditSmartOffset(_sceneWhitesOffset(scene), min: -12.0, max: 0.0);

  double _auditedSceneContrastScale(SceneClass scene) =>
      _auditSmartScale(_sceneContrastScale(scene), min: 0.97, max: 1.01);

  double _auditedSceneSaturationScale(SceneClass scene) =>
      _auditSmartScale(_sceneSaturationScale(scene), min: 0.95, max: 1.02);

  double _auditedSceneClarityOffset(SceneClass scene) =>
      _auditSmartOffset(_sceneClarityOffset(scene), min: -6.0, max: 1.0);

  double _auditedSceneVibranceOffset(SceneClass scene) =>
      _auditSmartOffset(_sceneVibranceOffset(scene), min: -8.0, max: 2.0);

  double _auditedSceneGrainScale(SceneClass scene) =>
      _auditSmartScale(_sceneGrainScale(scene), min: 0.78, max: 1.0);

  double _auditedSceneLutStrengthScale(SceneClass scene) =>
      _auditSmartScale(_sceneLutStrengthScale(scene), min: 0.95, max: 1.0);

  double _auditedSceneTemperatureOffset(SceneClass scene) =>
      _auditSmartOffset(_sceneTemperatureOffset(scene), min: -1.5, max: 0.8);

  double _filterGrainAmount(String? grain) {
    switch ((grain ?? '').toLowerCase()) {
      case 'light':
        return 0.06;
      case 'medium':
        return 0.12;
      case 'heavy':
        return 0.18;
      default:
        return 0.0;
    }
  }

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
        'highlightRolloff2': effectiveHighlightRolloff2,
        'toneCurveStrength': effectiveToneCurveStrength,
        'halationAmount': effectiveHalation,
        'sharpen': effectiveSharpen,
        'sharpness': effectiveSharpness,
        'dehaze': effectiveDehaze,
        'highlightWarmAmount': highlightWarmAmount,
        'lensVignette': effectiveVignette,
        'exposureOffset': exposureOffset + effectiveLensExposure,
        'distortion': effectiveDistortion,
        'fisheyeMode': effectiveFisheyeMode ? 1.0 : 0.0,
        'softFocus': effectiveSoftFocus,
        'grainSize': effectiveGrainSize,
        'luminanceNoise': defaultLook.luminanceNoise.clamp(0.0, 0.5),
        'chromaNoise': defaultLook.chromaNoise.clamp(0.0, 0.5),
        'exposureVariation': defaultLook.exposureVariation.clamp(0.0, 0.1),
        'topBottomBias': topBottomBias,
        'leftRightBias': leftRightBias,
        'beautyStrength': effectiveBeautyStrength,
        if (hasCustomToneCurve) 'toneCurvePoints': toneCurvePoints,
        if (hasBwMixer) 'bwChannelMixer': bwChannelMixer,
        // ── 新增：Fade / Split Toning / Light Leak ──
        'fadeAmount': effectiveFadeAmount,
        'fade': effectiveFadeAmount,
        'shadowTintR': defaultLook.shadowTintR.clamp(-0.2, 0.2),
        'shadowTintG': defaultLook.shadowTintG.clamp(-0.2, 0.2),
        'shadowTintB': defaultLook.shadowTintB.clamp(-0.2, 0.2),
        'highlightTintR': defaultLook.highlightTintR.clamp(-0.2, 0.2),
        'highlightTintG': defaultLook.highlightTintG.clamp(-0.2, 0.2),
        'highlightTintB': defaultLook.highlightTintB.clamp(-0.2, 0.2),
        'splitToneBalance': defaultLook.splitToneBalance.clamp(0.0, 1.0),
        'lightLeakAmount': defaultLook.lightLeakAmount.clamp(0.0, 1.0),
        if (cameraId.isNotEmpty) 'cameraId': cameraId,
        // runtime calibration/debug context
        'sceneClass': sceneClass.name,
        'protectionMode': protectionMode,
        'renderStyleMode': renderStyleMode.storageValue,
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
        'smartAuditEnabled': _isSmartMode,
        'smartAuditContrastScale': _auditedSceneContrastScale(sceneClass),
        'smartAuditSaturationScale': _auditedSceneSaturationScale(sceneClass),
        'smartAuditHighlightOffset': _auditedSceneHighlightOffset(sceneClass),
        'smartAuditShadowOffset': _auditedSceneShadowsOffset(sceneClass),
        'smartAuditWhitesOffset': _auditedSceneWhitesOffset(sceneClass),
        'smartAuditClarityOffset': _auditedSceneClarityOffset(sceneClass),
        'smartAuditVibranceOffset': _auditedSceneVibranceOffset(sceneClass),
        'smartAuditTemperatureOffset':
            _auditedSceneTemperatureOffset(sceneClass),
      };

  Map<String, dynamic> toPreviewJson({
    required PreviewPerformanceMode mode,
  }) {
    final json = Map<String, dynamic>.from(toJson());
    if (!mode.isLightweight) return json;

    final previewBeauty = (effectiveBeautyStrength * 0.82).clamp(0.0, 1.0);

    json['clarity'] = previewBeauty > 0.0 ? (-previewBeauty * 16.0) : 0.0;
    json['grainAmount'] = 0.0;
    json['noiseAmount'] = 0.0;
    json['chromaticAberration'] = 0.0;
    json['bloomAmount'] = 0.0;
    json['paperTexture'] = 0.0;
    json['developmentSoftness'] =
        previewBeauty > 0.0 ? (previewBeauty * 0.24) : 0.0;
    json['chemicalIrregularity'] = 0.0;
    json['halationAmount'] = 0.0;
    json['sharpen'] = previewBeauty > 0.0 ? (0.16 - previewBeauty * 0.16) : 0.0;
    json['sharpness'] =
        previewBeauty > 0.0 ? (1.0 - previewBeauty * 0.24) : 1.0;
    json['dehaze'] = 0.0;
    json['highlightWarmAmount'] = 0.0;
    json['softFocus'] = previewBeauty > 0.0 ? (previewBeauty * 0.18) : 0.0;
    json['skinHueProtect'] = previewBeauty > 0.0 ? 1.0 : json['skinHueProtect'];
    json['skinLumaSoften'] =
        previewBeauty > 0.0 ? (previewBeauty * 0.08) : json['skinLumaSoften'];
    json['grainSize'] = 1.0;
    json['luminanceNoise'] = 0.0;
    json['chromaNoise'] = 0.0;
    json['exposureVariation'] = 0.0;
    json['vignetteAmount'] = effectiveVignette.clamp(0.0, 0.18);
    return json;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PreviewFilterWidget — wraps camera Texture with render effects
// ─────────────────────────────────────────────────────────────────────────────

class PreviewFilterWidget extends StatelessWidget {
  final int textureId;
  final PreviewRenderParams params;

  /// 目标比例（用户选择，如 1:1/3:4/9:16）——只用于取景框容器大小计算
  final double aspectRatio;

  /// 相机预览源实际比例（短边/长边，竖屏口径）——用于 cover 缩放计算
  final double sourceAspectRatio;

  const PreviewFilterWidget({
    super.key,
    required this.textureId,
    required this.params,
    this.aspectRatio = 3 / 4,
    this.sourceAspectRatio = 3 / 4,
  });

  @override
  Widget build(BuildContext context) {
    // 后置保持满幅 cover，前置和圆形鱼眼优先保持原始几何比例。
    // Flutter 层不参与鱼眼绘制，只负责避免取景框内圆圈被二次裁切。
    return LayoutBuilder(
      builder: (context, constraints) {
        final containerW = constraints.maxWidth;
        final containerH = constraints.maxHeight;
        final sensorAspect =
            sourceAspectRatio > 0.01 ? sourceAspectRatio : 3 / 4;
        final containerAspect = containerW / containerH;
        final keepSourceAspect = params.isFrontCamera ||
            params.activeLens?.circularFisheyeCrop == true;
        double contentW, contentH;

        if (keepSourceAspect) {
          if (containerAspect >= sensorAspect) {
            contentH = containerH;
            contentW = containerH * sensorAspect;
          } else {
            contentW = containerW;
            contentH = containerW / sensorAspect;
          }
        } else if (containerAspect >= sensorAspect) {
          contentW = containerW;
          contentH = containerW / sensorAspect;
        } else {
          contentH = containerH;
          contentW = containerH * sensorAspect;
        }

        return ColoredBox(
          color: Colors.black,
          child: Center(
            child: keepSourceAspect
                ? SizedBox(
                    width: contentW,
                    height: contentH,
                    child: Texture(textureId: textureId),
                  )
                : ClipRect(
                    child: OverflowBox(
                      maxWidth: contentW,
                      maxHeight: contentH,
                      child: SizedBox(
                        width: contentW,
                        height: contentH,
                        // Phase 2 重构：所有渲染特效已下沉到 Native GPU Shader
                        // Flutter 层仅显示纯 Texture，不再做像素级渲染
                        child: Texture(textureId: textureId),
                      ),
                    ),
                  ),
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
