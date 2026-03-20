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

  bool matches({
    required String brand,
    required String model,
    required String cameraId,
    required String runtimeCameraId,
    required double sensorMp,
  }) {
    final normBrand = brand.trim().toLowerCase();
    final normModel = model.trim().toLowerCase();
    if (this.brand != normBrand || this.model != normModel) return false;
    if (this.cameraId.isNotEmpty && this.cameraId != cameraId) return false;
    if (this.runtimeCameraId.isNotEmpty &&
        this.runtimeCameraId != runtimeCameraId) {
      return false;
    }
    if (this.sensorMp > 0 &&
        sensorMp > 0 &&
        (this.sensorMp - sensorMp).abs() > 1.0) {
      return false;
    }
    return true;
  }
}

const SceneCalibrationDelta _kTemplateDaylight = SceneCalibrationDelta(
  // Fill from daylight benchmark deltas.
  temperatureOffset: 0.0,
  tintOffset: 0.0,
  contrastScale: 1.0,
  saturationScale: 1.0,
  colorBiasROffset: 0.0,
  colorBiasGOffset: 0.0,
  colorBiasBOffset: 0.0,
);

const SceneCalibrationDelta _kTemplateIndoorWarm = SceneCalibrationDelta(
  // Fill from indoor warm-light benchmark deltas.
  temperatureOffset: 0.0,
  tintOffset: 0.0,
  contrastScale: 1.0,
  saturationScale: 1.0,
  colorBiasROffset: 0.0,
  colorBiasGOffset: 0.0,
  colorBiasBOffset: 0.0,
);

const SceneCalibrationDelta _kTemplateBacklit = SceneCalibrationDelta(
  // Fill from backlit benchmark deltas.
  temperatureOffset: 0.0,
  tintOffset: 0.0,
  contrastScale: 1.0,
  saturationScale: 1.0,
  colorBiasROffset: 0.0,
  colorBiasGOffset: 0.0,
  colorBiasBOffset: 0.0,
);

const ExactDeviceCalibrationProfile _kTemplateFxnRProfile =
    ExactDeviceCalibrationProfile(
  // Replace these match keys with the real device identifiers.
  brand: '__fill_brand__',
  model: '__fill_model__',
  cameraId: 'fxn_r',
  runtimeCameraId: '__fill_runtime_camera_id__',
  sensorMp: 0.0,
  // Base neutral-scene calibration from the consolidated benchmark.
  temperatureOffset: 0.0,
  tintOffset: 0.0,
  contrastScale: 1.0,
  saturationScale: 1.0,
  colorBiasROffset: 0.0,
  colorBiasGOffset: 0.0,
  colorBiasBOffset: 0.0,
  // Replace with measured device CCM / white scales when available.
  ccm: const [1, 0, 0, 0, 1, 0, 0, 0, 1],
  whiteScaleR: 1.0,
  whiteScaleG: 1.0,
  whiteScaleB: 1.0,
  gamma: 2.2,
  daylight: _kTemplateDaylight,
  indoor: _kTemplateIndoorWarm,
  backlit: _kTemplateBacklit,
);

const ExactDeviceCalibrationProfile _kTemplateCcdRProfile =
    ExactDeviceCalibrationProfile(
  brand: '__fill_brand__',
  model: '__fill_model__',
  cameraId: 'ccd_r',
  runtimeCameraId: '__fill_runtime_camera_id__',
  sensorMp: 0.0,
  temperatureOffset: 0.0,
  tintOffset: 0.0,
  contrastScale: 1.0,
  saturationScale: 1.0,
  colorBiasROffset: 0.0,
  colorBiasGOffset: 0.0,
  colorBiasBOffset: 0.0,
  ccm: const [1, 0, 0, 0, 1, 0, 0, 0, 1],
  whiteScaleR: 1.0,
  whiteScaleG: 1.0,
  whiteScaleB: 1.0,
  gamma: 2.2,
  daylight: _kTemplateDaylight,
  indoor: _kTemplateIndoorWarm,
  backlit: _kTemplateBacklit,
);

const ExactDeviceCalibrationProfile _kTemplateGrdRProfile =
    ExactDeviceCalibrationProfile(
  brand: '__fill_brand__',
  model: '__fill_model__',
  cameraId: 'grd_r',
  runtimeCameraId: '__fill_runtime_camera_id__',
  sensorMp: 0.0,
  temperatureOffset: 0.0,
  tintOffset: 0.0,
  contrastScale: 1.0,
  saturationScale: 1.0,
  colorBiasROffset: 0.0,
  colorBiasGOffset: 0.0,
  colorBiasBOffset: 0.0,
  ccm: const [1, 0, 0, 0, 1, 0, 0, 0, 1],
  whiteScaleR: 1.0,
  whiteScaleG: 1.0,
  whiteScaleB: 1.0,
  gamma: 2.2,
  daylight: _kTemplateDaylight,
  indoor: _kTemplateIndoorWarm,
  backlit: _kTemplateBacklit,
);

const ExactDeviceCalibrationProfile _kTemplateCpm35Profile =
    ExactDeviceCalibrationProfile(
  brand: '__fill_brand__',
  model: '__fill_model__',
  cameraId: 'cpm35',
  runtimeCameraId: '__fill_runtime_camera_id__',
  sensorMp: 0.0,
  temperatureOffset: 0.0,
  tintOffset: 0.0,
  contrastScale: 1.0,
  saturationScale: 1.0,
  colorBiasROffset: 0.0,
  colorBiasGOffset: 0.0,
  colorBiasBOffset: 0.0,
  ccm: const [1, 0, 0, 0, 1, 0, 0, 0, 1],
  whiteScaleR: 1.0,
  whiteScaleG: 1.0,
  whiteScaleB: 1.0,
  gamma: 2.2,
  daylight: _kTemplateDaylight,
  indoor: _kTemplateIndoorWarm,
  backlit: _kTemplateBacklit,
);

const ExactDeviceCalibrationProfile _kTemplateInstCProfile =
    ExactDeviceCalibrationProfile(
  brand: '__fill_brand__',
  model: '__fill_model__',
  cameraId: 'inst_c',
  runtimeCameraId: '__fill_runtime_camera_id__',
  sensorMp: 0.0,
  temperatureOffset: 0.0,
  tintOffset: 0.0,
  contrastScale: 1.0,
  saturationScale: 1.0,
  colorBiasROffset: 0.0,
  colorBiasGOffset: 0.0,
  colorBiasBOffset: 0.0,
  ccm: const [1, 0, 0, 0, 1, 0, 0, 0, 1],
  whiteScaleR: 1.0,
  whiteScaleG: 1.0,
  whiteScaleB: 1.0,
  gamma: 2.2,
  daylight: _kTemplateDaylight,
  indoor: _kTemplateIndoorWarm,
  backlit: _kTemplateBacklit,
);

// Exact profiles generated from the ColorChecker workflow should live here.
// Each target device should be calibrated in daylight / indoor warm light /
// backlit scenes before adding a profile.
//
// The templates below are intentionally non-matching placeholders until you
// replace `__fill_*__` keys with a real device signature. They are scoped to
// specific camera presets through `cameraId`, so you can tune each replica
// preset independently on the same phone.
const List<ExactDeviceCalibrationProfile> kExactDeviceCalibrationProfiles = [
  _kTemplateFxnRProfile,
  _kTemplateCcdRProfile,
  _kTemplateGrdRProfile,
  _kTemplateCpm35Profile,
  _kTemplateInstCProfile,
];
