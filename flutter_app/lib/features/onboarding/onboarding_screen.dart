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
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── 全屏背景图 ──────────────────────────────────────────────────────
          Image.asset(
            'assets/images/onboarding_bg.jpg',
            fit: BoxFit.cover,
            alignment: Alignment.center,
          ),
          // ── 顶部渐变遮罩（让 Logo 文字清晰可读）────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: MediaQuery.of(context).size.height * 0.55,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withAlpha(220),
                    Colors.black.withAlpha(160),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
            ),
          ),
          // ── 底部渐变遮罩（让按钮区域清晰可读）─────────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: MediaQuery.of(context).size.height * 0.45,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withAlpha(230),
                    Colors.black.withAlpha(160),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.5, 1.0],
                ),
              ),
            ),
          ),
          // ── 内容层 ──────────────────────────────────────────────────────────
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 36),
              child: Column(
                children: [
                  const Spacer(flex: 3),
                  // ── Logo ───────────────────────────────────────────────────
                  const Text(
                    'DAZZ',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 56,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 8,
                      shadows: [
                        Shadow(
                          color: Colors.black54,
                          blurRadius: 16,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  // ── 副标题 ─────────────────────────────────────────────────
                  Text(
                    s.onboardingTitle,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 17,
                      fontWeight: FontWeight.w400,
                      letterSpacing: 0.8,
                      shadows: [
                        Shadow(
                          color: Colors.black45,
                          blurRadius: 8,
                        ),
                      ],
                    ),
                  ),
                  const Spacer(flex: 4),
                  // ── 说明文案 ───────────────────────────────────────────────
                  Text(
                    s.onboardingDesc,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 14,
                      height: 1.75,
                      shadows: [
                        Shadow(
                          color: Colors.black87,
                          blurRadius: 12,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 36),
                  // ── 授权按钮 ───────────────────────────────────────────────
                  SizedBox(
                    width: double.infinity,
                    child: GestureDetector(
                      onTap: () => _requestPermissionAndProceed(context),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 17),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF9500),
                          borderRadius: BorderRadius.circular(32),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFFFF9500).withAlpha(100),
                              blurRadius: 20,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          s.onboardingBtn,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
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
        ],
      ),
    );
  }

  Future<void> _requestPermissionAndProceed(BuildContext context) async {
    // 最佳实践：相机 + 相册权限同时请求，减少用户等待次数
    await [
      Permission.camera,
      Permission.photos,   // Android 13+ / iOS
      Permission.storage,  // Android 12 及以下
    ].request();
    if (!context.mounted) return;

    // 无论授权结果如何，标记 onboarding 已完成，进入相机页
    // （相机页会根据权限状态决定是否显示引导 UI）
    await AppPrefsService.instance.setOnboardingDone();

    if (context.mounted) {
      context.go(AppRoutes.camera);
    }
  }
}
