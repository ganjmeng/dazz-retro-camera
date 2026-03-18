import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../features/camera/camera_screen.dart';
import '../features/gallery/gallery_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/subscription/subscription_screen.dart';
import '../services/app_prefs_service.dart';

// 路由路径常量
abstract class AppRoutes {
  static const onboarding  = '/onboarding';
  static const camera      = '/';
  static const gallery     = '/gallery';
  static const settings    = '/settings';
  static const subscription = '/subscription';
}

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: AppRoutes.camera,
    redirect: (context, state) async {
      // 首次启动访问根路径时，如果 onboarding 未完成则跳转引导页
      if (state.matchedLocation == AppRoutes.camera) {
        final done = await AppPrefsService.instance.isOnboardingDone();
        if (!done) return AppRoutes.onboarding;
      }
      return null;
    },
    routes: [
      GoRoute(
        path: AppRoutes.onboarding,
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        path: AppRoutes.camera,
        builder: (context, state) => const CameraScreen(),
      ),
      GoRoute(
        path: AppRoutes.gallery,
        builder: (context, state) => const GalleryScreen(),
      ),
      GoRoute(
        path: AppRoutes.settings,
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: AppRoutes.subscription,
        builder: (context, state) => const SubscriptionScreen(),
      ),
    ],
  );
});
