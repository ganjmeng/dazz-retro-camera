import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'services/shutter_sound_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 预加载快门声音（后台异步，不阻塞启动）
  ShutterSoundService.instance.initialize();

  // 初始化相关服务，例如日志、本地存储等
  // await initServices();

  runApp(
    const ProviderScope(
      child: RetroCamApp(),
    ),
  );
}
