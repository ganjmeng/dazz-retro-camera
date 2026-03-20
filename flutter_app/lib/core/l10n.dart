// l10n.dart — 轻量级国际化方案（无需 flutter_localizations）
// 支持：简体中文、繁体中文、英文、马来文、日文、韩文
// 根据系统语言自动初始化，用户可在设置中手动切换

import 'dart:ui';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── 语言枚举 ─────────────────────────────────────────────────────────────────
enum AppLanguage {
  zhHans, // 简体中文
  zhHant, // 繁体中文
  en, // English
  ms, // Bahasa Melayu
  ja, // 日本語
  ko, // 한국어
}

extension AppLanguageExt on AppLanguage {
  String get displayName {
    switch (this) {
      case AppLanguage.zhHans:
        return '简体中文';
      case AppLanguage.zhHant:
        return '繁體中文';
      case AppLanguage.en:
        return 'English';
      case AppLanguage.ms:
        return 'Bahasa Melayu';
      case AppLanguage.ja:
        return '日本語';
      case AppLanguage.ko:
        return '한국어';
    }
  }

  String get code {
    switch (this) {
      case AppLanguage.zhHans:
        return 'zh_Hans';
      case AppLanguage.zhHant:
        return 'zh_Hant';
      case AppLanguage.en:
        return 'en';
      case AppLanguage.ms:
        return 'ms';
      case AppLanguage.ja:
        return 'ja';
      case AppLanguage.ko:
        return 'ko';
    }
  }
}

// ─── 从系统语言推断默认语言 ────────────────────────────────────────────────────
AppLanguage _detectSystemLanguage() {
  final locale = PlatformDispatcher.instance.locale;
  final lang = locale.languageCode.toLowerCase();
  final script = locale.scriptCode?.toLowerCase() ?? '';
  final country = locale.countryCode?.toLowerCase() ?? '';

  if (lang == 'zh') {
    // 繁体：TW/HK/MO 或 Hant script
    if (script == 'hant' ||
        country == 'tw' ||
        country == 'hk' ||
        country == 'mo') {
      return AppLanguage.zhHant;
    }
    return AppLanguage.zhHans;
  }
  if (lang == 'ja') return AppLanguage.ja;
  if (lang == 'ko') return AppLanguage.ko;
  if (lang == 'ms') return AppLanguage.ms;
  return AppLanguage.en;
}

// ─── Provider ────────────────────────────────────────────────────────────────
const _kLangPrefKey = 'app_language';

class LanguageNotifier extends StateNotifier<AppLanguage> {
  LanguageNotifier() : super(_detectSystemLanguage()) {
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_kLangPrefKey);
    if (saved != null) {
      final lang = AppLanguage.values.firstWhere(
        (l) => l.code == saved,
        orElse: () => state,
      );
      state = lang;
    }
  }

  Future<void> setLanguage(AppLanguage lang) async {
    state = lang;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLangPrefKey, lang.code);
  }
}

final languageProvider = StateNotifierProvider<LanguageNotifier, AppLanguage>(
  (ref) => LanguageNotifier(),
);

// ─── 翻译字符串 ───────────────────────────────────────────────────────────────
class S {
  final AppLanguage _lang;
  const S(this._lang);

  String get(String key) => _t[key]?[_lang] ?? _t[key]?[AppLanguage.en] ?? key;

  // 便捷访问
  String get settings => get('settings');
  String get language => get('language');
  String get dazzPro => get('dazzPro');
  String get restorePurchase => get('restorePurchase');
  String get mirrorFront => get('mirrorFront');
  String get mirrorBack => get('mirrorBack');
  String get livePhoto => get('livePhoto');
  String get livePhotoEffect => get('livePhotoEffect');
  String get livePhotoOn => get('livePhotoOn');
  String get livePhotoOff => get('livePhotoOff');
  String get livePhotoMicRequired => get('livePhotoMicRequired');
  String get livePhotoMicDenied => get('livePhotoMicDenied');
  String get livePhotoNoOverlay => get('livePhotoNoOverlay');
  String get saveLocation => get('saveLocation');
  String get renderMode => get('renderMode');
  String get replicaModeShort => get('replicaModeShort');
  String get smartModeShort => get('smartModeShort');
  String get previewMode => get('previewMode');
  String get previewModeHint => get('previewModeHint');
  String get previewModeLightweightShort => get('previewModeLightweightShort');
  String get previewModePerformanceShort => get('previewModePerformanceShort');
  String get silentCapture => get('silentCapture');
  String get shutterVibration => get('shutterVibration');
  String get shutterSound => get('shutterSound');
  String get guideLines => get('guideLines');
  String get shareApp => get('shareApp');
  String get sendFeedback => get('sendFeedback');
  String get recommendApp => get('recommendApp');
  String get writeReview => get('writeReview');
  String get followInstagram => get('followInstagram');
  String get privacyPolicy => get('privacyPolicy');
  String get termsOfUse => get('termsOfUse');
  String get storageHint => get('storageHint');
  String get hashtagHint => get('hashtagHint');
  String get selectLanguage => get('selectLanguage');
  String get cancel => get('cancel');
  // 保留设定
  String get retainSettings => get('retainSettings');
  String get retainTemperature => get('retainTemperature');
  String get retainTemperatureDesc => get('retainTemperatureDesc');
  String get retainExposure => get('retainExposure');
  String get retainExposureDesc => get('retainExposureDesc');
  String get retainZoom => get('retainZoom');
  String get retainZoomDesc => get('retainZoomDesc');
  String get retainFrame => get('retainFrame');
  String get retainFrameDesc => get('retainFrameDesc');
  // 相机界面
  String get photo => get('photo');
  String get video => get('video');
  String get sample => get('sample');
  String get manage => get('manage');
  String get cameraInitializing => get('cameraInitializing');
  String get importPhoto => get('importPhoto');
  String get timer => get('timer');
  String get timerOff => get('timerOff');
  String timerSeconds(int n) => get('timerSeconds').replaceAll('{n}', '$n');
  String get flash => get('flash');
  String get flashOff => get('flashOff');
  String get flashOn => get('flashOn');
  String get flashAuto => get('flashAuto');
  String get rear => get('rear');
  String get gridOn => get('gridOn');
  String get gridOff => get('gridOff');
  String get sharpness => get('sharpness');
  String get minimapOn => get('minimapOn');
  String get minimapOff => get('minimapOff');
  String get minimapHintOn => get('minimapHintOn');
  String get minimapHintOff => get('minimapHintOff');
  String get doubleExpOn => get('doubleExpOn');
  String get doubleExpOff => get('doubleExpOff');
  String get doubleExpStart => get('doubleExpStart');
  String get doubleExpDisabled => get('doubleExpDisabled');
  String get doubleExpDone => get('doubleExpDone');
  String get locationOn => get('locationOn');
  String get locationOff => get('locationOff');
  String get locationEnabled => get('locationEnabled');
  String get locationDisabled => get('locationDisabled');
  String get locationDenied => get('locationDenied');
  String get locationPermTitle => get('locationPermTitle');
  String get locationPermDesc => get('locationPermDesc');
  String get debugOn => get('debugOn');
  String get debugOff => get('debugOff');
  String get copyCalibrationInfo => get('copyCalibrationInfo');
  String get copyCalibrationInfoDone => get('copyCalibrationInfoDone');
  String get copyCalibrationInfoEmpty => get('copyCalibrationInfoEmpty');
  String get goToSettings => get('goToSettings');
  String get cameraPerm => get('cameraPerm');
  String get cameraPermDesc => get('cameraPermDesc');
  String get wbAuto => get('wbAuto');
  String get wbDaylight => get('wbDaylight');
  String get wbIncandescent => get('wbIncandescent');
  String get doubleExpLabel1 => get('doubleExpLabel1');
  String get doubleExpLabel2 => get('doubleExpLabel2');
  String get burstOff => get('burstOff');
  String burstCount(int n) => get('burstCount').replaceAll('{n}', '$n');
  String burstStart(int n) => get('burstStart').replaceAll('{n}', '$n');
  String burstDone(int n) => get('burstDone').replaceAll('{n}', '$n');
  String get captured1 => get('captured1');
  String get compositing => get('compositing');
  String get unlockAll => get('unlockAll');
  String get leakLight => get('leakLight');
  String get grain => get('grain');
  String get vignette => get('vignette');
  String get frame => get('frame');
  String get color => get('color');
  String get countdownTimer => get('countdownTimer');
  String get ratio => get('ratio');
  String get watermark => get('watermark');
  String get allPhotos => get('allPhotos');
  String get favorites => get('favorites');
  String get film => get('film');
  String get noPhotos => get('noPhotos');
  String get noPhotoHint => get('noPhotoHint');
  String get galleryPermDesc => get('galleryPermDesc');
  String get shareFailed => get('shareFailed');
  String get photoSaved => get('photoSaved');
  String get deletePhoto => get('deletePhoto');
  String get deleteConfirm => get('deleteConfirm');
  String get delete => get('delete');
  String get select => get('select');
  // 图片编辑
  String get selectCamera => get('selectCamera');
  String get edit => get('edit');
  String get save => get('save');
  String get saveFailed => get('saveFailed');
  String get saveFailedRetry => get('saveFailedRetry');
  String get savedToGallery => get('savedToGallery');
  String get needGalleryPerm => get('needGalleryPerm');
  String get processFailed => get('processFailed');
  String get selectCameraFirst => get('selectCameraFirst');
  String get editTab => get('editTab');
  String get filterTab => get('filterTab');
  String get frameTab => get('frameTab');
  String get watermarkTab => get('watermarkTab');
  String get flipTab => get('flipTab');
  String get cropTab => get('cropTab');
  String get none => get('none');
  // 相机配置面板
  String get timeWatermark => get('timeWatermark');
  String get frameBorder => get('frameBorder');
  String get originalRatio => get('originalRatio');
  String get filter => get('filter');
  String get noWatermark => get('noWatermark');
  String get colorLabel => get('colorLabel');
  String get styleLabel => get('styleLabel');
  String get positionLabel => get('positionLabel');
  String get directionLabel => get('directionLabel');
  String get sizeLabel => get('sizeLabel');
  String get horizontal => get('horizontal');
  String get vertical => get('vertical');
  String get sizeSmall => get('sizeSmall');
  String get sizeMedium => get('sizeMedium');
  String get sizeLarge => get('sizeLarge');
  String get frameRatioHint => get('frameRatioHint');
  String get noFrame => get('noFrame');
  String get styleTab => get('styleTab');
  String get backgroundTab => get('backgroundTab');
  String get topLeft => get('topLeft');
  String get topCenter => get('topCenter');
  String get topRight => get('topRight');
  String get bottomLeft => get('bottomLeft');
  String get bottomCenter => get('bottomCenter');
  String get bottomRight => get('bottomRight');
  // 相机管理
  String get cameraManage => get('cameraManage');
  String get loadFailed => get('loadFailed');
  String get favoritesCam => get('favoritesCam');
  String get moreCameras => get('moreCameras');
  String get noFavCam => get('noFavCam');
  String get noCam => get('noCam');
  // 低中高
  String get low => get('low');
  String get medium => get('medium');
  String get high => get('high');
  // 场景提示
  String get sceneHintBalanced => get('sceneHintBalanced');
  String get sceneHintLowLight => get('sceneHintLowLight');
  String get sceneHintBacklit => get('sceneHintBacklit');
  String get sceneHintIndoor => get('sceneHintIndoor');
  String get sceneHintOutdoor => get('sceneHintOutdoor');
  String get sceneHintPortrait => get('sceneHintPortrait');
  String get sceneHintMacro => get('sceneHintMacro');
  String get sceneHintFisheye => get('sceneHintFisheye');
  String get sceneHintHighRes => get('sceneHintHighRes');

  // ── 别名：水印位置（posXxx → 复用 topLeft 等已有翻译）──
  String get posTopLeft => get('topLeft');
  String get posTopCenter => get('topCenter');
  String get posTopRight => get('topRight');
  String get posBottomLeft => get('bottomLeft');
  String get posBottomCenter => get('bottomCenter');
  String get posBottomRight => get('bottomRight');

  // ── 别名：水印方向/大小（复用已有翻译）──
  String get wmHorizontal => get('horizontal');
  String get wmVertical => get('vertical');
  String get small => get('sizeSmall');
  String get large => get('sizeLarge');

  // ── 别名：相机管理（复用 noFavCam / noCam）──
  String get noFavCameras => get('noFavCam');
  String get noCameras => get('noCam');

  // ── 新增：水印/相框配置面板 Tab 标签 ──
  String get wmColor => get('wmColor');
  String get wmStyle => get('wmStyle');
  String get wmPosition => get('wmPosition');
  String get wmDirection => get('wmDirection');
  String get wmSize => get('wmSize');
  String get frameBackground => get('frameBackground');
  String get lens => get('lens');

  // ── 新增：相册权限/空状态/删除确认 ──
  String get galleryPermissionHint => get('galleryPermissionHint');
  String get noPhotosHint => get('noPhotosHint');
  String get deletePhotoConfirm => get('deletePhotoConfirm');

  // ── 新增：图片编辑 ──
  String get imageProcessFailed => get('imageProcessFailed');
  String get needGalleryPermission => get('needGalleryPermission');
  String get saveError => get('saveError');
  String get flip => get('flip');
  String get crop => get('crop');

  // 相机管理重置
  String get reset => get('reset');
  String get resetTitle => get('resetTitle');
  String get resetConfirm => get('resetConfirm');
}

// 全局翻译表
const Map<String, Map<AppLanguage, String>> _t = {
  'settings': {
    AppLanguage.zhHans: '设定',
    AppLanguage.zhHant: '設定',
    AppLanguage.en: 'Settings',
    AppLanguage.ms: 'Tetapan',
    AppLanguage.ja: '設定',
    AppLanguage.ko: '설정',
  },
  'language': {
    AppLanguage.zhHans: '语言',
    AppLanguage.zhHant: '語言',
    AppLanguage.en: 'Language',
    AppLanguage.ms: 'Bahasa',
    AppLanguage.ja: '言語',
    AppLanguage.ko: '언어',
  },
  'dazzPro': {
    AppLanguage.zhHans: 'Dazz Pro',
    AppLanguage.zhHant: 'Dazz Pro',
    AppLanguage.en: 'Dazz Pro',
    AppLanguage.ms: 'Dazz Pro',
    AppLanguage.ja: 'Dazz Pro',
    AppLanguage.ko: 'Dazz Pro',
  },
  'restorePurchase': {
    AppLanguage.zhHans: '恢复购买',
    AppLanguage.zhHant: '恢復購買',
    AppLanguage.en: 'Restore Purchase',
    AppLanguage.ms: 'Pulihkan Pembelian',
    AppLanguage.ja: '購入を復元',
    AppLanguage.ko: '구매 복원',
  },
  'mirrorFront': {
    AppLanguage.zhHans: '镜像前置摄像头',
    AppLanguage.zhHant: '鏡像前置鏡頭',
    AppLanguage.en: 'Mirror Front Camera',
    AppLanguage.ms: 'Cermin Kamera Depan',
    AppLanguage.ja: 'フロントカメラ反転',
    AppLanguage.ko: '전면 카메라 미러',
  },
  'mirrorBack': {
    AppLanguage.zhHans: '镜像后置摄像头',
    AppLanguage.zhHant: '鏡像後置鏡頭',
    AppLanguage.en: 'Mirror Rear Camera',
    AppLanguage.ms: 'Cermin Kamera Belakang',
    AppLanguage.ja: 'リアカメラ反転',
    AppLanguage.ko: '후면 카메라 미러',
  },
  'livePhoto': {
    AppLanguage.zhHans: '实况照片',
    AppLanguage.zhHant: '實況照片',
    AppLanguage.en: 'Live Photo',
    AppLanguage.ms: 'Live Photo',
    AppLanguage.ja: 'Live Photo',
    AppLanguage.ko: '라이브 포토',
  },
  'livePhotoEffect': {
    AppLanguage.zhHans: '实况效果',
    AppLanguage.zhHant: '實況效果',
    AppLanguage.en: 'Live Effect',
    AppLanguage.ms: 'Kesan Live',
    AppLanguage.ja: 'ライブ効果',
    AppLanguage.ko: '라이브 효과',
  },
  'livePhotoOn': {
    AppLanguage.zhHans: '实况已开启',
    AppLanguage.zhHant: '實況已開啟',
    AppLanguage.en: 'Live Photo On',
    AppLanguage.ms: 'Live Photo aktif',
    AppLanguage.ja: 'Live Photo オン',
    AppLanguage.ko: '라이브 포토 켜짐',
  },
  'livePhotoOff': {
    AppLanguage.zhHans: '实况已关闭',
    AppLanguage.zhHant: '實況已關閉',
    AppLanguage.en: 'Live Photo Off',
    AppLanguage.ms: 'Live Photo dimatikan',
    AppLanguage.ja: 'Live Photo オフ',
    AppLanguage.ko: '라이브 포토 꺼짐',
  },
  'livePhotoMicRequired': {
    AppLanguage.zhHans: '开启实况需要麦克风权限以录制声音',
    AppLanguage.zhHant: '開啟實況需要麥克風權限以錄製聲音',
    AppLanguage.en: 'Microphone access is required to record Live Photo audio',
    AppLanguage.ms: 'Akses mikrofon diperlukan untuk merakam audio Live Photo',
    AppLanguage.ja: 'Live Photo の音声録音にはマイク権限が必要です',
    AppLanguage.ko: '라이브 포토 오디오 녹음에는 마이크 권한이 필요합니다',
  },
  'livePhotoMicDenied': {
    AppLanguage.zhHans: '未授予麦克风权限，实况将无法录制声音',
    AppLanguage.zhHant: '未授予麥克風權限，實況將無法錄製聲音',
    AppLanguage.en:
        'Microphone permission denied. Live Photo audio will not be recorded',
    AppLanguage.ms:
        'Kebenaran mikrofon ditolak. Audio Live Photo tidak akan dirakam',
    AppLanguage.ja: 'マイク権限がないため、Live Photo の音声は録音されません',
    AppLanguage.ko: '마이크 권한이 없어 라이브 포토 오디오를 녹음할 수 없습니다',
  },
  'livePhotoNoOverlay': {
    AppLanguage.zhHans: 'Live Photo 不支持边框 水印',
    AppLanguage.zhHant: 'Live Photo 不支援邊框 浮水印',
    AppLanguage.en: 'Live Photo does not support frames or watermarks',
    AppLanguage.ms: 'Live Photo tidak menyokong bingkai atau tera air',
    AppLanguage.ja: 'Live Photo はフレームと透かしに非対応です',
    AppLanguage.ko: '라이브 포토는 프레임과 워터마크를 지원하지 않습니다',
  },
  'saveLocation': {
    AppLanguage.zhHans: '保存地理位置',
    AppLanguage.zhHant: '儲存地理位置',
    AppLanguage.en: 'Save Location',
    AppLanguage.ms: 'Simpan Lokasi',
    AppLanguage.ja: '位置情報を保存',
    AppLanguage.ko: '위치 저장',
  },
  'renderMode': {
    AppLanguage.zhHans: '出片模式',
    AppLanguage.zhHant: '出片模式',
    AppLanguage.en: 'Render Mode',
    AppLanguage.ms: 'Mod Hasil',
    AppLanguage.ja: 'レンダーモード',
    AppLanguage.ko: '렌더 모드',
  },
  'replicaModeShort': {
    AppLanguage.zhHans: '复刻',
    AppLanguage.zhHant: '復刻',
    AppLanguage.en: 'Replica',
    AppLanguage.ms: 'Replika',
    AppLanguage.ja: '復刻',
    AppLanguage.ko: '복각',
  },
  'smartModeShort': {
    AppLanguage.zhHans: '智能',
    AppLanguage.zhHant: '智能',
    AppLanguage.en: 'Smart',
    AppLanguage.ms: 'Pintar',
    AppLanguage.ja: 'スマート',
    AppLanguage.ko: '스마트',
  },
  'previewMode': {
    AppLanguage.zhHans: '预览模式',
    AppLanguage.zhHant: '預覽模式',
    AppLanguage.en: 'Preview Mode',
    AppLanguage.ms: 'Mod Pratonton',
    AppLanguage.ja: 'プレビューモード',
    AppLanguage.ko: '미리보기 모드',
  },
  'previewModeHint': {
    AppLanguage.zhHans: '轻量模式默认使用 720p 并关闭部分重效果，明显降低发热；性能模式预览更完整，但更耗电、更容易发热。',
    AppLanguage.zhHant: '輕量模式預設使用 720p 並關閉部分重效果，可明顯降低發熱；效能模式預覽更完整，但更耗電、更容易發熱。',
    AppLanguage.en:
        'Lightweight mode uses 720p preview and disables heavier effects to reduce heat. Performance mode shows fuller preview effects, but uses more power and runs hotter.',
    AppLanguage.ms:
        'Mod ringan menggunakan pratonton 720p dan mematikan kesan berat untuk mengurangkan haba. Mod prestasi memberi pratonton lebih lengkap, tetapi lebih menggunakan kuasa dan lebih panas.',
    AppLanguage.ja:
        '軽量モードは 720p プレビューと一部の重い効果の無効化で発熱を抑えます。性能モードはプレビュー効果がより完全ですが、消費電力と発熱が増えます。',
    AppLanguage.ko:
        '경량 모드는 720p 미리보기와 일부 무거운 효과 비활성화로 발열을 줄입니다. 성능 모드는 미리보기 효과가 더 완전하지만 전력 소모와 발열이 더 큽니다.',
  },
  'previewModeLightweightShort': {
    AppLanguage.zhHans: '轻量',
    AppLanguage.zhHant: '輕量',
    AppLanguage.en: 'Light',
    AppLanguage.ms: 'Ringan',
    AppLanguage.ja: '軽量',
    AppLanguage.ko: '경량',
  },
  'previewModePerformanceShort': {
    AppLanguage.zhHans: '性能',
    AppLanguage.zhHant: '效能',
    AppLanguage.en: 'Performance',
    AppLanguage.ms: 'Prestasi',
    AppLanguage.ja: '性能',
    AppLanguage.ko: '성능',
  },
  'silentCapture': {
    AppLanguage.zhHans: '静音拍摄',
    AppLanguage.zhHant: '靜音拍攝',
    AppLanguage.en: 'Silent Capture',
    AppLanguage.ms: 'Tangkap Senyap',
    AppLanguage.ja: 'サイレント撮影',
    AppLanguage.ko: '무음 촬영',
  },
  'shutterVibration': {
    AppLanguage.zhHans: '快门震动',
    AppLanguage.zhHant: '快門震動',
    AppLanguage.en: 'Shutter Vibration',
    AppLanguage.ms: 'Getaran Pengatup',
    AppLanguage.ja: 'シャッター振動',
    AppLanguage.ko: '셔터 진동',
  },
  'shutterSound': {
    AppLanguage.zhHans: '快门声音',
    AppLanguage.zhHant: '快門聲音',
    AppLanguage.en: 'Shutter Sound',
    AppLanguage.ms: 'Bunyi Pengatup',
    AppLanguage.ja: 'シャッター音',
    AppLanguage.ko: '셔터 소리',
  },
  'guideLines': {
    AppLanguage.zhHans: '辅助线',
    AppLanguage.zhHant: '輔助線',
    AppLanguage.en: 'Guide Lines',
    AppLanguage.ms: 'Garis Panduan',
    AppLanguage.ja: 'ガイドライン',
    AppLanguage.ko: '가이드라인',
  },
  'shareApp': {
    AppLanguage.zhHans: '分享应用给朋友',
    AppLanguage.zhHant: '分享應用給朋友',
    AppLanguage.en: 'Share with Friends',
    AppLanguage.ms: 'Kongsi dengan Rakan',
    AppLanguage.ja: '友達にシェア',
    AppLanguage.ko: '친구에게 공유',
  },
  'sendFeedback': {
    AppLanguage.zhHans: '发送反馈',
    AppLanguage.zhHant: '傳送意見',
    AppLanguage.en: 'Send Feedback',
    AppLanguage.ms: 'Hantar Maklum Balas',
    AppLanguage.ja: 'フィードバック送信',
    AppLanguage.ko: '피드백 보내기',
  },
  'recommendApp': {
    AppLanguage.zhHans: '推荐应用',
    AppLanguage.zhHant: '推薦應用',
    AppLanguage.en: 'Recommend App',
    AppLanguage.ms: 'Cadangkan Apl',
    AppLanguage.ja: 'アプリを推薦',
    AppLanguage.ko: '앱 추천',
  },
  'writeReview': {
    AppLanguage.zhHans: '撰写评论',
    AppLanguage.zhHant: '撰寫評論',
    AppLanguage.en: 'Write a Review',
    AppLanguage.ms: 'Tulis Ulasan',
    AppLanguage.ja: 'レビューを書く',
    AppLanguage.ko: '리뷰 작성',
  },
  'followInstagram': {
    AppLanguage.zhHans: '在 Instagram 上关注我们',
    AppLanguage.zhHant: '在 Instagram 上關注我們',
    AppLanguage.en: 'Follow Us on Instagram',
    AppLanguage.ms: 'Ikuti Kami di Instagram',
    AppLanguage.ja: 'Instagramでフォロー',
    AppLanguage.ko: 'Instagram 팔로우',
  },
  'privacyPolicy': {
    AppLanguage.zhHans: '隐私政策',
    AppLanguage.zhHant: '隱私政策',
    AppLanguage.en: 'Privacy Policy',
    AppLanguage.ms: 'Dasar Privasi',
    AppLanguage.ja: 'プライバシーポリシー',
    AppLanguage.ko: '개인정보 처리방침',
  },
  'termsOfUse': {
    AppLanguage.zhHans: '使用条款',
    AppLanguage.zhHant: '使用條款',
    AppLanguage.en: 'Terms of Use',
    AppLanguage.ms: 'Syarat Penggunaan',
    AppLanguage.ja: '利用規約',
    AppLanguage.ko: '이용약관',
  },
  'storageHint': {
    AppLanguage.zhHans: '照片和影片储存在本地，请在必要时进行备份。',
    AppLanguage.zhHant: '照片和影片儲存在本地，請在必要時進行備份。',
    AppLanguage.en:
        'Photos and videos are stored locally. Please back them up when needed.',
    AppLanguage.ms:
        'Foto dan video disimpan secara tempatan. Sila buat sandaran bila perlu.',
    AppLanguage.ja: '写真と動画はローカルに保存されます。必要に応じてバックアップしてください。',
    AppLanguage.ko: '사진과 동영상은 로컬에 저장됩니다. 필요시 백업하세요.',
  },
  'hashtagHint': {
    AppLanguage.zhHans: '在社交媒体发布时，请使用',
    AppLanguage.zhHant: '在社交媒體發布時，請使用',
    AppLanguage.en: 'Use',
    AppLanguage.ms: 'Gunakan',
    AppLanguage.ja: 'SNSに投稿するときは',
    AppLanguage.ko: 'SNS에 게시할 때',
  },
  'selectLanguage': {
    AppLanguage.zhHans: '选择语言',
    AppLanguage.zhHant: '選擇語言',
    AppLanguage.en: 'Select Language',
    AppLanguage.ms: 'Pilih Bahasa',
    AppLanguage.ja: '言語を選択',
    AppLanguage.ko: '언어 선택',
  },
  'cancel': {
    AppLanguage.zhHans: '取消',
    AppLanguage.zhHant: '取消',
    AppLanguage.en: 'Cancel',
    AppLanguage.ms: 'Batal',
    AppLanguage.ja: 'キャンセル',
    AppLanguage.ko: '취소',
  },
  // 保留设定
  'retainSettings': {
    AppLanguage.zhHans: '保留设定',
    AppLanguage.zhHant: '保留設定',
    AppLanguage.en: 'Retain Settings',
    AppLanguage.ms: 'Kekal Tetapan',
    AppLanguage.ja: '設定を保持',
    AppLanguage.ko: '설정 유지',
  },
  'retainTemperature': {
    AppLanguage.zhHans: '色温',
    AppLanguage.zhHant: '色溫',
    AppLanguage.en: 'White Balance',
    AppLanguage.ms: 'Imbangan Putih',
    AppLanguage.ja: 'ホワイトバランス',
    AppLanguage.ko: '화이트 밸런스',
  },
  'retainTemperatureDesc': {
    AppLanguage.zhHans: '保留上次使用的色温，而不自动重置。',
    AppLanguage.zhHant: '保留上次使用的色溫，而不自動重置。',
    AppLanguage.en: 'Keep the last white balance instead of auto reset.',
    AppLanguage.ms: 'Kekal imbangan putih terakhir tanpa tetapan semula.',
    AppLanguage.ja: '前回の色温度を保持し、自動リセットしません。',
    AppLanguage.ko: '마지막 화이트 밸런스를 유지합니다.',
  },
  'retainExposure': {
    AppLanguage.zhHans: '曝光设定',
    AppLanguage.zhHant: '曝光設定',
    AppLanguage.en: 'Exposure',
    AppLanguage.ms: 'Pendedahan',
    AppLanguage.ja: '露出設定',
    AppLanguage.ko: '노출 설정',
  },
  'retainExposureDesc': {
    AppLanguage.zhHans: '保留曝光设定，如 EV，而不自动重置。',
    AppLanguage.zhHant: '保留曝光設定，如 EV，而不自動重置。',
    AppLanguage.en: 'Keep the last exposure (EV) instead of auto reset.',
    AppLanguage.ms: 'Kekal tetapan pendedahan (EV) tanpa tetapan semula.',
    AppLanguage.ja: '前回の露出設定(EV)を保持します。',
    AppLanguage.ko: '마지막 노출(EV) 설정을 유지합니다.',
  },
  'retainZoom': {
    AppLanguage.zhHans: '焦距',
    AppLanguage.zhHant: '焦距',
    AppLanguage.en: 'Focal Length',
    AppLanguage.ms: 'Panjang Fokal',
    AppLanguage.ja: 'ズーム',
    AppLanguage.ko: '줌 거리',
  },
  'retainZoomDesc': {
    AppLanguage.zhHans: '保留上次使用的焦距，而不自动重置。',
    AppLanguage.zhHant: '保留上次使用的焦距，而不自動重置。',
    AppLanguage.en: 'Keep the last zoom level instead of auto reset.',
    AppLanguage.ms: 'Kekal tahap zum terakhir tanpa tetapan semula.',
    AppLanguage.ja: '前回のズームを保持し、自動リセットしません。',
    AppLanguage.ko: '마지막 줌 거리를 유지합니다.',
  },
  'retainFrame': {
    AppLanguage.zhHans: '底片',
    AppLanguage.zhHant: '底片',
    AppLanguage.en: 'Film Frame',
    AppLanguage.ms: 'Bingkai Filem',
    AppLanguage.ja: 'フィルム枠',
    AppLanguage.ko: '필름 프레임',
  },
  'retainFrameDesc': {
    AppLanguage.zhHans: '保留上次的底片设置，而不自动重置。',
    AppLanguage.zhHant: '保留上次的底片設定，而不自動重置。',
    AppLanguage.en: 'Keep the last film frame instead of auto reset.',
    AppLanguage.ms: 'Kekal bingkai filem terakhir tanpa tetapan semula.',
    AppLanguage.ja: '前回のフィルム枠を保持し、自動リセットしません。',
    AppLanguage.ko: '마지막 필름 프레임을 유지합니다.',
  },
  // 相机界面
  'photo': {
    AppLanguage.zhHans: '照片',
    AppLanguage.zhHant: '照片',
    AppLanguage.en: 'Photo',
    AppLanguage.ms: 'Foto',
    AppLanguage.ja: '写真',
    AppLanguage.ko: '사진',
  },
  'video': {
    AppLanguage.zhHans: '视频',
    AppLanguage.zhHant: '影片',
    AppLanguage.en: 'Video',
    AppLanguage.ms: 'Video',
    AppLanguage.ja: '動画',
    AppLanguage.ko: '비디오',
  },
  'sample': {
    AppLanguage.zhHans: '样图',
    AppLanguage.zhHant: '樣圖',
    AppLanguage.en: 'Sample',
    AppLanguage.ms: 'Contoh',
    AppLanguage.ja: 'サンプル',
    AppLanguage.ko: '샘플',
  },
  'manage': {
    AppLanguage.zhHans: '管理',
    AppLanguage.zhHant: '管理',
    AppLanguage.en: 'Manage',
    AppLanguage.ms: 'Urus',
    AppLanguage.ja: '管理',
    AppLanguage.ko: '관리',
  },
  'cameraInitializing': {
    AppLanguage.zhHans: '相机初始化中...',
    AppLanguage.zhHant: '相機初始化中...',
    AppLanguage.en: 'Initializing camera...',
    AppLanguage.ms: 'Memulakan kamera...',
    AppLanguage.ja: 'カメラ初期化中...',
    AppLanguage.ko: '카메라 초기화 중...',
  },
  'importPhoto': {
    AppLanguage.zhHans: '导入图片',
    AppLanguage.zhHant: '匯入圖片',
    AppLanguage.en: 'Import Photo',
    AppLanguage.ms: 'Import Foto',
    AppLanguage.ja: '写真をインポート',
    AppLanguage.ko: '사진 가져오기',
  },
  'timer': {
    AppLanguage.zhHans: '倒计时',
    AppLanguage.zhHant: '倒數時',
    AppLanguage.en: 'Timer',
    AppLanguage.ms: 'Pemasa',
    AppLanguage.ja: 'タイマー',
    AppLanguage.ko: '타이머',
  },
  'timerOff': {
    AppLanguage.zhHans: '倒计时关闭',
    AppLanguage.zhHant: '倒數時關閉',
    AppLanguage.en: 'Timer Off',
    AppLanguage.ms: 'Pemasa Mati',
    AppLanguage.ja: 'タイマーオフ',
    AppLanguage.ko: '타이머 끔',
  },
  'timerSeconds': {
    AppLanguage.zhHans: '倒计时 {n}s',
    AppLanguage.zhHant: '倒數時 {n}s',
    AppLanguage.en: 'Timer {n}s',
    AppLanguage.ms: 'Pemasa {n}s',
    AppLanguage.ja: 'タイマー {n}s',
    AppLanguage.ko: '타이머 {n}s',
  },
  'flash': {
    AppLanguage.zhHans: '闪光灯',
    AppLanguage.zhHant: '閃光燈',
    AppLanguage.en: 'Flash',
    AppLanguage.ms: 'Kilat',
    AppLanguage.ja: 'フラッシュ',
    AppLanguage.ko: '플래시',
  },
  'flashOff': {
    AppLanguage.zhHans: '闪光灯已关闭',
    AppLanguage.zhHant: '閃光燈已關閉',
    AppLanguage.en: 'Flash Off',
    AppLanguage.ms: 'Kilat Mati',
    AppLanguage.ja: 'フラッシュオフ',
    AppLanguage.ko: '플래시 끔',
  },
  'flashOn': {
    AppLanguage.zhHans: '闪光灯已开启',
    AppLanguage.zhHant: '閃光燈已開啟',
    AppLanguage.en: 'Flash On',
    AppLanguage.ms: 'Kilat Hidup',
    AppLanguage.ja: 'フラッシュオン',
    AppLanguage.ko: '플래시 켬',
  },
  'flashAuto': {
    AppLanguage.zhHans: '闪光灯自动',
    AppLanguage.zhHant: '閃光燈自動',
    AppLanguage.en: 'Flash Auto',
    AppLanguage.ms: 'Kilat Auto',
    AppLanguage.ja: 'フラッシュ自動',
    AppLanguage.ko: '플래시 자동',
  },
  'rear': {
    AppLanguage.zhHans: '后置',
    AppLanguage.zhHant: '後置',
    AppLanguage.en: 'Rear',
    AppLanguage.ms: 'Belakang',
    AppLanguage.ja: '背面',
    AppLanguage.ko: '후면',
  },
  'gridOn': {
    AppLanguage.zhHans: '网格线开启',
    AppLanguage.zhHant: '網格線開啟',
    AppLanguage.en: 'Grid On',
    AppLanguage.ms: 'Grid Hidup',
    AppLanguage.ja: 'グリッドオン',
    AppLanguage.ko: '격자 켬',
  },
  'gridOff': {
    AppLanguage.zhHans: '网格线关闭',
    AppLanguage.zhHant: '網格線關閉',
    AppLanguage.en: 'Grid Off',
    AppLanguage.ms: 'Grid Mati',
    AppLanguage.ja: 'グリッドオフ',
    AppLanguage.ko: '격자 끔',
  },
  'sharpness': {
    AppLanguage.zhHans: '清晰度',
    AppLanguage.zhHant: '清晰度',
    AppLanguage.en: 'Sharpness',
    AppLanguage.ms: 'Ketajaman',
    AppLanguage.ja: 'シャープネス',
    AppLanguage.ko: '선명도',
  },
  'minimapOn': {
    AppLanguage.zhHans: '小框模式开启',
    AppLanguage.zhHant: '小框模式開啟',
    AppLanguage.en: 'Minimap On',
    AppLanguage.ms: 'Minimap Hidup',
    AppLanguage.ja: 'ミニマップオン',
    AppLanguage.ko: '미니맵 켬',
  },
  'minimapOff': {
    AppLanguage.zhHans: '小框模式关闭',
    AppLanguage.zhHant: '小框模式關閉',
    AppLanguage.en: 'Minimap Off',
    AppLanguage.ms: 'Minimap Mati',
    AppLanguage.ja: 'ミニマップオフ',
    AppLanguage.ko: '미니맵 끔',
  },
  'minimapHintOn': {
    AppLanguage.zhHans: '小窗模式已开启',
    AppLanguage.zhHant: '小窗模式已開啟',
    AppLanguage.en: 'Minimap Enabled',
    AppLanguage.ms: 'Minimap Diaktifkan',
    AppLanguage.ja: 'ミニマップ有効',
    AppLanguage.ko: '미니맵 활성화',
  },
  'minimapHintOff': {
    AppLanguage.zhHans: '小窗模式已关闭',
    AppLanguage.zhHant: '小窗模式已關閉',
    AppLanguage.en: 'Minimap Disabled',
    AppLanguage.ms: 'Minimap Dimatikan',
    AppLanguage.ja: 'ミニマップ無効',
    AppLanguage.ko: '미니맵 비활성화',
  },
  'doubleExpOn': {
    AppLanguage.zhHans: '双重曝光开启',
    AppLanguage.zhHant: '雙重曝光開啟',
    AppLanguage.en: 'Double Exp On',
    AppLanguage.ms: 'Eksp Ganda Hidup',
    AppLanguage.ja: '多重露光オン',
    AppLanguage.ko: '이중 노출 켬',
  },
  'doubleExpOff': {
    AppLanguage.zhHans: '双重曝光关闭',
    AppLanguage.zhHant: '雙重曝光關閉',
    AppLanguage.en: 'Double Exp Off',
    AppLanguage.ms: 'Eksp Ganda Mati',
    AppLanguage.ja: '多重露光オフ',
    AppLanguage.ko: '이중 노출 끔',
  },
  'doubleExpStart': {
    AppLanguage.zhHans: '双重曝光开启，请拍第 1 张',
    AppLanguage.zhHant: '雙重曝光開啟，請拍第 1 張',
    AppLanguage.en: 'Double Exp On, take shot 1',
    AppLanguage.ms: 'Eksp Ganda Hidup, ambil gambar 1',
    AppLanguage.ja: '多重露光オン、1枚目を撮影',
    AppLanguage.ko: '이중 노출 켬, 1번째 촬영',
  },
  'doubleExpDisabled': {
    AppLanguage.zhHans: '双重曝光已关闭',
    AppLanguage.zhHant: '雙重曝光已關閉',
    AppLanguage.en: 'Double Exp Disabled',
    AppLanguage.ms: 'Eksp Ganda Dimatikan',
    AppLanguage.ja: '多重露光無効',
    AppLanguage.ko: '이중 노출 비활성화',
  },
  'doubleExpDone': {
    AppLanguage.zhHans: '双重曝光已完成',
    AppLanguage.zhHant: '雙重曝光已完成',
    AppLanguage.en: 'Double Exp Done',
    AppLanguage.ms: 'Eksp Ganda Selesai',
    AppLanguage.ja: '多重露光完了',
    AppLanguage.ko: '이중 노출 완료',
  },
  'locationOn': {
    AppLanguage.zhHans: '位置开启',
    AppLanguage.zhHant: '位置開啟',
    AppLanguage.en: 'Location On',
    AppLanguage.ms: 'Lokasi Hidup',
    AppLanguage.ja: '位置情報オン',
    AppLanguage.ko: '위치 켬',
  },
  'locationOff': {
    AppLanguage.zhHans: '位置关闭',
    AppLanguage.zhHant: '位置關閉',
    AppLanguage.en: 'Location Off',
    AppLanguage.ms: 'Lokasi Mati',
    AppLanguage.ja: '位置情報オフ',
    AppLanguage.ko: '위치 끔',
  },
  'locationEnabled': {
    AppLanguage.zhHans: '位置信息已开启',
    AppLanguage.zhHant: '位置資訊已開啟',
    AppLanguage.en: 'Location Enabled',
    AppLanguage.ms: 'Lokasi Diaktifkan',
    AppLanguage.ja: '位置情報有効',
    AppLanguage.ko: '위치 활성화',
  },
  'locationDisabled': {
    AppLanguage.zhHans: '位置信息已关闭',
    AppLanguage.zhHant: '位置資訊已關閉',
    AppLanguage.en: 'Location Disabled',
    AppLanguage.ms: 'Lokasi Dimatikan',
    AppLanguage.ja: '位置情報無効',
    AppLanguage.ko: '위치 비활성화',
  },
  'locationDenied': {
    AppLanguage.zhHans: '位置权限被拒绝',
    AppLanguage.zhHant: '位置權限被拒絕',
    AppLanguage.en: 'Location Permission Denied',
    AppLanguage.ms: 'Kebenaran Lokasi Ditolak',
    AppLanguage.ja: '位置情報の権限が拒否されました',
    AppLanguage.ko: '위치 권한 거부됨',
  },
  'locationPermTitle': {
    AppLanguage.zhHans: '需要位置权限',
    AppLanguage.zhHant: '需要位置權限',
    AppLanguage.en: 'Location Permission Required',
    AppLanguage.ms: 'Kebenaran Lokasi Diperlukan',
    AppLanguage.ja: '位置情報の権限が必要',
    AppLanguage.ko: '위치 권한 필요',
  },
  'locationPermDesc': {
    AppLanguage.zhHans: '请在设置中开启位置权限，以将 GPS 坐标记录到照片',
    AppLanguage.zhHant: '請在設定中開啟位置權限，以將 GPS 坐標記錄到照片',
    AppLanguage.en:
        'Enable location in Settings to record GPS coordinates in photos',
    AppLanguage.ms:
        'Aktifkan lokasi dalam Tetapan untuk merekod koordinat GPS dalam foto',
    AppLanguage.ja: '設定で位置情報を有効にして、写真にGPS座標を記録します',
    AppLanguage.ko: '설정에서 위치를 활성화하여 사진에 GPS 좌표를 기록하세요',
  },
  'debugOn': {
    AppLanguage.zhHans: '调试开启',
    AppLanguage.zhHant: '除錯開啟',
    AppLanguage.en: 'Debug On',
    AppLanguage.ms: 'Debug Hidup',
    AppLanguage.ja: 'デバッグオン',
    AppLanguage.ko: '디버그 켬',
  },
  'debugOff': {
    AppLanguage.zhHans: '调试关闭',
    AppLanguage.zhHant: '除錯關閉',
    AppLanguage.en: 'Debug Off',
    AppLanguage.ms: 'Debug Mati',
    AppLanguage.ja: 'デバッグオフ',
    AppLanguage.ko: '디버그 끔',
  },
  'copyCalibrationInfo': {
    AppLanguage.zhHans: '复制真机校准信息',
    AppLanguage.zhHant: '複製真機校準資訊',
    AppLanguage.en: 'Copy Calibration Device Info',
    AppLanguage.ms: 'Salin Maklumat Kalibrasi Peranti',
    AppLanguage.ja: '実機キャリブレーション情報をコピー',
    AppLanguage.ko: '실기기 보정 정보 복사',
  },
  'copyCalibrationInfoDone': {
    AppLanguage.zhHans: '真机校准信息已复制',
    AppLanguage.zhHant: '真機校準資訊已複製',
    AppLanguage.en: 'Calibration device info copied',
    AppLanguage.ms: 'Maklumat kalibrasi peranti disalin',
    AppLanguage.ja: '実機キャリブレーション情報をコピーしました',
    AppLanguage.ko: '실기기 보정 정보를 복사했습니다',
  },
  'copyCalibrationInfoEmpty': {
    AppLanguage.zhHans: '当前还没有可用的真机信息，请先打开相机预览',
    AppLanguage.zhHant: '目前還沒有可用的真機資訊，請先打開相機預覽',
    AppLanguage.en: 'No device info yet. Open the camera preview first.',
    AppLanguage.ms: 'Belum ada maklumat peranti. Buka pratonton kamera dahulu.',
    AppLanguage.ja: 'まだ実機情報がありません。先にカメラプレビューを開いてください。',
    AppLanguage.ko: '아직 기기 정보가 없습니다. 먼저 카메라 미리보기를 여세요.',
  },
  'goToSettings': {
    AppLanguage.zhHans: '去设置',
    AppLanguage.zhHant: '去設定',
    AppLanguage.en: 'Go to Settings',
    AppLanguage.ms: 'Pergi ke Tetapan',
    AppLanguage.ja: '設定へ',
    AppLanguage.ko: '설정으로',
  },
  'cameraPerm': {
    AppLanguage.zhHans: '需要相机权限',
    AppLanguage.zhHant: '需要相機權限',
    AppLanguage.en: 'Camera Permission Required',
    AppLanguage.ms: 'Kebenaran Kamera Diperlukan',
    AppLanguage.ja: 'カメラの権限が必要',
    AppLanguage.ko: '카메라 권한 필요',
  },
  'cameraPermDesc': {
    AppLanguage.zhHans: '请在设置中开启相机权限以使用拍照功能',
    AppLanguage.zhHant: '請在設定中開啟相機權限以使用拍照功能',
    AppLanguage.en: 'Enable camera access in Settings to take photos',
    AppLanguage.ms: 'Aktifkan akses kamera dalam Tetapan untuk mengambil foto',
    AppLanguage.ja: '設定でカメラアクセスを有効にして写真を撮影します',
    AppLanguage.ko: '설정에서 카메라 접근을 활성화하여 사진을 찍으세요',
  },
  'wbAuto': {
    AppLanguage.zhHans: '自动',
    AppLanguage.zhHant: '自動',
    AppLanguage.en: 'Auto',
    AppLanguage.ms: 'Auto',
    AppLanguage.ja: '自動',
    AppLanguage.ko: '자동',
  },
  'wbDaylight': {
    AppLanguage.zhHans: '日光',
    AppLanguage.zhHant: '日光',
    AppLanguage.en: 'Daylight',
    AppLanguage.ms: 'Siang',
    AppLanguage.ja: '太陽光',
    AppLanguage.ko: '주광',
  },
  'wbIncandescent': {
    AppLanguage.zhHans: '白炎灯',
    AppLanguage.zhHant: '白熾燈',
    AppLanguage.en: 'Incandescent',
    AppLanguage.ms: 'Pijar',
    AppLanguage.ja: '白熱灯',
    AppLanguage.ko: '백열등',
  },
  'doubleExpLabel1': {
    AppLanguage.zhHans: '双重曝光 • 第 1 张',
    AppLanguage.zhHant: '雙重曝光 • 第 1 張',
    AppLanguage.en: 'Double Exp • Shot 1',
    AppLanguage.ms: 'Eksp Ganda • Gambar 1',
    AppLanguage.ja: '多重露光 • 1枚目',
    AppLanguage.ko: '이중 노출 • 1번째',
  },
  'doubleExpLabel2': {
    AppLanguage.zhHans: '双重曝光 • 第 2 张',
    AppLanguage.zhHant: '雙重曝光 • 第 2 張',
    AppLanguage.en: 'Double Exp • Shot 2',
    AppLanguage.ms: 'Eksp Ganda • Gambar 2',
    AppLanguage.ja: '多重露光 • 2枚目',
    AppLanguage.ko: '이중 노출 • 2번째',
  },
  'burstOff': {
    AppLanguage.zhHans: '连拍关闭',
    AppLanguage.zhHant: '連拍關閉',
    AppLanguage.en: 'Burst Off',
    AppLanguage.ms: 'Burst Mati',
    AppLanguage.ja: '連写オフ',
    AppLanguage.ko: '연속 촬영 끔',
  },
  'burstCount': {
    AppLanguage.zhHans: '连拍 {n}张',
    AppLanguage.zhHant: '連拍 {n}張',
    AppLanguage.en: 'Burst {n}',
    AppLanguage.ms: 'Burst {n}',
    AppLanguage.ja: '連写 {n}枚',
    AppLanguage.ko: '연속 {n}장',
  },
  'burstStart': {
    AppLanguage.zhHans: '连拍 {n} 张开始…',
    AppLanguage.zhHant: '連拍 {n} 張開始…',
    AppLanguage.en: 'Burst {n} shots starting…',
    AppLanguage.ms: 'Burst {n} gambar bermula…',
    AppLanguage.ja: '連写 {n}枚 開始…',
    AppLanguage.ko: '연속 {n}장 시작…',
  },
  'burstDone': {
    AppLanguage.zhHans: '连拍完成，共 {n} 张',
    AppLanguage.zhHant: '連拍完成，共 {n} 張',
    AppLanguage.en: 'Burst done, {n} shots',
    AppLanguage.ms: 'Burst selesai, {n} gambar',
    AppLanguage.ja: '連写完了、{n}枚',
    AppLanguage.ko: '연속 촬영 완료, {n}장',
  },
  'captured1': {
    AppLanguage.zhHans: '已捕捉第 1 张，请拍第 2 张',
    AppLanguage.zhHant: '已捕捉第 1 張，請拍第 2 張',
    AppLanguage.en: 'Shot 1 captured, take shot 2',
    AppLanguage.ms: 'Gambar 1 diambil, ambil gambar 2',
    AppLanguage.ja: '1枚目撮影済み、2枚目を撮影',
    AppLanguage.ko: '1번째 촬영 완료, 2번째 촬영하세요',
  },
  'compositing': {
    AppLanguage.zhHans: '合成中…',
    AppLanguage.zhHant: '合成中…',
    AppLanguage.en: 'Compositing…',
    AppLanguage.ms: 'Menggabungkan…',
    AppLanguage.ja: '合成中…',
    AppLanguage.ko: '합성 중…',
  },
  'unlockAll': {
    AppLanguage.zhHans: '解锁所有相机和配件。',
    AppLanguage.zhHant: '解鎖所有相機和配件。',
    AppLanguage.en: 'Unlock all cameras and accessories.',
    AppLanguage.ms: 'Buka kunci semua kamera dan aksesori.',
    AppLanguage.ja: 'すべてのカメラとアクセサリーをアンロック。',
    AppLanguage.ko: '모든 카메라와 액세서리 잠금 해제.',
  },
  'leakLight': {
    AppLanguage.zhHans: '漏光',
    AppLanguage.zhHant: '漏光',
    AppLanguage.en: 'Leak',
    AppLanguage.ms: 'Bocor',
    AppLanguage.ja: '光漏れ',
    AppLanguage.ko: '빛 누출',
  },
  'grain': {
    AppLanguage.zhHans: '颗粒',
    AppLanguage.zhHant: '顆粒',
    AppLanguage.en: 'Grain',
    AppLanguage.ms: 'Butiran',
    AppLanguage.ja: 'グレイン',
    AppLanguage.ko: '그레인',
  },
  'vignette': {
    AppLanguage.zhHans: '暗角',
    AppLanguage.zhHant: '暗角',
    AppLanguage.en: 'Vignette',
    AppLanguage.ms: 'Vignette',
    AppLanguage.ja: 'ビネット',
    AppLanguage.ko: '비네트',
  },
  'frame': {
    AppLanguage.zhHans: '边框',
    AppLanguage.zhHant: '邊框',
    AppLanguage.en: 'Frame',
    AppLanguage.ms: 'Bingkai',
    AppLanguage.ja: 'フレーム',
    AppLanguage.ko: '프레임',
  },
  'color': {
    AppLanguage.zhHans: '色彩',
    AppLanguage.zhHant: '色彩',
    AppLanguage.en: 'Color',
    AppLanguage.ms: 'Warna',
    AppLanguage.ja: 'カラー',
    AppLanguage.ko: '색상',
  },
  'countdownTimer': {
    AppLanguage.zhHans: '计时',
    AppLanguage.zhHant: '計時',
    AppLanguage.en: 'Timer',
    AppLanguage.ms: 'Pemasa',
    AppLanguage.ja: 'タイマー',
    AppLanguage.ko: '타이머',
  },
  'ratio': {
    AppLanguage.zhHans: '比例',
    AppLanguage.zhHant: '比例',
    AppLanguage.en: 'Ratio',
    AppLanguage.ms: 'Nisbah',
    AppLanguage.ja: '比率',
    AppLanguage.ko: '비율',
  },
  'watermark': {
    AppLanguage.zhHans: '水印',
    AppLanguage.zhHant: '浮水印',
    AppLanguage.en: 'Watermark',
    AppLanguage.ms: 'Tera Air',
    AppLanguage.ja: 'ウォーターマーク',
    AppLanguage.ko: '워터마크',
  },
  'allPhotos': {
    AppLanguage.zhHans: '全部照片',
    AppLanguage.zhHant: '全部照片',
    AppLanguage.en: 'All Photos',
    AppLanguage.ms: 'Semua Foto',
    AppLanguage.ja: 'すべての写真',
    AppLanguage.ko: '모든 사진',
  },
  'favorites': {
    AppLanguage.zhHans: '喜好项目',
    AppLanguage.zhHant: '喜好項目',
    AppLanguage.en: 'Favorites',
    AppLanguage.ms: 'Kegemaran',
    AppLanguage.ja: 'お気に入り',
    AppLanguage.ko: '즐겨찾기',
  },
  'film': {
    AppLanguage.zhHans: '底片',
    AppLanguage.zhHant: '底片',
    AppLanguage.en: 'Film',
    AppLanguage.ms: 'Filem',
    AppLanguage.ja: 'フィルム',
    AppLanguage.ko: '필름',
  },
  'noPhotos': {
    AppLanguage.zhHans: '还没有照片',
    AppLanguage.zhHant: '還沒有照片',
    AppLanguage.en: 'No Photos Yet',
    AppLanguage.ms: 'Tiada Foto Lagi',
    AppLanguage.ja: 'まだ写真がありません',
    AppLanguage.ko: '아직 사진이 없습니다',
  },
  'noPhotoHint': {
    AppLanguage.zhHans: '用 DAZZ 拍摄的照片会出现在这里',
    AppLanguage.zhHant: '用 DAZZ 拍攝的照片會出現在這裡',
    AppLanguage.en: 'Photos taken with DAZZ will appear here',
    AppLanguage.ms: 'Foto yang diambil dengan DAZZ akan muncul di sini',
    AppLanguage.ja: 'DAZZで撮影した写真がここに表示されます',
    AppLanguage.ko: 'DAZZ로 찍은 사진이 여기에 표시됩니다',
  },
  'galleryPermDesc': {
    AppLanguage.zhHans: '请在设置中开启相册访问权限，才能查看成片',
    AppLanguage.zhHant: '請在設定中開啟相冊存取權限，才能查看成片',
    AppLanguage.en: 'Enable photo library access in Settings to view photos',
    AppLanguage.ms:
        'Aktifkan akses perpustakaan foto dalam Tetapan untuk melihat foto',
    AppLanguage.ja: '設定でフォトライブラリへのアクセスを有効にして写真を表示します',
    AppLanguage.ko: '설정에서 사진 라이브러리 접근을 활성화하여 사진을 보세요',
  },
  'shareFailed': {
    AppLanguage.zhHans: '分享失败',
    AppLanguage.zhHant: '分享失敗',
    AppLanguage.en: 'Share Failed',
    AppLanguage.ms: 'Kongsi Gagal',
    AppLanguage.ja: '共有失敗',
    AppLanguage.ko: '공유 실패',
  },
  'photoSaved': {
    AppLanguage.zhHans: '照片已保存在相册中',
    AppLanguage.zhHant: '照片已儲存在相冊中',
    AppLanguage.en: 'Photo saved to gallery',
    AppLanguage.ms: 'Foto disimpan ke galeri',
    AppLanguage.ja: '写真がギャラリーに保存されました',
    AppLanguage.ko: '사진이 갤러리에 저장되었습니다',
  },
  'deletePhoto': {
    AppLanguage.zhHans: '删除照片',
    AppLanguage.zhHant: '刪除照片',
    AppLanguage.en: 'Delete Photo',
    AppLanguage.ms: 'Padam Foto',
    AppLanguage.ja: '写真を削除',
    AppLanguage.ko: '사진 삭제',
  },
  'deleteConfirm': {
    AppLanguage.zhHans: '确定要删除这张照片吗？',
    AppLanguage.zhHant: '確定要刪除這張照片嗎？',
    AppLanguage.en: 'Are you sure you want to delete this photo?',
    AppLanguage.ms: 'Adakah anda pasti mahu memadamkan foto ini?',
    AppLanguage.ja: 'この写真を削除しますか？',
    AppLanguage.ko: '이 사진을 삭제하시겠습니까?',
  },
  'delete': {
    AppLanguage.zhHans: '删除',
    AppLanguage.zhHant: '刪除',
    AppLanguage.en: 'Delete',
    AppLanguage.ms: 'Padam',
    AppLanguage.ja: '削除',
    AppLanguage.ko: '삭제',
  },
  'select': {
    AppLanguage.zhHans: '选择',
    AppLanguage.zhHant: '選擇',
    AppLanguage.en: 'Select',
    AppLanguage.ms: 'Pilih',
    AppLanguage.ja: '選択',
    AppLanguage.ko: '선택',
  },
  // 图片编辑
  'selectCamera': {
    AppLanguage.zhHans: '选择相机',
    AppLanguage.zhHant: '選擇相機',
    AppLanguage.en: 'Select Camera',
    AppLanguage.ms: 'Pilih Kamera',
    AppLanguage.ja: 'カメラを選択',
    AppLanguage.ko: '카메라 선택',
  },
  'edit': {
    AppLanguage.zhHans: '编辑',
    AppLanguage.zhHant: '編輯',
    AppLanguage.en: 'Edit',
    AppLanguage.ms: 'Edit',
    AppLanguage.ja: '編集',
    AppLanguage.ko: '편집',
  },
  'save': {
    AppLanguage.zhHans: '保存',
    AppLanguage.zhHant: '儲存',
    AppLanguage.en: 'Save',
    AppLanguage.ms: 'Simpan',
    AppLanguage.ja: '保存',
    AppLanguage.ko: '저장',
  },
  'saveFailed': {
    AppLanguage.zhHans: '保存失败',
    AppLanguage.zhHant: '儲存失敗',
    AppLanguage.en: 'Save Failed',
    AppLanguage.ms: 'Simpan Gagal',
    AppLanguage.ja: '保存失敗',
    AppLanguage.ko: '저장 실패',
  },
  'saveFailedRetry': {
    AppLanguage.zhHans: '保存失败，请重试',
    AppLanguage.zhHant: '儲存失敗，請重試',
    AppLanguage.en: 'Save failed, please retry',
    AppLanguage.ms: 'Simpan gagal, sila cuba lagi',
    AppLanguage.ja: '保存に失敗しました。再試行してください',
    AppLanguage.ko: '저장 실패, 다시 시도하세요',
  },
  'savedToGallery': {
    AppLanguage.zhHans: '已保存到相册',
    AppLanguage.zhHant: '已儲存到相冊',
    AppLanguage.en: 'Saved to Gallery',
    AppLanguage.ms: 'Disimpan ke Galeri',
    AppLanguage.ja: 'ギャラリーに保存しました',
    AppLanguage.ko: '갤러리에 저장되었습니다',
  },
  'needGalleryPerm': {
    AppLanguage.zhHans: '需要相册权限才能保存',
    AppLanguage.zhHant: '需要相冊權限才能儲存',
    AppLanguage.en: 'Gallery permission required to save',
    AppLanguage.ms: 'Kebenaran galeri diperlukan untuk menyimpan',
    AppLanguage.ja: '保存するにはギャラリーの権限が必要です',
    AppLanguage.ko: '저장하려면 갤러리 권한이 필요합니다',
  },
  'processFailed': {
    AppLanguage.zhHans: '图片处理失败',
    AppLanguage.zhHant: '圖片處理失敗',
    AppLanguage.en: 'Image processing failed',
    AppLanguage.ms: 'Pemprosesan imej gagal',
    AppLanguage.ja: '画像処理に失敗しました',
    AppLanguage.ko: '이미지 처리 실패',
  },
  'selectCameraFirst': {
    AppLanguage.zhHans: '请先选择相机',
    AppLanguage.zhHant: '請先選擇相機',
    AppLanguage.en: 'Please select a camera first',
    AppLanguage.ms: 'Sila pilih kamera dahulu',
    AppLanguage.ja: 'まずカメラを選択してください',
    AppLanguage.ko: '먼저 카메라를 선택하세요',
  },
  'editTab': {
    AppLanguage.zhHans: '编辑',
    AppLanguage.zhHant: '編輯',
    AppLanguage.en: 'Edit',
    AppLanguage.ms: 'Edit',
    AppLanguage.ja: '編集',
    AppLanguage.ko: '편집',
  },
  'filterTab': {
    AppLanguage.zhHans: '滤镜',
    AppLanguage.zhHant: '濾鏡',
    AppLanguage.en: 'Filter',
    AppLanguage.ms: 'Penapis',
    AppLanguage.ja: 'フィルター',
    AppLanguage.ko: '필터',
  },
  'frameTab': {
    AppLanguage.zhHans: '边框',
    AppLanguage.zhHant: '邊框',
    AppLanguage.en: 'Frame',
    AppLanguage.ms: 'Bingkai',
    AppLanguage.ja: 'フレーム',
    AppLanguage.ko: '프레임',
  },
  'watermarkTab': {
    AppLanguage.zhHans: '水印',
    AppLanguage.zhHant: '浮水印',
    AppLanguage.en: 'Watermark',
    AppLanguage.ms: 'Tera Air',
    AppLanguage.ja: 'ウォーターマーク',
    AppLanguage.ko: '워터마크',
  },
  'flipTab': {
    AppLanguage.zhHans: '翻转',
    AppLanguage.zhHant: '翻轉',
    AppLanguage.en: 'Flip',
    AppLanguage.ms: 'Balik',
    AppLanguage.ja: '反転',
    AppLanguage.ko: '뒤집기',
  },
  'cropTab': {
    AppLanguage.zhHans: '裁剪',
    AppLanguage.zhHant: '裁剪',
    AppLanguage.en: 'Crop',
    AppLanguage.ms: 'Potong',
    AppLanguage.ja: 'トリミング',
    AppLanguage.ko: '자르기',
  },
  'none': {
    AppLanguage.zhHans: '无',
    AppLanguage.zhHant: '無',
    AppLanguage.en: 'None',
    AppLanguage.ms: 'Tiada',
    AppLanguage.ja: 'なし',
    AppLanguage.ko: '없음',
  },
  // 相机配置面板
  'timeWatermark': {
    AppLanguage.zhHans: '时间水印',
    AppLanguage.zhHant: '時間浮水印',
    AppLanguage.en: 'Time Watermark',
    AppLanguage.ms: 'Tera Air Masa',
    AppLanguage.ja: '時刻ウォーターマーク',
    AppLanguage.ko: '시간 워터마크',
  },
  'frameBorder': {
    AppLanguage.zhHans: '边框',
    AppLanguage.zhHant: '邊框',
    AppLanguage.en: 'Frame',
    AppLanguage.ms: 'Bingkai',
    AppLanguage.ja: 'フレーム',
    AppLanguage.ko: '프레임',
  },
  'originalRatio': {
    AppLanguage.zhHans: '原比例',
    AppLanguage.zhHant: '原比例',
    AppLanguage.en: 'Original',
    AppLanguage.ms: 'Asal',
    AppLanguage.ja: 'オリジナル',
    AppLanguage.ko: '원본',
  },
  'filter': {
    AppLanguage.zhHans: '滤镜',
    AppLanguage.zhHant: '濾鏡',
    AppLanguage.en: 'Filter',
    AppLanguage.ms: 'Penapis',
    AppLanguage.ja: 'フィルター',
    AppLanguage.ko: '필터',
  },
  'noWatermark': {
    AppLanguage.zhHans: '无水印',
    AppLanguage.zhHant: '無浮水印',
    AppLanguage.en: 'No Watermark',
    AppLanguage.ms: 'Tiada Tera Air',
    AppLanguage.ja: 'ウォーターマークなし',
    AppLanguage.ko: '워터마크 없음',
  },
  'colorLabel': {
    AppLanguage.zhHans: '颜色',
    AppLanguage.zhHant: '顏色',
    AppLanguage.en: 'Color',
    AppLanguage.ms: 'Warna',
    AppLanguage.ja: '色',
    AppLanguage.ko: '색상',
  },
  'styleLabel': {
    AppLanguage.zhHans: '样式',
    AppLanguage.zhHant: '樣式',
    AppLanguage.en: 'Style',
    AppLanguage.ms: 'Gaya',
    AppLanguage.ja: 'スタイル',
    AppLanguage.ko: '스타일',
  },
  'positionLabel': {
    AppLanguage.zhHans: '位置',
    AppLanguage.zhHant: '位置',
    AppLanguage.en: 'Position',
    AppLanguage.ms: 'Kedudukan',
    AppLanguage.ja: '位置',
    AppLanguage.ko: '위치',
  },
  'directionLabel': {
    AppLanguage.zhHans: '方向',
    AppLanguage.zhHant: '方向',
    AppLanguage.en: 'Direction',
    AppLanguage.ms: 'Arah',
    AppLanguage.ja: '方向',
    AppLanguage.ko: '방향',
  },
  'sizeLabel': {
    AppLanguage.zhHans: '大小',
    AppLanguage.zhHant: '大小',
    AppLanguage.en: 'Size',
    AppLanguage.ms: 'Saiz',
    AppLanguage.ja: 'サイズ',
    AppLanguage.ko: '크기',
  },
  'horizontal': {
    AppLanguage.zhHans: '水平',
    AppLanguage.zhHant: '水平',
    AppLanguage.en: 'Horizontal',
    AppLanguage.ms: 'Mendatar',
    AppLanguage.ja: '横',
    AppLanguage.ko: '가로',
  },
  'vertical': {
    AppLanguage.zhHans: '垂直',
    AppLanguage.zhHant: '垂直',
    AppLanguage.en: 'Vertical',
    AppLanguage.ms: 'Menegak',
    AppLanguage.ja: '縦',
    AppLanguage.ko: '세로',
  },
  'sizeSmall': {
    AppLanguage.zhHans: '小',
    AppLanguage.zhHant: '小',
    AppLanguage.en: 'S',
    AppLanguage.ms: 'K',
    AppLanguage.ja: '小',
    AppLanguage.ko: '소',
  },
  'sizeMedium': {
    AppLanguage.zhHans: '中',
    AppLanguage.zhHant: '中',
    AppLanguage.en: 'M',
    AppLanguage.ms: 'S',
    AppLanguage.ja: '中',
    AppLanguage.ko: '중',
  },
  'sizeLarge': {
    AppLanguage.zhHans: '大',
    AppLanguage.zhHant: '大',
    AppLanguage.en: 'L',
    AppLanguage.ms: 'B',
    AppLanguage.ja: '大',
    AppLanguage.ko: '대',
  },
  'frameRatioHint': {
    AppLanguage.zhHans: '仅1:1和4:3支持显示边框',
    AppLanguage.zhHant: '僅1:1和4:3支援顯示邊框',
    AppLanguage.en: 'Frame only supported for 1:1 and 4:3 ratios',
    AppLanguage.ms: 'Bingkai hanya disokong untuk nisbah 1:1 dan 4:3',
    AppLanguage.ja: 'フレームは1:1と4:3のみ対応',
    AppLanguage.ko: '프레임은 1:1 및 4:3 비율만 지원',
  },
  'noFrame': {
    AppLanguage.zhHans: '无边框',
    AppLanguage.zhHant: '無邊框',
    AppLanguage.en: 'No Frame',
    AppLanguage.ms: 'Tiada Bingkai',
    AppLanguage.ja: 'フレームなし',
    AppLanguage.ko: '프레임 없음',
  },
  'styleTab': {
    AppLanguage.zhHans: '样式',
    AppLanguage.zhHant: '樣式',
    AppLanguage.en: 'Style',
    AppLanguage.ms: 'Gaya',
    AppLanguage.ja: 'スタイル',
    AppLanguage.ko: '스타일',
  },
  'backgroundTab': {
    AppLanguage.zhHans: '背景',
    AppLanguage.zhHant: '背景',
    AppLanguage.en: 'Background',
    AppLanguage.ms: 'Latar',
    AppLanguage.ja: '背景',
    AppLanguage.ko: '배경',
  },
  'topLeft': {
    AppLanguage.zhHans: '左上',
    AppLanguage.zhHant: '左上',
    AppLanguage.en: 'Top Left',
    AppLanguage.ms: 'Kiri Atas',
    AppLanguage.ja: '左上',
    AppLanguage.ko: '왼쪽 위',
  },
  'topCenter': {
    AppLanguage.zhHans: '上中',
    AppLanguage.zhHant: '上中',
    AppLanguage.en: 'Top Center',
    AppLanguage.ms: 'Tengah Atas',
    AppLanguage.ja: '上中央',
    AppLanguage.ko: '위 가운데',
  },
  'topRight': {
    AppLanguage.zhHans: '右上',
    AppLanguage.zhHant: '右上',
    AppLanguage.en: 'Top Right',
    AppLanguage.ms: 'Kanan Atas',
    AppLanguage.ja: '右上',
    AppLanguage.ko: '오른쪽 위',
  },
  'bottomLeft': {
    AppLanguage.zhHans: '左下',
    AppLanguage.zhHant: '左下',
    AppLanguage.en: 'Bottom Left',
    AppLanguage.ms: 'Kiri Bawah',
    AppLanguage.ja: '左下',
    AppLanguage.ko: '왼쪽 아래',
  },
  'bottomCenter': {
    AppLanguage.zhHans: '下中',
    AppLanguage.zhHant: '下中',
    AppLanguage.en: 'Bottom Center',
    AppLanguage.ms: 'Tengah Bawah',
    AppLanguage.ja: '下中央',
    AppLanguage.ko: '아래 가운데',
  },
  'bottomRight': {
    AppLanguage.zhHans: '右下',
    AppLanguage.zhHant: '右下',
    AppLanguage.en: 'Bottom Right',
    AppLanguage.ms: 'Kanan Bawah',
    AppLanguage.ja: '右下',
    AppLanguage.ko: '오른쪽 아래',
  },
  // 相机管理
  'cameraManage': {
    AppLanguage.zhHans: '相机管理',
    AppLanguage.zhHant: '相機管理',
    AppLanguage.en: 'Camera Management',
    AppLanguage.ms: 'Pengurusan Kamera',
    AppLanguage.ja: 'カメラ管理',
    AppLanguage.ko: '카메라 관리',
  },
  'loadFailed': {
    AppLanguage.zhHans: '加载失败',
    AppLanguage.zhHant: '載入失敗',
    AppLanguage.en: 'Load Failed',
    AppLanguage.ms: 'Muat Gagal',
    AppLanguage.ja: '読み込み失敗',
    AppLanguage.ko: '로드 실패',
  },
  'favoritesCam': {
    AppLanguage.zhHans: '收藏夹',
    AppLanguage.zhHant: '收藏夾',
    AppLanguage.en: 'Favorites',
    AppLanguage.ms: 'Kegemaran',
    AppLanguage.ja: 'お気に入り',
    AppLanguage.ko: '즐겨찾기',
  },
  'moreCameras': {
    AppLanguage.zhHans: '更多相机',
    AppLanguage.zhHant: '更多相機',
    AppLanguage.en: 'More Cameras',
    AppLanguage.ms: 'Lebih Kamera',
    AppLanguage.ja: 'その他のカメラ',
    AppLanguage.ko: '더 많은 카메라',
  },
  'noFavCam': {
    AppLanguage.zhHans: '暂无收藏相机',
    AppLanguage.zhHant: '暫無收藏相機',
    AppLanguage.en: 'No favorite cameras',
    AppLanguage.ms: 'Tiada kamera kegemaran',
    AppLanguage.ja: 'お気に入りのカメラなし',
    AppLanguage.ko: '즐겨찾기 카메라 없음',
  },
  'noCam': {
    AppLanguage.zhHans: '暂无相机',
    AppLanguage.zhHant: '暫無相機',
    AppLanguage.en: 'No cameras',
    AppLanguage.ms: 'Tiada kamera',
    AppLanguage.ja: 'カメラなし',
    AppLanguage.ko: '카메라 없음',
  },
  // 低中高
  'low': {
    AppLanguage.zhHans: '低',
    AppLanguage.zhHant: '低',
    AppLanguage.en: 'Low',
    AppLanguage.ms: 'Rendah',
    AppLanguage.ja: '低',
    AppLanguage.ko: '낮음',
  },
  'medium': {
    AppLanguage.zhHans: '中',
    AppLanguage.zhHant: '中',
    AppLanguage.en: 'Medium',
    AppLanguage.ms: 'Sederhana',
    AppLanguage.ja: '中',
    AppLanguage.ko: '중간',
  },
  'high': {
    AppLanguage.zhHans: '高',
    AppLanguage.zhHant: '高',
    AppLanguage.en: 'High',
    AppLanguage.ms: 'Tinggi',
    AppLanguage.ja: '高',
    AppLanguage.ko: '높음',
  },
  // 拍摄界面场景提示
  'sceneHintBalanced': {
    AppLanguage.zhHans: '均衡场景',
    AppLanguage.zhHant: '均衡場景',
    AppLanguage.en: 'Balanced Scene',
    AppLanguage.ms: 'Adegan Seimbang',
    AppLanguage.ja: 'バランスシーン',
    AppLanguage.ko: '균형 장면',
  },
  'sceneHintLowLight': {
    AppLanguage.zhHans: '低光场景',
    AppLanguage.zhHant: '低光場景',
    AppLanguage.en: 'Low Light Scene',
    AppLanguage.ms: 'Adegan Cahaya Rendah',
    AppLanguage.ja: '低照度シーン',
    AppLanguage.ko: '저조도 장면',
  },
  'sceneHintBacklit': {
    AppLanguage.zhHans: '强光逆光',
    AppLanguage.zhHant: '強光逆光',
    AppLanguage.en: 'Backlit Scene',
    AppLanguage.ms: 'Adegan Cahaya Latar',
    AppLanguage.ja: '逆光シーン',
    AppLanguage.ko: '역광 장면',
  },
  'sceneHintIndoor': {
    AppLanguage.zhHans: '室内暖光',
    AppLanguage.zhHant: '室內暖光',
    AppLanguage.en: 'Indoor Warm Light',
    AppLanguage.ms: 'Cahaya Dalaman Hangat',
    AppLanguage.ja: '室内暖色光',
    AppLanguage.ko: '실내 난색광',
  },
  'sceneHintOutdoor': {
    AppLanguage.zhHans: '户外日光',
    AppLanguage.zhHant: '戶外日光',
    AppLanguage.en: 'Outdoor Daylight',
    AppLanguage.ms: 'Cahaya Siang Luar',
    AppLanguage.ja: '屋外日中光',
    AppLanguage.ko: '야외 주광',
  },
  'sceneHintPortrait': {
    AppLanguage.zhHans: '人像场景',
    AppLanguage.zhHant: '人像場景',
    AppLanguage.en: 'Portrait Scene',
    AppLanguage.ms: 'Adegan Potret',
    AppLanguage.ja: 'ポートレート',
    AppLanguage.ko: '인물 장면',
  },
  'sceneHintMacro': {
    AppLanguage.zhHans: '近摄场景',
    AppLanguage.zhHant: '近攝場景',
    AppLanguage.en: 'Macro Scene',
    AppLanguage.ms: 'Adegan Makro',
    AppLanguage.ja: 'マクロシーン',
    AppLanguage.ko: '접사 장면',
  },
  'sceneHintFisheye': {
    AppLanguage.zhHans: '鱼眼场景',
    AppLanguage.zhHant: '魚眼場景',
    AppLanguage.en: 'Fisheye Scene',
    AppLanguage.ms: 'Adegan Fisheye',
    AppLanguage.ja: '魚眼シーン',
    AppLanguage.ko: '어안 장면',
  },
  'sceneHintHighRes': {
    AppLanguage.zhHans: '高像素场景',
    AppLanguage.zhHant: '高像素場景',
    AppLanguage.en: 'High Resolution Scene',
    AppLanguage.ms: 'Adegan Resolusi Tinggi',
    AppLanguage.ja: '高解像度シーン',
    AppLanguage.ko: '고해상도 장면',
  },
  // ── 水印/相框配置面板 Tab 标签 ──
  'wmColor': {
    AppLanguage.zhHans: '颜色',
    AppLanguage.zhHant: '顏色',
    AppLanguage.en: 'Color',
    AppLanguage.ms: 'Warna',
    AppLanguage.ja: 'カラー',
    AppLanguage.ko: '색상',
  },
  'wmStyle': {
    AppLanguage.zhHans: '样式',
    AppLanguage.zhHant: '樣式',
    AppLanguage.en: 'Style',
    AppLanguage.ms: 'Gaya',
    AppLanguage.ja: 'スタイル',
    AppLanguage.ko: '스타일',
  },
  'wmPosition': {
    AppLanguage.zhHans: '位置',
    AppLanguage.zhHant: '位置',
    AppLanguage.en: 'Position',
    AppLanguage.ms: 'Kedudukan',
    AppLanguage.ja: '位置',
    AppLanguage.ko: '위치',
  },
  'wmDirection': {
    AppLanguage.zhHans: '方向',
    AppLanguage.zhHant: '方向',
    AppLanguage.en: 'Direction',
    AppLanguage.ms: 'Arah',
    AppLanguage.ja: '方向',
    AppLanguage.ko: '방향',
  },
  'wmSize': {
    AppLanguage.zhHans: '大小',
    AppLanguage.zhHant: '大小',
    AppLanguage.en: 'Size',
    AppLanguage.ms: 'Saiz',
    AppLanguage.ja: 'サイズ',
    AppLanguage.ko: '크기',
  },
  'frameBackground': {
    AppLanguage.zhHans: '背景',
    AppLanguage.zhHant: '背景',
    AppLanguage.en: 'Background',
    AppLanguage.ms: 'Latar',
    AppLanguage.ja: '背景',
    AppLanguage.ko: '배경',
  },
  'lens': {
    AppLanguage.zhHans: '镜头',
    AppLanguage.zhHant: '鏡頭',
    AppLanguage.en: 'Lens',
    AppLanguage.ms: 'Kanta',
    AppLanguage.ja: 'レンズ',
    AppLanguage.ko: '렌즈',
  },
  // ── 相册权限/空状态/删除确认 ──
  'galleryPermissionHint': {
    AppLanguage.zhHans: '请开启相册访问权限',
    AppLanguage.zhHant: '請開啟相册存取權限',
    AppLanguage.en: 'Please grant photo library access',
    AppLanguage.ms: 'Sila benarkan akses galeri',
    AppLanguage.ja: 'フォトライブラリのアクセスを許可してください',
    AppLanguage.ko: '사진 라이브러리 접근을 허용해주세요',
  },
  'noPhotosHint': {
    AppLanguage.zhHans: '还没有用 DAZZ 拍的照片',
    AppLanguage.zhHant: '還沒有用 DAZZ 拍的照片',
    AppLanguage.en: 'No photos taken with DAZZ yet',
    AppLanguage.ms: 'Tiada foto diambil dengan DAZZ lagi',
    AppLanguage.ja: 'DAZZで撮影した写真はまだありません',
    AppLanguage.ko: 'DAZZ로 찍은 사진이 없습니다',
  },
  'deletePhotoConfirm': {
    AppLanguage.zhHans: '确定删除这张照片？',
    AppLanguage.zhHant: '確定刪除這張照片？',
    AppLanguage.en: 'Delete this photo?',
    AppLanguage.ms: 'Padam foto ini?',
    AppLanguage.ja: 'この写真を削除しますか？',
    AppLanguage.ko: '이 사진을 삭제하시겠습니까?',
  },
  // ── 图片编辑 ──
  'imageProcessFailed': {
    AppLanguage.zhHans: '图片处理失败',
    AppLanguage.zhHant: '圖片處理失敗',
    AppLanguage.en: 'Image processing failed',
    AppLanguage.ms: 'Pemprosesan imej gagal',
    AppLanguage.ja: '画像処理に失敗しました',
    AppLanguage.ko: '이미지 처리 실패',
  },
  'needGalleryPermission': {
    AppLanguage.zhHans: '需要相册权限才能保存',
    AppLanguage.zhHant: '需要相册權限才能儲存',
    AppLanguage.en: 'Gallery permission required to save',
    AppLanguage.ms: 'Kebenaran galeri diperlukan untuk simpan',
    AppLanguage.ja: '保存にはフォトライブラリの権限が必要です',
    AppLanguage.ko: '저장하려면 갤러리 권한이 필요합니다',
  },
  'saveError': {
    AppLanguage.zhHans: '保存失败，请重试',
    AppLanguage.zhHant: '儲存失敗，請重試',
    AppLanguage.en: 'Save failed, please try again',
    AppLanguage.ms: 'Simpan gagal, cuba lagi',
    AppLanguage.ja: '保存に失敗しました。再試してください',
    AppLanguage.ko: '저장 실패, 다시 시도해주세요',
  },
  'flip': {
    AppLanguage.zhHans: '翻转',
    AppLanguage.zhHant: '翻轉',
    AppLanguage.en: 'Flip',
    AppLanguage.ms: 'Balik',
    AppLanguage.ja: '反転',
    AppLanguage.ko: '플립',
  },
  'crop': {
    AppLanguage.zhHans: '裁剪',
    AppLanguage.zhHant: '裁剪',
    AppLanguage.en: 'Crop',
    AppLanguage.ms: 'Potong',
    AppLanguage.ja: 'トリミング',
    AppLanguage.ko: '자르기',
  },
  // 相机管理重置
  'reset': {
    AppLanguage.zhHans: '重置',
    AppLanguage.zhHant: '重置',
    AppLanguage.en: 'Reset',
    AppLanguage.ms: 'Set Semula',
    AppLanguage.ja: 'リセット',
    AppLanguage.ko: '재설정',
  },
  'resetTitle': {
    AppLanguage.zhHans: '重置相机排序',
    AppLanguage.zhHant: '重置相機排序',
    AppLanguage.en: 'Reset Camera Order',
    AppLanguage.ms: 'Set Semula Susunan Kamera',
    AppLanguage.ja: 'カメラ順序をリセット',
    AppLanguage.ko: '카메라 순서 재설정',
  },
  'resetConfirm': {
    AppLanguage.zhHans: '将恢复初始排序，收藏和自定义顺序将被清除。确定重置？',
    AppLanguage.zhHant: '將恢復初始排序，收藏和自定義順序將被清除。確定重置？',
    AppLanguage.en:
        'This will restore the default order and clear favorites. Confirm reset?',
    AppLanguage.ms:
        'Ini akan memulihkan susunan lalai dan mengosongkan kegemaran. Sahkan set semula?',
    AppLanguage.ja: '初期順序に戻し、お気に入りとカスタム順序がリセットされます。確認しますか？',
    AppLanguage.ko: '기본 순서로 복원되며 즐겨찾기와 사용자 지정 순서가 삭제됩니다. 재설정하시겠습니까?',
  },
};

// 全局便捷方法
S sOf(AppLanguage lang) => S(lang);
