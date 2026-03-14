// settings_screen.dart
// 一比一复刻 Dazz 设置界面
// 设计规范：黑色背景，深灰色分组卡片(#1C1C1E)，红色开关(#E05A4B)，白色文字，返回按钮圆形深灰
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../services/subscription_service.dart';

// ─── 设置状态 Provider ────────────────────────────────────────────────────────
class _SettingsState {
  final bool exportToAlbum;
  final bool keepOriginal;
  final bool saveLocation;
  final bool mirrorFrontCamera;
  final bool guideLines;
  final bool levelIndicator;
  final bool shutterVibration;
  final bool recommendApp;

  const _SettingsState({
    this.exportToAlbum = true,
    this.keepOriginal = false,
    this.saveLocation = true,
    this.mirrorFrontCamera = true,
    this.guideLines = true,
    this.levelIndicator = true,
    this.shutterVibration = true,
    this.recommendApp = true,
  });

  _SettingsState copyWith({
    bool? exportToAlbum,
    bool? keepOriginal,
    bool? saveLocation,
    bool? mirrorFrontCamera,
    bool? guideLines,
    bool? levelIndicator,
    bool? shutterVibration,
    bool? recommendApp,
  }) {
    return _SettingsState(
      exportToAlbum: exportToAlbum ?? this.exportToAlbum,
      keepOriginal: keepOriginal ?? this.keepOriginal,
      saveLocation: saveLocation ?? this.saveLocation,
      mirrorFrontCamera: mirrorFrontCamera ?? this.mirrorFrontCamera,
      guideLines: guideLines ?? this.guideLines,
      levelIndicator: levelIndicator ?? this.levelIndicator,
      shutterVibration: shutterVibration ?? this.shutterVibration,
      recommendApp: recommendApp ?? this.recommendApp,
    );
  }
}

class _SettingsNotifier extends StateNotifier<_SettingsState> {
  _SettingsNotifier() : super(const _SettingsState());
  void toggle(String key) {
    switch (key) {
      case 'exportToAlbum': state = state.copyWith(exportToAlbum: !state.exportToAlbum); break;
      case 'keepOriginal': state = state.copyWith(keepOriginal: !state.keepOriginal); break;
      case 'saveLocation': state = state.copyWith(saveLocation: !state.saveLocation); break;
      case 'mirrorFrontCamera': state = state.copyWith(mirrorFrontCamera: !state.mirrorFrontCamera); break;
      case 'guideLines': state = state.copyWith(guideLines: !state.guideLines); break;
      case 'levelIndicator': state = state.copyWith(levelIndicator: !state.levelIndicator); break;
      case 'shutterVibration': state = state.copyWith(shutterVibration: !state.shutterVibration); break;
      case 'recommendApp': state = state.copyWith(recommendApp: !state.recommendApp); break;
    }
  }
}

final _settingsProvider = StateNotifierProvider<_SettingsNotifier, _SettingsState>(
  (ref) => _SettingsNotifier(),
);

// ─── 颜色常量 ─────────────────────────────────────────────────────────────────
const _kBg = Color(0xFF000000);
const _kCard = Color(0xFF1C1C1E);
const _kRed = Color(0xFFE05A4B);
const _kWhite = Colors.white;
const _kGray = Color(0xFF8E8E93);
const _kDivider = Color(0xFF3A3A3C);

// ─── 主界面 ───────────────────────────────────────────────────────────────────
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(_settingsProvider);
    final notifier = ref.read(_settingsProvider.notifier);
    final isPro = ref.watch(subscriptionServiceProvider);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light, // 白色状态栏图标（黑色背景）
      child: Scaffold(
      backgroundColor: _kBg,
      body: SafeArea(
        child: Column(
          children: [
            // ── 顶部导航栏 ──
            SizedBox(
              height: 44,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 返回按钮（左侧圆形深灰）
                  Positioned(
                    left: 16,
                    child: GestureDetector(
                      onTap: () => context.pop(),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
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
                  ),
                  // 标题居中
                  const Text(
                    '设定',
                    style: TextStyle(
                      color: _kWhite,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),

            // ── 内容列表 ──
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 16,
                  bottom: 16,
                ),
                children: [
                  // 分组1：Dazz Pro + 恢复购买
                  _SettingsGroup(
                    children: [
                      _SettingsRow(
                        title: 'Dazz Pro',
                        titleBold: true,
                        trailing: const Icon(Icons.chevron_right, color: _kGray, size: 20),
                        onTap: () {},
                      ),
                      _SettingsDivider(),
                      _SettingsRow(
                        title: '恢复购买',
                        onTap: () async {
                          await ref.read(subscriptionServiceProvider.notifier).restorePurchases();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // 分组2：语言
                  _SettingsGroup(
                    children: [
                      _SettingsRow(
                        title: '语言',
                        trailing: const Icon(Icons.chevron_right, color: _kGray, size: 20),
                        onTap: () {},
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // 分组3：相机设置（开关列表）
                  _SettingsGroup(
                    children: [
                      _SettingsRow(
                        title: '导出到相册',
                        trailing: _RedSwitch(
                          value: st.exportToAlbum,
                          onChanged: (_) => notifier.toggle('exportToAlbum'),
                        ),
                      ),
                      _SettingsDivider(),
                      _SettingsRow(
                        title: '保留原始照片',
                        trailing: _RedSwitch(
                          value: st.keepOriginal,
                          onChanged: (_) => notifier.toggle('keepOriginal'),
                        ),
                      ),
                      _SettingsDivider(),
                      _SettingsRow(
                        title: '保存地理位置',
                        trailing: _RedSwitch(
                          value: st.saveLocation,
                          onChanged: (_) => notifier.toggle('saveLocation'),
                        ),
                      ),
                      _SettingsDivider(),
                      _SettingsRow(
                        title: '镜像前置摄像头',
                        trailing: _RedSwitch(
                          value: st.mirrorFrontCamera,
                          onChanged: (_) => notifier.toggle('mirrorFrontCamera'),
                        ),
                      ),
                      _SettingsDivider(),
                      _SettingsRow(
                        title: '实况照片封面',
                        trailing: const Icon(Icons.chevron_right, color: _kGray, size: 20),
                        onTap: () {},
                      ),
                      _SettingsDivider(),
                      _SettingsRow(
                        title: 'ISO 与快门滑杆',
                        trailingLabel: '分段式',
                        trailing: const Icon(Icons.chevron_right, color: _kGray, size: 20),
                        onTap: () {},
                      ),
                      _SettingsDivider(),
                      _SettingsRow(
                        title: '辅助线',
                        trailing: _RedSwitch(
                          value: st.guideLines,
                          onChanged: (_) => notifier.toggle('guideLines'),
                        ),
                      ),
                      _SettingsDivider(),
                      _SettingsRow(
                        title: '水平仪',
                        trailing: _RedSwitch(
                          value: st.levelIndicator,
                          onChanged: (_) => notifier.toggle('levelIndicator'),
                        ),
                      ),
                      _SettingsDivider(),
                      _SettingsRow(
                        title: '快门震动',
                        trailing: _RedSwitch(
                          value: st.shutterVibration,
                          onChanged: (_) => notifier.toggle('shutterVibration'),
                        ),
                      ),
                      _SettingsDivider(),
                      _SettingsRow(
                        title: '时间水印格式',
                        trailing: const Icon(Icons.chevron_right, color: _kGray, size: 20),
                        onTap: () {},
                      ),
                      _SettingsDivider(),
                      _SettingsRow(
                        title: '保留设定',
                        trailing: const Icon(Icons.chevron_right, color: _kGray, size: 20),
                        onTap: () {},
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // 分组4：储存空间
                  _SettingsGroup(
                    children: [
                      _SettingsRow(
                        title: '储存空间',
                        trailing: const Icon(Icons.chevron_right, color: _kGray, size: 20),
                        onTap: () {},
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // 提示横幅（深红色背景）
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF4A1A14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('👉', style: TextStyle(fontSize: 20)),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            '照片和影片在 Dazz 应用中储存在本地，请在必要时进行备份。',
                            style: TextStyle(
                              color: _kWhite,
                              fontSize: 14,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // 分组5：分享/反馈/推荐/评论
                  _SettingsGroup(
                    children: [
                      _SettingsRow(
                        title: '分享应用给朋友',
                        onTap: () {},
                      ),
                      _SettingsDivider(),
                      _SettingsRow(
                        title: '发送反馈',
                        onTap: () {},
                      ),
                      _SettingsDivider(),
                      _SettingsRow(
                        title: '推荐应用',
                        trailing: _RedSwitch(
                          value: st.recommendApp,
                          onChanged: (_) => notifier.toggle('recommendApp'),
                        ),
                      ),
                      _SettingsDivider(),
                      _SettingsRow(
                        title: '撰写评论',
                        onTap: () {},
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // 分组6：Instagram
                  _SettingsGroup(
                    children: [
                      _SettingsRow(
                        title: '在 Instagram 上关注我们',
                        onTap: () {},
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // 分组7：隐私政策 + 使用条款
                  _SettingsGroup(
                    children: [
                      _SettingsRow(
                        title: '隐私政策',
                        onTap: () {},
                      ),
                      _SettingsDivider(),
                      _SettingsRow(
                        title: '使用条款',
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
                        style: TextStyle(color: _kGray, fontSize: 13),
                        children: [
                          TextSpan(text: '在社交媒体上发布内容时，请使用'),
                          TextSpan(
                            text: '#dazzcam',
                            style: TextStyle(
                              color: _kRed,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          TextSpan(text: ' 标签。'),
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
    ),  // Scaffold
    );  // AnnotatedRegion
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

// ─── 红色开关（复刻截图样式）─────────────────────────────────────────────────
class _RedSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _RedSwitch({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return CupertinoSwitch(
      value: value,
      onChanged: onChanged,
      activeColor: _kRed,
      trackColor: const Color(0xFF3A3A3C),
    );
  }
}
