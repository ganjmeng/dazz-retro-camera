import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'router/app_router.dart';
import 'core/theme.dart';

class RetroCamApp extends ConsumerWidget {
  const RetroCamApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'Retro Cam',
      theme: AppTheme.darkTheme, // 默认暗色主题，符合相机应用调性
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
