class SceneCalibrationDelta {
  final double temperatureOffset;
  final double tintOffset;
  final double contrastScale;
  final double saturationScale;
  final double colorBiasROffset;
  final double colorBiasGOffset;
  final double colorBiasBOffset;

  const SceneCalibrationDelta({
    this.temperatureOffset = 0.0,
    this.tintOffset = 0.0,
    this.contrastScale = 1.0,
    this.saturationScale = 1.0,
    this.colorBiasROffset = 0.0,
    this.colorBiasGOffset = 0.0,
    this.colorBiasBOffset = 0.0,
  });
}

class DeviceFingerprint {
  final String brand;
  final String model;
  final String cameraId;
  final String runtimeCameraId;
  final double sensorMp;
  final String manufacturer;
  final String device;
  final String facing;
  final String focalLengths;

  const DeviceFingerprint({
    required this.brand,
    required this.model,
    required this.cameraId,
    required this.runtimeCameraId,
    required this.sensorMp,
    this.manufacturer = '',
    this.device = '',
    this.facing = '',
    this.focalLengths = '',
  });

  factory DeviceFingerprint.normalized({
    required String brand,
    required String model,
    required String cameraId,
    required String runtimeCameraId,
    required double sensorMp,
    String manufacturer = '',
    String device = '',
    String facing = '',
    String focalLengths = '',
  }) {
    String norm(String value) => value.trim().toLowerCase();

    return DeviceFingerprint(
      brand: norm(brand),
      model: norm(model),
      cameraId: norm(cameraId),
      runtimeCameraId: runtimeCameraId.trim(),
      sensorMp: sensorMp,
      manufacturer: norm(manufacturer),
      device: norm(device),
      facing: norm(facing),
      focalLengths: focalLengths.trim(),
    );
  }

  bool get hasIdentity =>
      brand.isNotEmpty ||
      model.isNotEmpty ||
      runtimeCameraId.isNotEmpty ||
      sensorMp > 0.0;
}

class ExactDeviceCalibrationProfile {
  final String brand;
  final String model;
  final String cameraId;
  final String runtimeCameraId;
  final double sensorMp;
  final double temperatureOffset;
  final double tintOffset;
  final double contrastScale;
  final double saturationScale;
  final double colorBiasROffset;
  final double colorBiasGOffset;
  final double colorBiasBOffset;
  final List<double> ccm;
  final double whiteScaleR;
  final double whiteScaleG;
  final double whiteScaleB;
  final double gamma;
  final SceneCalibrationDelta daylight;
  final SceneCalibrationDelta indoor;
  final SceneCalibrationDelta backlit;

  const ExactDeviceCalibrationProfile({
    required this.brand,
    required this.model,
    this.cameraId = '',
    this.runtimeCameraId = '',
    this.sensorMp = 0.0,
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
    this.daylight = const SceneCalibrationDelta(),
    this.indoor = const SceneCalibrationDelta(),
    this.backlit = const SceneCalibrationDelta(),
  });

  bool matches(DeviceFingerprint fingerprint) {
    if (brand != fingerprint.brand || model != fingerprint.model) return false;
    if (cameraId.isNotEmpty && cameraId != fingerprint.cameraId) return false;
    if (runtimeCameraId.isNotEmpty &&
        runtimeCameraId != fingerprint.runtimeCameraId) {
      return false;
    }
    if (sensorMp > 0.0 &&
        fingerprint.sensorMp > 0.0 &&
        (sensorMp - fingerprint.sensorMp).abs() > 1.0) {
      return false;
    }
    return true;
  }
}

class DeviceFamilyCalibrationProfile {
  final String id;
  final bool Function(DeviceFingerprint fingerprint) matcher;
  final double temperatureOffset;
  final double tintOffset;
  final double contrastScale;
  final double saturationScale;
  final double colorBiasROffset;
  final double colorBiasGOffset;
  final double colorBiasBOffset;
  final List<double> ccm;
  final double whiteScaleR;
  final double whiteScaleG;
  final double whiteScaleB;
  final double gamma;

  const DeviceFamilyCalibrationProfile({
    required this.id,
    required this.matcher,
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

  bool matches(DeviceFingerprint fingerprint) => matcher(fingerprint);
}

const SceneCalibrationDelta _kTemplateDaylight = SceneCalibrationDelta(
  temperatureOffset: 0.0,
  tintOffset: 0.0,
  contrastScale: 1.0,
  saturationScale: 1.0,
  colorBiasROffset: 0.0,
  colorBiasGOffset: 0.0,
  colorBiasBOffset: 0.0,
);

const SceneCalibrationDelta _kTemplateIndoorWarm = SceneCalibrationDelta(
  temperatureOffset: 0.0,
  tintOffset: 0.0,
  contrastScale: 1.0,
  saturationScale: 1.0,
  colorBiasROffset: 0.0,
  colorBiasGOffset: 0.0,
  colorBiasBOffset: 0.0,
);

const SceneCalibrationDelta _kTemplateBacklit = SceneCalibrationDelta(
  temperatureOffset: 0.0,
  tintOffset: 0.0,
  contrastScale: 1.0,
  saturationScale: 1.0,
  colorBiasROffset: 0.0,
  colorBiasGOffset: 0.0,
  colorBiasBOffset: 0.0,
);

bool _isApple(DeviceFingerprint fp) =>
    fp.brand.contains('apple') || fp.model.contains('iphone');

bool _isSamsung(DeviceFingerprint fp) => fp.brand.contains('samsung');

bool _isXiaomiFamily(DeviceFingerprint fp) =>
    fp.brand.contains('xiaomi') ||
    fp.brand.contains('redmi') ||
    fp.brand.contains('poco') ||
    fp.manufacturer.contains('xiaomi');

bool _isBbkFamily(DeviceFingerprint fp) =>
    fp.brand.contains('vivo') ||
    fp.brand.contains('oppo') ||
    fp.brand.contains('oneplus') ||
    fp.manufacturer.contains('vivo') ||
    fp.manufacturer.contains('oppo') ||
    fp.manufacturer.contains('oneplus');

bool _isHuaweiHonor(DeviceFingerprint fp) =>
    fp.brand.contains('huawei') ||
    fp.brand.contains('honor') ||
    fp.manufacturer.contains('huawei') ||
    fp.manufacturer.contains('honor');

bool _isGenericHighMp(DeviceFingerprint fp) => fp.sensorMp >= 150.0;

// Hot-device exact override registration:
// 1. Keep entries grouped by device family.
// 2. One physical module variant per entry (distinguish by runtimeCameraId/sensorMp
//    when needed).
// 3. Scope replica-specific tuning through cameraId so presets can diverge on the
//    same phone without cross-contamination.
// 4. Only promote verified chart-calibrated devices into these active lists.
// 5. First-wave priority:
//    - iPhone 15 Pro / 15 Pro Max / 16 Pro / 16 Pro Max
//    - Galaxy S23 Ultra / S24 Ultra / S25 Ultra
//    - Xiaomi 13 Ultra / 14 Ultra / 15 Ultra
const List<ExactDeviceCalibrationProfile> _kIphoneHotExactOverrides = [];
const List<ExactDeviceCalibrationProfile> _kSamsungUltraHotExactOverrides = [];
const List<ExactDeviceCalibrationProfile> _kXiaomiUltraHotExactOverrides = [];

// Local exact overrides are optional and should be reserved for hot devices
// with verified chart-based calibration. This lets the shipped app improve
// popular models without asking any user to fill device info manually.
const List<ExactDeviceCalibrationProfile> kLocalExactDeviceCalibrationProfiles =
    [
  ..._kIphoneHotExactOverrides,
  ..._kSamsungUltraHotExactOverrides,
  ..._kXiaomiUltraHotExactOverrides,
];

// Family profiles are the default scalable layer for end-user devices.
const List<DeviceFamilyCalibrationProfile> kDeviceFamilyCalibrationProfiles = [
  DeviceFamilyCalibrationProfile(
    id: 'xiaomi_family',
    matcher: _isXiaomiFamily,
    temperatureOffset: -5.0,
    tintOffset: -2.5,
    contrastScale: 1.02,
    saturationScale: 0.97,
    colorBiasROffset: -0.008,
    colorBiasGOffset: 0.003,
    colorBiasBOffset: 0.006,
    ccm: [
      1.018,
      -0.014,
      -0.004,
      -0.008,
      1.012,
      -0.004,
      -0.010,
      -0.006,
      1.016,
    ],
    whiteScaleR: 1.012,
    whiteScaleG: 1.000,
    whiteScaleB: 0.992,
    gamma: 2.24,
  ),
  DeviceFamilyCalibrationProfile(
    id: 'samsung_family',
    matcher: _isSamsung,
    temperatureOffset: 2.0,
    tintOffset: -0.8,
    contrastScale: 0.99,
    saturationScale: 0.98,
    colorBiasROffset: -0.003,
    colorBiasGOffset: 0.001,
    colorBiasBOffset: 0.002,
    ccm: [
      1.010,
      -0.007,
      -0.003,
      -0.006,
      1.008,
      -0.002,
      -0.004,
      -0.004,
      1.012,
    ],
    whiteScaleR: 1.006,
    whiteScaleG: 1.000,
    whiteScaleB: 0.996,
    gamma: 2.20,
  ),
  DeviceFamilyCalibrationProfile(
    id: 'bbk_family',
    matcher: _isBbkFamily,
    temperatureOffset: -2.0,
    tintOffset: -1.0,
    contrastScale: 1.00,
    saturationScale: 0.98,
    colorBiasROffset: -0.004,
    colorBiasGOffset: 0.001,
    colorBiasBOffset: 0.002,
    ccm: [
      1.012,
      -0.009,
      -0.003,
      -0.007,
      1.010,
      -0.003,
      -0.006,
      -0.003,
      1.012,
    ],
    whiteScaleR: 1.008,
    whiteScaleG: 1.000,
    whiteScaleB: 0.995,
    gamma: 2.22,
  ),
  DeviceFamilyCalibrationProfile(
    id: 'huawei_family',
    matcher: _isHuaweiHonor,
    temperatureOffset: 1.2,
    tintOffset: -0.6,
    contrastScale: 0.99,
    saturationScale: 0.99,
    ccm: [
      1.008,
      -0.006,
      -0.002,
      -0.004,
      1.006,
      -0.002,
      -0.004,
      -0.002,
      1.009,
    ],
    whiteScaleR: 1.004,
    whiteScaleG: 1.000,
    whiteScaleB: 0.998,
    gamma: 2.20,
  ),
  DeviceFamilyCalibrationProfile(
    id: 'apple_iphone',
    matcher: _isApple,
    temperatureOffset: 0.6,
    tintOffset: 0.2,
    contrastScale: 1.0,
    saturationScale: 1.0,
    ccm: [
      1.004,
      -0.003,
      -0.001,
      -0.002,
      1.003,
      -0.001,
      -0.002,
      -0.001,
      1.004,
    ],
    whiteScaleR: 1.002,
    whiteScaleG: 1.000,
    whiteScaleB: 0.999,
    gamma: 2.18,
  ),
  DeviceFamilyCalibrationProfile(
    id: 'generic_200mp',
    matcher: _isGenericHighMp,
    temperatureOffset: -2.0,
    tintOffset: -0.8,
    saturationScale: 0.98,
    colorBiasROffset: -0.004,
    colorBiasBOffset: 0.003,
    ccm: [
      1.014,
      -0.010,
      -0.004,
      -0.007,
      1.010,
      -0.003,
      -0.008,
      -0.004,
      1.014,
    ],
    whiteScaleR: 1.009,
    whiteScaleG: 1.000,
    whiteScaleB: 0.994,
    gamma: 2.24,
  ),
];

// Templates for future verified exact profiles. Keep them out of the active
// registry until real measured device signatures are filled in.
const List<ExactDeviceCalibrationProfile> kExactProfileTemplates = [
  ExactDeviceCalibrationProfile(
    brand: '__fill_brand__',
    model: '__fill_model__',
    cameraId: 'fxn_r',
    runtimeCameraId: '__fill_runtime_camera_id__',
    sensorMp: 0.0,
    daylight: _kTemplateDaylight,
    indoor: _kTemplateIndoorWarm,
    backlit: _kTemplateBacklit,
  ),
  ExactDeviceCalibrationProfile(
    brand: '__fill_brand__',
    model: '__fill_model__',
    cameraId: 'ccd_r',
    runtimeCameraId: '__fill_runtime_camera_id__',
    sensorMp: 0.0,
    daylight: _kTemplateDaylight,
    indoor: _kTemplateIndoorWarm,
    backlit: _kTemplateBacklit,
  ),
  ExactDeviceCalibrationProfile(
    brand: '__fill_brand__',
    model: '__fill_model__',
    cameraId: 'grd_r',
    runtimeCameraId: '__fill_runtime_camera_id__',
    sensorMp: 0.0,
    daylight: _kTemplateDaylight,
    indoor: _kTemplateIndoorWarm,
    backlit: _kTemplateBacklit,
  ),
  ExactDeviceCalibrationProfile(
    brand: '__fill_brand__',
    model: '__fill_model__',
    cameraId: 'cpm35',
    runtimeCameraId: '__fill_runtime_camera_id__',
    sensorMp: 0.0,
    daylight: _kTemplateDaylight,
    indoor: _kTemplateIndoorWarm,
    backlit: _kTemplateBacklit,
  ),
  ExactDeviceCalibrationProfile(
    brand: '__fill_brand__',
    model: '__fill_model__',
    cameraId: 'inst_c',
    runtimeCameraId: '__fill_runtime_camera_id__',
    sensorMp: 0.0,
    daylight: _kTemplateDaylight,
    indoor: _kTemplateIndoorWarm,
    backlit: _kTemplateBacklit,
  ),
];

// Registration templates for high-priority device lines. Copy one of these into
// the matching hot-override list after replacing all placeholder fields with
// verified chart-based measurements.
const List<ExactDeviceCalibrationProfile> kHotDeviceOverrideTemplates = [
  ExactDeviceCalibrationProfile(
    brand: 'apple',
    model: '__fill_iphone_model__',
    cameraId: 'fxn_r',
    runtimeCameraId: '__fill_runtime_camera_id__',
    sensorMp: 0.0,
    daylight: _kTemplateDaylight,
    indoor: _kTemplateIndoorWarm,
    backlit: _kTemplateBacklit,
  ),
  ExactDeviceCalibrationProfile(
    brand: 'samsung',
    model: '__fill_galaxy_ultra_model__',
    cameraId: 'fxn_r',
    runtimeCameraId: '__fill_runtime_camera_id__',
    sensorMp: 0.0,
    daylight: _kTemplateDaylight,
    indoor: _kTemplateIndoorWarm,
    backlit: _kTemplateBacklit,
  ),
  ExactDeviceCalibrationProfile(
    brand: 'xiaomi',
    model: '__fill_xiaomi_ultra_model__',
    cameraId: 'fxn_r',
    runtimeCameraId: '__fill_runtime_camera_id__',
    sensorMp: 0.0,
    daylight: _kTemplateDaylight,
    indoor: _kTemplateIndoorWarm,
    backlit: _kTemplateBacklit,
  ),
];
