import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'router/app_router.dart';
import 'core/theme.dart';
import 'core/l10n.dart';

class RetroCamApp extends ConsumerWidget {
  const RetroCamApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router   = ref.watch(appRouterProvider);
    final language = ref.watch(languageProvider);

    // 将 AppLanguage 枚举映射为 Flutter Locale
    final locale = _toLocale(language);

    return MaterialApp.router(
      title: 'DAZZ',
      theme: AppTheme.darkTheme,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      // 绑定语言 Provider，切换语言时整个 Widget 树重建
      locale: locale,
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        Locale('en'),
        Locale('ms'),
        Locale('ja'),
        Locale('ko'),
      ],
    );
  }

  Locale _toLocale(AppLanguage lang) {
    switch (lang) {
      case AppLanguage.zhHans: return const Locale('zh', 'CN');
      case AppLanguage.zhHant: return const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
      case AppLanguage.en:     return const Locale('en');
      case AppLanguage.ms:     return const Locale('ms');
      case AppLanguage.ja:     return const Locale('ja');
      case AppLanguage.ko:     return const Locale('ko');
    }
  }
}
