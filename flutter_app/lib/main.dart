import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/app_logger.dart';
import 'services/shutter_sound_service.dart';

/// 全局 NavigatorKey，供 AppLogger 崩溃弹窗使用
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 安装全局崩溃捕获（FlutterError + PlatformDispatcher）
  // 崩溃时自动弹出可复制堆栈的 ErrorOverlay
  AppLogger.installCrashHandlers(appNavigatorKey);
  AppLogger.i('App', 'DAZZ starting...');

  // 预加载快门声音（后台异步，不阻塞启动）
  ShutterSoundService.instance.initialize();

  runApp(
    ProviderScope(
      child: RetroCamApp(navigatorKey: appNavigatorKey),
    ),
  );
}
