// settings_screen.dart
// 设计规范：黑色背景，深灰色分组卡片(#1C1C1E)，红色开关(#E05A4B)，白色文字，返回按钮圆形深灰
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/subscription_service.dart';
import '../../core/l10n.dart';
import '../camera/camera_notifier.dart';
import '../../services/camera_service.dart';
import '../../services/location_service.dart';
import '../camera/render_style_mode.dart';
import '../camera/preview_performance_mode.dart';
import '../../services/retain_settings_service.dart';

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
      case 'saveLocation':
        state = state.copyWith(saveLocation: !state.saveLocation);
        break;
      case 'mirrorFrontCamera':
        state = state.copyWith(mirrorFrontCamera: !state.mirrorFrontCamera);
        break;
      case 'guideLines':
        state = state.copyWith(guideLines: !state.guideLines);
        break;
      case 'shutterVibration':
        state = state.copyWith(shutterVibration: !state.shutterVibration);
        break;
      case 'shutterSound':
        state = state.copyWith(shutterSound: !state.shutterSound);
        break;
      case 'recommendApp':
        state = state.copyWith(recommendApp: !state.recommendApp);
        break;
    }
  }
}

final _settingsProvider =
    StateNotifierProvider<_SettingsNotifier, _SettingsState>(
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

  Future<void> _toggleLocationPermission(
    BuildContext context,
    WidgetRef ref,
    S s,
  ) async {
    final result = await ref.read(cameraAppProvider.notifier).toggleLocation();
    if (!context.mounted) return;

    switch (result) {
      case LocationToggleResult.enabled:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.locationEnabled)),
        );
        break;
      case LocationToggleResult.disabled:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.locationDisabled)),
        );
        break;
      case LocationToggleResult.permissionDenied:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.locationDenied)),
        );
        break;
      case LocationToggleResult.permissionDeniedForever:
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1C1C1E),
            title: Text(
              s.locationPermTitle,
              style: const TextStyle(color: Colors.white),
            ),
            content: Text(
              s.locationPermDesc,
              style: const TextStyle(color: Colors.grey),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  s.cancel,
                  style: const TextStyle(color: Colors.grey),
                ),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  LocationService.instance.openSettings();
                },
                child: Text(
                  s.goToSettings,
                  style: const TextStyle(color: Color(0xFFFF9500)),
                ),
              ),
            ],
          ),
        );
        break;
    }
  }

  Future<void> _copyCalibrationInfo(
    BuildContext context,
    WidgetRef ref,
    S s,
  ) async {
    final camState = ref.read(cameraAppProvider);
    final debugInfo = ref.read(cameraServiceProvider).activeCameraDebugInfo;
    final runtimeCameraId = (camState.runtimeCameraId.isNotEmpty
            ? camState.runtimeCameraId
            : debugInfo['cameraId']?.toString() ?? '')
        .trim();
    final brand = (camState.runtimeDeviceBrand.isNotEmpty
            ? camState.runtimeDeviceBrand
            : debugInfo['brand']?.toString() ?? '')
        .trim();
    final model = (camState.runtimeDeviceModel.isNotEmpty
            ? camState.runtimeDeviceModel
            : debugInfo['model']?.toString() ?? '')
        .trim();
    final sensorMp = debugInfo['sensorMp']?.toString() ??
        camState.runtimeSensorMp.toString();

    if (brand.isEmpty && model.isEmpty && runtimeCameraId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.copyCalibrationInfoEmpty)),
      );
      return;
    }

    final payload = <String, String>{
      'presetCameraId': camState.activeCameraId,
      'runtimeCameraId': runtimeCameraId,
      'brand': brand,
      'model': model,
      'sensorMp': sensorMp,
      if (debugInfo['facing'] != null) 'facing': debugInfo['facing'].toString(),
      if (debugInfo['focalLengths'] != null)
        'focalLengths': debugInfo['focalLengths'].toString(),
      if (debugInfo['sensorSize'] != null)
        'sensorSize': debugInfo['sensorSize'].toString(),
      if (debugInfo['manufacturer'] != null)
        'manufacturer': debugInfo['manufacturer'].toString(),
      if (debugInfo['device'] != null) 'device': debugInfo['device'].toString(),
    };
    final text = payload.entries.map((e) => '${e.key}: ${e.value}').join('\n');

    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(s.copyCalibrationInfoDone)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(_settingsProvider);
    final notifier = ref.read(_settingsProvider.notifier);
    final camState = ref.watch(cameraAppProvider);
    final camNotifier = ref.read(cameraAppProvider.notifier);
    final lang = ref.watch(languageProvider);
    final s = sOf(lang);
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
                        onTap: () => Navigator.of(context).pop(),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  children: [
                    // 分组1：Dazz Pro + 恢复购买
                    _SettingsGroup(
                      children: [
                        _SettingsRow(
                          title: s.dazzPro,
                          titleBold: true,
                          trailing: const Icon(Icons.chevron_right,
                              color: _kGray, size: 20),
                          onTap: () {},
                        ),
                        _SettingsDivider(),
                        _SettingsRow(
                          title: s.restorePurchase,
                          onTap: () async {
                            await ref
                                .read(subscriptionServiceProvider.notifier)
                                .restorePurchases();
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
                          trailing: const Icon(Icons.chevron_right,
                              color: _kGray, size: 20),
                          onTap: () => _showLanguagePicker(context, ref, s),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // 分组3：相机设置（精简后）
                    _SettingsGroup(
                      children: [
                        _SettingsRow(
                          title: s.renderMode,
                          trailing: _RenderModeSegment(
                            value: camState.renderStyleMode,
                            replicaLabel: s.replicaModeShort,
                            smartLabel: s.smartModeShort,
                            onChanged: (mode) {
                              if (mode != null) {
                                camNotifier.setRenderStyleMode(mode);
                              }
                            },
                          ),
                        ),
                        _SettingsDivider(),
                        _SettingsRow(
                          title: s.previewMode,
                          subtitle: s.previewModeHint,
                          trailing: _PreviewModeSegment(
                            value: camState.previewPerformanceMode,
                            lightweightLabel: s.previewModeLightweightShort,
                            performanceLabel: s.previewModePerformanceShort,
                            onChanged: (mode) {
                              if (mode != null) {
                                camNotifier.setPreviewPerformanceMode(mode);
                              }
                            },
                          ),
                        ),
                        _SettingsDivider(),
                        _SettingsRow(
                          title: s.mirrorFront,
                          trailing: _RedSwitch(
                            // 直接从 cameraAppProvider 读取，保证开关状态与相机层同步
                            value: camState.mirrorFrontCamera,
                            onChanged: (_) {
                              camNotifier.setMirrorFrontCamera(
                                  !camState.mirrorFrontCamera);
                            },
                          ),
                        ),
                        _SettingsDivider(),
                        _SettingsRow(
                          title: s.mirrorBack,
                          trailing: _RedSwitch(
                            value: camState.mirrorBackCamera,
                            onChanged: (_) {
                              camNotifier.setMirrorBackCamera(
                                  !camState.mirrorBackCamera);
                            },
                          ),
                        ),
                        _SettingsDivider(),
                        _SettingsRow(
                          title: s.saveLocation,
                          trailing: _RedSwitch(
                            value: camState.locationEnabled,
                            onChanged: (_) async {
                              await _toggleLocationPermission(context, ref, s);
                            },
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
                            value: camState.shutterVibrationEnabled,
                            onChanged: (_) {
                              camNotifier.setShutterVibrationEnabled(
                                  !camState.shutterVibrationEnabled);
                            },
                          ),
                        ),
                        _SettingsDivider(),
                        _SettingsRow(
                          title: s.shutterSound,
                          trailing: _RedSwitch(
                            value: camState.shutterSoundEnabled,
                            onChanged: (_) {
                              camNotifier.setShutterSoundEnabled(
                                  !camState.shutterSoundEnabled);
                            },
                          ),
                        ),
                        _SettingsDivider(),
                        // 保留设定 → 跳转子页面
                        _SettingsRow(
                          title: s.retainSettings,
                          trailing: const Icon(Icons.chevron_right,
                              color: _kGray, size: 20),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const RetainSettingsScreen(),
                            ),
                          ),
                        ),
                        _SettingsDivider(),
                        _SettingsRow(
                          title: s.copyCalibrationInfo,
                          trailing: const Icon(Icons.copy_rounded,
                              color: _kGray, size: 18),
                          onTap: () => _copyCalibrationInfo(context, ref, s),
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
                            if (lang == AppLanguage.zhHans ||
                                lang == AppLanguage.zhHant)
                              const TextSpan(text: ' 标签。'),
                            if (lang == AppLanguage.en ||
                                lang == AppLanguage.ms)
                              const TextSpan(
                                  text: ' when posting on social media.'),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            lang.displayName,
                            style: TextStyle(
                              color: isSelected ? _kRed : _kWhite,
                              fontSize: 16,
                              fontWeight: isSelected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
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
  final String? subtitle;
  final bool titleBold;
  final Widget? trailing;
  final String? trailingLabel;
  final VoidCallback? onTap;

  const _SettingsRow({
    required this.title,
    this.subtitle,
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
          crossAxisAlignment: subtitle != null
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: _kWhite,
                      fontSize: 16,
                      fontWeight: titleBold ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        color: _kGray,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
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

class _RenderModeSegment extends StatelessWidget {
  final RenderStyleMode value;
  final String replicaLabel;
  final String smartLabel;
  final ValueChanged<RenderStyleMode?> onChanged;

  const _RenderModeSegment({
    required this.value,
    required this.replicaLabel,
    required this.smartLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoSlidingSegmentedControl<RenderStyleMode>(
      backgroundColor: const Color(0xFF2C2C2E),
      thumbColor: _kRed,
      groupValue: value,
      onValueChanged: onChanged,
      children: {
        RenderStyleMode.replica: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            replicaLabel,
            style: const TextStyle(color: _kWhite, fontSize: 12),
          ),
        ),
        RenderStyleMode.smart: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            smartLabel,
            style: const TextStyle(color: _kWhite, fontSize: 12),
          ),
        ),
      },
    );
  }
}

class _PreviewModeSegment extends StatelessWidget {
  final PreviewPerformanceMode value;
  final String lightweightLabel;
  final String performanceLabel;
  final ValueChanged<PreviewPerformanceMode?> onChanged;

  const _PreviewModeSegment({
    required this.value,
    required this.lightweightLabel,
    required this.performanceLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoSlidingSegmentedControl<PreviewPerformanceMode>(
      backgroundColor: const Color(0xFF2C2C2E),
      thumbColor: _kRed,
      groupValue: value,
      onValueChanged: onChanged,
      children: {
        PreviewPerformanceMode.lightweight: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            lightweightLabel,
            style: const TextStyle(color: _kWhite, fontSize: 12),
          ),
        ),
        PreviewPerformanceMode.performance: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            performanceLabel,
            style: const TextStyle(color: _kWhite, fontSize: 12),
          ),
        ),
      },
    );
  }
}

// ─── 保留设定子页面 ────────────────────────────────────────────────────────────
class RetainSettingsScreen extends ConsumerWidget {
  const RetainSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final retain = ref.watch(retainSettingsProvider);
    final notifier = ref.read(retainSettingsProvider.notifier);
    final lang = ref.watch(languageProvider);
    final s = sOf(lang);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _kBg,
        body: SafeArea(
          child: Column(
            children: [
              // ── 顶部导航栏 ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: SizedBox(
                  height: 44,
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.of(context).pop(),
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
                      Expanded(
                        child: Center(
                          child: Text(
                            s.retainSettings,
                            style: const TextStyle(
                              color: _kWhite,
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 36),
                    ],
                  ),
                ),
              ),
              // ── 内容 ──
              Expanded(
                child: ListView(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  children: [
                    _SettingsGroup(
                      children: [
                        _RetainItem(
                          title: s.retainTemperature,
                          subtitle: s.retainTemperatureDesc,
                          value: retain.retainTemperature,
                          onChanged: (_) =>
                              notifier.toggle('retainTemperature'),
                        ),
                        _SettingsDivider(),
                        _RetainItem(
                          title: s.retainExposure,
                          subtitle: s.retainExposureDesc,
                          value: retain.retainExposure,
                          onChanged: (_) => notifier.toggle('retainExposure'),
                        ),
                        _SettingsDivider(),
                        _RetainItem(
                          title: s.retainZoom,
                          subtitle: s.retainZoomDesc,
                          value: retain.retainZoom,
                          onChanged: (_) => notifier.toggle('retainZoom'),
                        ),
                        _SettingsDivider(),
                        _RetainItem(
                          title: s.retainFrame,
                          subtitle: s.retainFrameDesc,
                          value: retain.retainFrame,
                          onChanged: (_) => notifier.toggle('retainFrame'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 带副标题的保留设定行
class _RetainItem extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _RetainItem({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: _kWhite,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: _kGray,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _RedSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
