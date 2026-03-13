/// 全局常量定义
abstract class AppConstants {
  // Platform Channel 名称
  static const String cameraControlChannel = 'com.retrocam.app/camera_control';
  static const String cameraEventsChannel = 'com.retrocam.app/camera_events';

  // 错误码
  static const int errorCameraInitFailed = 1001;
  static const int errorPermissionDenied = 1002;
  static const int errorPresetParseFailed = 1003;
  static const int errorRenderPipelineFailed = 1004;
  static const int errorFileWriteFailed = 1005;

  // 事件类型
  static const String eventCameraReady = 'onCameraReady';
  static const String eventPermissionDenied = 'onPermissionDenied';
  static const String eventPhotoCaptured = 'onPhotoCaptured';
  static const String eventVideoRecorded = 'onVideoRecorded';
  static const String eventRecordingStateChanged = 'onRecordingStateChanged';
  static const String eventError = 'onError';

  // Preset 分类
  static const String categoryAll = 'All';
  static const String categoryCCD = 'CCD';
  static const String categoryFilm = 'Film';
  static const String categoryDisposable = 'Disposable';
  static const String categoryVideo = 'Video';
}
