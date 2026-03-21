import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/debug_crash_overlay.dart';
import 'router/app_router.dart';
import 'core/theme.dart';
import 'services/camera_service.dart';

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
    final nativeCameraError =
        ref.watch(cameraServiceProvider.select((state) => state.error));
    return MaterialApp.router(
      title: 'DAZZ',
      theme: AppTheme.darkTheme,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        if (kEnableAndroidDebugCrashOverlay &&
            nativeCameraError != null &&
            nativeCameraError.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            DebugCrashOverlayController.instance.reportMessage(
              title: 'Native 相机错误',
              message: nativeCameraError,
            );
          });
        }
        if (!kEnableAndroidDebugCrashOverlay) {
          return child ?? const SizedBox.shrink();
        }
        return ValueListenableBuilder<DebugCrashInfo?>(
          valueListenable: DebugCrashOverlayController.instance.current,
          builder: (context, info, _) {
            return Stack(
              children: [
                child ?? const SizedBox.shrink(),
                if (info != null)
                  Positioned.fill(
                    child: DebugCrashOverlay(
                      info: info,
                      onDismiss: DebugCrashOverlayController.instance.clear,
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}
