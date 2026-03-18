import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'router/app_router.dart';
import 'core/theme.dart';
import 'core/app_logger.dart';

// NOTE: languageProvider is intentionally NOT watched here.
// Watching it at the MaterialApp level would rebuild the entire router/widget
// tree on every language switch, invalidating all BuildContexts in the stack
// and breaking showModalBottomSheet / Navigator calls in child pages.
// Each page watches languageProvider locally so only that page rebuilds.
class RetroCamApp extends ConsumerWidget {
  const RetroCamApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: 'DAZZ',
      theme: AppTheme.darkTheme,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      // AppLogOverlay：
      // - debug 模式下右下角悬浮日志按钮（有 error 时变红色显示数量）
      // - 监听 AppLogger.pendingError，崩溃时直接在 Stack 最高层弹出弹框
      // - 完全不依赖 Navigator/GoRouter，即使路由层崩溃也能显示
      builder: (context, child) => AppLogOverlay(child: child ?? const SizedBox()),
    );
  }
}
