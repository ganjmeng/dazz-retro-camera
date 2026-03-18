import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/app_logger.dart';
import 'services/shutter_sound_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 安装全局崩溃捕获（FlutterError + PlatformDispatcher）
  // 崩溃时通过 AppLogOverlay 的 ValueNotifier 弹出可复制堆栈的弹框
  // 不依赖 navigatorKey，即使路由层崩溃也能显示
  AppLogger.installCrashHandlers();
  AppLogger.i('App', 'DAZZ starting...');

  // 预加载快门声音（后台异步，不阻塞启动）
  ShutterSoundService.instance.initialize();

  runApp(
    const ProviderScope(
      child: RetroCamApp(),
    ),
  );
}
