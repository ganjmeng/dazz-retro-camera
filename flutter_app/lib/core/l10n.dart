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
  en,     // English
  ms,     // Bahasa Melayu
  ja,     // 日本語
  ko,     // 한국어
}

extension AppLanguageExt on AppLanguage {
  String get displayName {
    switch (this) {
      case AppLanguage.zhHans: return '简体中文';
      case AppLanguage.zhHant: return '繁體中文';
      case AppLanguage.en:     return 'English';
      case AppLanguage.ms:     return 'Bahasa Melayu';
      case AppLanguage.ja:     return '日本語';
      case AppLanguage.ko:     return '한국어';
    }
  }

  String get code {
    switch (this) {
      case AppLanguage.zhHans: return 'zh_Hans';
      case AppLanguage.zhHant: return 'zh_Hant';
      case AppLanguage.en:     return 'en';
      case AppLanguage.ms:     return 'ms';
      case AppLanguage.ja:     return 'ja';
      case AppLanguage.ko:     return 'ko';
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
    if (script == 'hant' || country == 'tw' || country == 'hk' || country == 'mo') {
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
  String get settings        => get('settings');
  String get language        => get('language');
  String get dazzPro         => get('dazzPro');
  String get restorePurchase => get('restorePurchase');
  String get mirrorFront     => get('mirrorFront');
  String get saveLocation    => get('saveLocation');
  String get silentCapture   => get('silentCapture');
  String get shutterVibration=> get('shutterVibration');
  String get shutterSound    => get('shutterSound');
  String get guideLines      => get('guideLines');
  String get shareApp        => get('shareApp');
  String get sendFeedback    => get('sendFeedback');
  String get recommendApp    => get('recommendApp');
  String get writeReview     => get('writeReview');
  String get followInstagram => get('followInstagram');
  String get privacyPolicy   => get('privacyPolicy');
  String get termsOfUse      => get('termsOfUse');
  String get storageHint     => get('storageHint');
  String get hashtagHint     => get('hashtagHint');
  String get selectLanguage  => get('selectLanguage');
  String get cancel          => get('cancel');
}

// 全局翻译表
const Map<String, Map<AppLanguage, String>> _t = {
  'settings': {
    AppLanguage.zhHans: '设定',
    AppLanguage.zhHant: '設定',
    AppLanguage.en:     'Settings',
    AppLanguage.ms:     'Tetapan',
    AppLanguage.ja:     '設定',
    AppLanguage.ko:     '설정',
  },
  'language': {
    AppLanguage.zhHans: '语言',
    AppLanguage.zhHant: '語言',
    AppLanguage.en:     'Language',
    AppLanguage.ms:     'Bahasa',
    AppLanguage.ja:     '言語',
    AppLanguage.ko:     '언어',
  },
  'dazzPro': {
    AppLanguage.zhHans: 'Dazz Pro',
    AppLanguage.zhHant: 'Dazz Pro',
    AppLanguage.en:     'Dazz Pro',
    AppLanguage.ms:     'Dazz Pro',
    AppLanguage.ja:     'Dazz Pro',
    AppLanguage.ko:     'Dazz Pro',
  },
  'restorePurchase': {
    AppLanguage.zhHans: '恢复购买',
    AppLanguage.zhHant: '恢復購買',
    AppLanguage.en:     'Restore Purchase',
    AppLanguage.ms:     'Pulihkan Pembelian',
    AppLanguage.ja:     '購入を復元',
    AppLanguage.ko:     '구매 복원',
  },
  'mirrorFront': {
    AppLanguage.zhHans: '镜像前置摄像头',
    AppLanguage.zhHant: '鏡像前置鏡頭',
    AppLanguage.en:     'Mirror Front Camera',
    AppLanguage.ms:     'Cermin Kamera Depan',
    AppLanguage.ja:     'フロントカメラ反転',
    AppLanguage.ko:     '전면 카메라 미러',
  },
  'saveLocation': {
    AppLanguage.zhHans: '保存地理位置',
    AppLanguage.zhHant: '儲存地理位置',
    AppLanguage.en:     'Save Location',
    AppLanguage.ms:     'Simpan Lokasi',
    AppLanguage.ja:     '位置情報を保存',
    AppLanguage.ko:     '위치 저장',
  },
  'silentCapture': {
    AppLanguage.zhHans: '静音拍摄',
    AppLanguage.zhHant: '靜音拍攝',
    AppLanguage.en:     'Silent Capture',
    AppLanguage.ms:     'Tangkap Senyap',
    AppLanguage.ja:     'サイレント撮影',
    AppLanguage.ko:     '무음 촬영',
  },
  'shutterVibration': {
    AppLanguage.zhHans: '快门震动',
    AppLanguage.zhHant: '快門震動',
    AppLanguage.en:     'Shutter Vibration',
    AppLanguage.ms:     'Getaran Pengatup',
    AppLanguage.ja:     'シャッター振動',
    AppLanguage.ko:     '셔터 진동',
  },
  'shutterSound': {
    AppLanguage.zhHans: '快门声音',
    AppLanguage.zhHant: '快門聲音',
    AppLanguage.en:     'Shutter Sound',
    AppLanguage.ms:     'Bunyi Pengatup',
    AppLanguage.ja:     'シャッター音',
    AppLanguage.ko:     '셔터 소리',
  },
  'guideLines': {
    AppLanguage.zhHans: '辅助线',
    AppLanguage.zhHant: '輔助線',
    AppLanguage.en:     'Guide Lines',
    AppLanguage.ms:     'Garis Panduan',
    AppLanguage.ja:     'ガイドライン',
    AppLanguage.ko:     '가이드라인',
  },
  'shareApp': {
    AppLanguage.zhHans: '分享应用给朋友',
    AppLanguage.zhHant: '分享應用給朋友',
    AppLanguage.en:     'Share with Friends',
    AppLanguage.ms:     'Kongsi dengan Rakan',
    AppLanguage.ja:     '友達にシェア',
    AppLanguage.ko:     '친구에게 공유',
  },
  'sendFeedback': {
    AppLanguage.zhHans: '发送反馈',
    AppLanguage.zhHant: '傳送意見',
    AppLanguage.en:     'Send Feedback',
    AppLanguage.ms:     'Hantar Maklum Balas',
    AppLanguage.ja:     'フィードバック送信',
    AppLanguage.ko:     '피드백 보내기',
  },
  'recommendApp': {
    AppLanguage.zhHans: '推荐应用',
    AppLanguage.zhHant: '推薦應用',
    AppLanguage.en:     'Recommend App',
    AppLanguage.ms:     'Cadangkan Apl',
    AppLanguage.ja:     'アプリを推薦',
    AppLanguage.ko:     '앱 추천',
  },
  'writeReview': {
    AppLanguage.zhHans: '撰写评论',
    AppLanguage.zhHant: '撰寫評論',
    AppLanguage.en:     'Write a Review',
    AppLanguage.ms:     'Tulis Ulasan',
    AppLanguage.ja:     'レビューを書く',
    AppLanguage.ko:     '리뷰 작성',
  },
  'followInstagram': {
    AppLanguage.zhHans: '在 Instagram 上关注我们',
    AppLanguage.zhHant: '在 Instagram 上關注我們',
    AppLanguage.en:     'Follow Us on Instagram',
    AppLanguage.ms:     'Ikuti Kami di Instagram',
    AppLanguage.ja:     'Instagramでフォロー',
    AppLanguage.ko:     'Instagram 팔로우',
  },
  'privacyPolicy': {
    AppLanguage.zhHans: '隐私政策',
    AppLanguage.zhHant: '隱私政策',
    AppLanguage.en:     'Privacy Policy',
    AppLanguage.ms:     'Dasar Privasi',
    AppLanguage.ja:     'プライバシーポリシー',
    AppLanguage.ko:     '개인정보 처리방침',
  },
  'termsOfUse': {
    AppLanguage.zhHans: '使用条款',
    AppLanguage.zhHant: '使用條款',
    AppLanguage.en:     'Terms of Use',
    AppLanguage.ms:     'Syarat Penggunaan',
    AppLanguage.ja:     '利用規約',
    AppLanguage.ko:     '이용약관',
  },
  'storageHint': {
    AppLanguage.zhHans: '照片和影片储存在本地，请在必要时进行备份。',
    AppLanguage.zhHant: '照片和影片儲存在本地，請在必要時進行備份。',
    AppLanguage.en:     'Photos and videos are stored locally. Please back them up when needed.',
    AppLanguage.ms:     'Foto dan video disimpan secara tempatan. Sila buat sandaran bila perlu.',
    AppLanguage.ja:     '写真と動画はローカルに保存されます。必要に応じてバックアップしてください。',
    AppLanguage.ko:     '사진과 동영상은 로컬에 저장됩니다. 필요시 백업하세요.',
  },
  'hashtagHint': {
    AppLanguage.zhHans: '在社交媒体发布时，请使用',
    AppLanguage.zhHant: '在社交媒體發布時，請使用',
    AppLanguage.en:     'Use',
    AppLanguage.ms:     'Gunakan',
    AppLanguage.ja:     'SNSに投稿するときは',
    AppLanguage.ko:     'SNS에 게시할 때',
  },
  'selectLanguage': {
    AppLanguage.zhHans: '选择语言',
    AppLanguage.zhHant: '選擇語言',
    AppLanguage.en:     'Select Language',
    AppLanguage.ms:     'Pilih Bahasa',
    AppLanguage.ja:     '言語を選択',
    AppLanguage.ko:     '언어 선택',
  },
  'cancel': {
    AppLanguage.zhHans: '取消',
    AppLanguage.zhHant: '取消',
    AppLanguage.en:     'Cancel',
    AppLanguage.ms:     'Batal',
    AppLanguage.ja:     'キャンセル',
    AppLanguage.ko:     '취소',
  },
};

// 全局便捷方法
S sOf(AppLanguage lang) => S(lang);
