// settings_screen.dart
// 设计规范：黑色背景，深灰色分组卡片(#1C1C1E)，红色开关(#E05A4B)，白色文字，返回按钮圆形深灰
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../router/app_router.dart';
import '../../services/subscription_service.dart';
import '../../core/l10n.dart';
import '../camera/camera_notifier.dart';

// ─── 设置状态 Provider ────────────────────────────────────────────────────────
class _SettingsState {
  final bool saveLocation;
  final bool mirrorFrontCamera;
  final bool guideLines;
  final bool shutterVibration;
  final bool shutterSound;
  final bool recommendApp;

  const _SettingsState({
    this.saveLocation = true,
    this.mirrorFrontCamera = true,
    this.guideLines = true,
    this.shutterVibration = true,
    this.shutterSound = true,
    this.recommendApp = true,
  });

  _SettingsState copyWith({
    bool? saveLocation,
    bool? mirrorFrontCamera,
    bool? guideLines,
    bool? shutterVibration,
    bool? shutterSound,
    bool? recommendApp,
  }) {
    return _SettingsState(
      saveLocation: saveLocation ?? this.saveLocation,
      mirrorFrontCamera: mirrorFrontCamera ?? this.mirrorFrontCamera,
      guideLines: guideLines ?? this.guideLines,
      shutterVibration: shutterVibration ?? this.shutterVibration,
      shutterSound: shutterSound ?? this.shutterSound,
      recommendApp: recommendApp ?? this.recommendApp,
    );
  }
}

class _SettingsNotifier extends StateNotifier<_SettingsState> {
  _SettingsNotifier() : super(const _SettingsState());
  void toggle(String key) {
    switch (key) {
      case 'saveLocation':      state = state.copyWith(saveLocation: !state.saveLocation); break;
      case 'mirrorFrontCamera': state = state.copyWith(mirrorFrontCamera: !state.mirrorFrontCamera); break;
      case 'guideLines':        state = state.copyWith(guideLines: !state.guideLines); break;
      case 'shutterVibration':  state = state.copyWith(shutterVibration: !state.shutterVibration); break;
      case 'shutterSound':      state = state.copyWith(shutterSound: !state.shutterSound); break;
      case 'recommendApp':      state = state.copyWith(recommendApp: !state.recommendApp); break;
    }
  }
}

final _settingsProvider = StateNotifierProvider<_SettingsNotifier, _SettingsState>(
  (ref) => _SettingsNotifier(),
);

// ─── 颜色常量 ─────────────────────────────────────────────────────────────────
const _kBg      = Color(0xFF000000);
const _kCard    = Color(0xFF1C1C1E);
const _kRed     = Color(0xFFE05A4B);
const _kWhite   = Colors.white;
const _kGray    = Color(0xFF8E8E93);
const _kDivider = Color(0xFF3A3A3C);

// ─── 主界面 ───────────────────────────────────────────────────────────────────
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st       = ref.watch(_settingsProvider);
    final notifier = ref.read(_settingsProvider.notifier);
    final camNotifier = ref.read(cameraAppProvider.notifier);
    final lang     = ref.watch(languageProvider);
    final s        = sOf(lang);
    ref.watch(subscriptionServiceProvider);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _kBg,
        body: SafeArea(
          child: Column(
            children: [
              // ── 顶部导航栏（修复返回键重叠：使用 Padding + Row 代替 Stack）──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: SizedBox(
                  height: 44,
                  child: Row(
                    children: [
                      // 返回按钮
                      GestureDetector(
                        onTap: () => context.go(AppRoutes.camera),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: const BoxDecoration(
                            color: _kCard,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.chevron_left,
                            color: _kWhite,
                            size: 24,
                          ),
                        ),
                      ),
                      // 标题居中（Expanded + Center）
                      Expanded(
                        child: Center(
                          child: Text(
                            s.settings,
                            style: const TextStyle(
                              color: _kWhite,
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      // 右侧占位，保持标题视觉居中
                      const SizedBox(width: 36),
                    ],
                  ),
                ),
              ),

              // ── 内容列表 ──
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  children: [
                    // 分组1：Dazz Pro + 恢复购买
                    _SettingsGroup(
                      children: [
                        _SettingsRow(
                          title: s.dazzPro,
                          titleBold: true,
                          trailing: const Icon(Icons.chevron_right, color: _kGray, size: 20),
                          onTap: () {},
                        ),
                        _SettingsDivider(),
                        _SettingsRow(
                          title: s.restorePurchase,
                          onTap: () async {
                            await ref.read(subscriptionServiceProvider.notifier).restorePurchases();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // 分组2：语言（带当前语言名称 + 选择器）
                    _SettingsGroup(
                      children: [
                        _SettingsRow(
                          title: s.language,
                          trailingLabel: lang.displayName,
                          trailing: const Icon(Icons.chevron_right, color: _kGray, size: 20),
                          onTap: () => _showLanguagePicker(context, ref, s),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // 分组3：相机设置（精简后）
                    _SettingsGroup(
                      children: [
                        _SettingsRow(
                          title: s.mirrorFront,
                          trailing: _RedSwitch(
                            value: st.mirrorFrontCamera,
                            onChanged: (_) => notifier.toggle('mirrorFrontCamera'),
                          ),
                        ),
                        _SettingsDivider(),
                        _SettingsRow(
                          title: s.saveLocation,
                          trailing: _RedSwitch(
                            value: st.saveLocation,
                            onChanged: (_) => notifier.toggle('saveLocation'),
                          ),
                        ),
                        _SettingsDivider(),
                        _SettingsRow(
                          title: s.guideLines,
                          trailing: _RedSwitch(
                            value: st.guideLines,
                            onChanged: (_) => notifier.toggle('guideLines'),
                          ),
                        ),
                        _SettingsDivider(),
                        _SettingsRow(
                          title: s.shutterVibration,
                          trailing: _RedSwitch(
                            value: st.shutterVibration,
                            onChanged: (_) => notifier.toggle('shutterVibration'),
                          ),
                        ),
                        _SettingsDivider(),
                        _SettingsRow(
                          title: s.shutterSound,
                          trailing: _RedSwitch(
                            value: st.shutterSound,
                            onChanged: (_) {
                              notifier.toggle('shutterSound');
                              camNotifier.setShutterSoundEnabled(!st.shutterSound);
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // 分组4：分享/反馈/推荐/评论
                    _SettingsGroup(
                      children: [
                        _SettingsRow(
                          title: s.shareApp,
                          onTap: () {},
                        ),
                        _SettingsDivider(),
                        _SettingsRow(
                          title: s.sendFeedback,
                          onTap: () {},
                        ),
                        _SettingsDivider(),
                        _SettingsRow(
                          title: s.recommendApp,
                          trailing: _RedSwitch(
                            value: st.recommendApp,
                            onChanged: (_) => notifier.toggle('recommendApp'),
                          ),
                        ),
                        _SettingsDivider(),
                        _SettingsRow(
                          title: s.writeReview,
                          onTap: () {},
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // 分组5：Instagram
                    _SettingsGroup(
                      children: [
                        _SettingsRow(
                          title: s.followInstagram,
                          onTap: () {},
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // 分组6：隐私政策 + 使用条款
                    _SettingsGroup(
                      children: [
                        _SettingsRow(
                          title: s.privacyPolicy,
                          onTap: () {},
                        ),
                        _SettingsDivider(),
                        _SettingsRow(
                          title: s.termsOfUse,
                          onTap: () {},
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // 底部标签
                    Center(
                      child: RichText(
                        textAlign: TextAlign.center,
                        text: TextSpan(
                          style: const TextStyle(color: _kGray, fontSize: 13),
                          children: [
                            TextSpan(text: s.hashtagHint),
                            TextSpan(text: ' '),
                            const TextSpan(
                              text: '#dazzcam',
                              style: TextStyle(
                                color: _kRed,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (lang == AppLanguage.zhHans || lang == AppLanguage.zhHant)
                              const TextSpan(text: ' 标签。'),
                            if (lang == AppLanguage.en || lang == AppLanguage.ms)
                              const TextSpan(text: ' when posting on social media.'),
                            if (lang == AppLanguage.ja)
                              const TextSpan(text: ' タグを使ってください。'),
                            if (lang == AppLanguage.ko)
                              const TextSpan(text: ' 태그를 사용하세요.'),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 语言选择底部弹窗 ──────────────────────────────────────────────────────────
  void _showLanguagePicker(BuildContext context, WidgetRef ref, S s) {
    final langNotifier = ref.read(languageProvider.notifier);
    final current = ref.read(languageProvider);

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部把手
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: _kDivider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  s.selectLanguage,
                  style: const TextStyle(
                    color: _kWhite,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Divider(height: 1, thickness: 0.5, color: _kDivider),
              ...AppLanguage.values.map((lang) {
                final isSelected = lang == current;
                return InkWell(
                  onTap: () {
                    langNotifier.setLanguage(lang);
                    Navigator.of(ctx).pop();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            lang.displayName,
                            style: TextStyle(
                              color: isSelected ? _kRed : _kWhite,
                              fontSize: 16,
                              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                        ),
                        if (isSelected)
                          const Icon(Icons.check, color: _kRed, size: 20),
                      ],
                    ),
                  ),
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

// ─── 分组卡片容器 ─────────────────────────────────────────────────────────────
class _SettingsGroup extends StatelessWidget {
  final List<Widget> children;
  const _SettingsGroup({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

// ─── 分割线 ───────────────────────────────────────────────────────────────────
class _SettingsDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(left: 16),
      child: Divider(height: 1, thickness: 0.5, color: _kDivider),
    );
  }
}

// ─── 单行设置项 ───────────────────────────────────────────────────────────────
class _SettingsRow extends StatelessWidget {
  final String title;
  final bool titleBold;
  final Widget? trailing;
  final String? trailingLabel;
  final VoidCallback? onTap;

  const _SettingsRow({
    required this.title,
    this.titleBold = false,
    this.trailing,
    this.trailingLabel,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: _kWhite,
                  fontSize: 16,
                  fontWeight: titleBold ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
            if (trailingLabel != null) ...[
              Text(
                trailingLabel!,
                style: const TextStyle(color: _kGray, fontSize: 15),
              ),
              const SizedBox(width: 4),
            ],
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

// ─── 红色开关 ─────────────────────────────────────────────────────────────────
class _RedSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _RedSwitch({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return CupertinoSwitch(
      value: value,
      onChanged: onChanged,
      activeTrackColor: _kRed,
      inactiveTrackColor: const Color(0xFF3A3A3C),
    );
  }
}
