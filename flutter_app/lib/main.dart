import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/debug_crash_overlay.dart';
import 'services/shutter_sound_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 预加载快门声音（后台异步，不阻塞启动）
  ShutterSoundService.instance.initialize();

  if (kEnableAndroidDebugCrashOverlay) {
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      DebugCrashOverlayController.instance.report(
        title: 'Flutter 崩溃',
        error: details.exception,
        stackTrace: details.stack,
      );
    };

    ErrorWidget.builder = (details) {
      DebugCrashOverlayController.instance.report(
        title: 'Widget 构建异常',
        error: details.exception,
        stackTrace: details.stack,
      );
      return Material(
        color: const Color(0xF2151518),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              details.exceptionAsString(),
              style: const TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      DebugCrashOverlayController.instance.report(
        title: 'Dart 未捕获异常',
        error: error,
        stackTrace: stack,
      );
      return true;
    };
  }

  // 初始化相关服务，例如日志、本地存储等
  // await initServices();

  runApp(
    const ProviderScope(
      child: RetroCamApp(),
    ),
  );
}
