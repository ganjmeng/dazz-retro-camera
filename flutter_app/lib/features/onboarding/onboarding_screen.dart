import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/l10n.dart';
import '../../router/app_router.dart';
import '../../services/app_prefs_service.dart';

class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lang = ref.watch(languageProvider);
    final s = sOf(lang);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 36),
          child: Column(
            children: [
              const Spacer(flex: 3),
              // ── Logo ──────────────────────────────────────────────────────
              const Text(
                'DAZZ',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 52,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 6,
                ),
              ),
              const SizedBox(height: 16),
              // ── 副标题 ────────────────────────────────────────────────────
              Text(
                s.onboardingTitle,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 18,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0.5,
                ),
              ),
              const Spacer(flex: 2),
              // ── 说明文案 ──────────────────────────────────────────────────
              Text(
                s.onboardingDesc,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 14,
                  height: 1.7,
                ),
              ),
              const SizedBox(height: 40),
              // ── 授权按钮 ──────────────────────────────────────────────────
              SizedBox(
                width: double.infinity,
                child: GestureDetector(
                  onTap: () => _requestPermissionAndProceed(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF9500),
                      borderRadius: BorderRadius.circular(32),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      s.onboardingBtn,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
              ),
              const Spacer(flex: 1),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _requestPermissionAndProceed(BuildContext context) async {
    final status = await Permission.camera.request();
    if (!context.mounted) return;

    // 无论授权结果如何，标记 onboarding 已完成，进入相机页
    // （相机页会根据权限状态决定是否显示引导 UI）
    await AppPrefsService.instance.setOnboardingDone();

    if (context.mounted) {
      context.go(AppRoutes.camera);
    }
  }
}
