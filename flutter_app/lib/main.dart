import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 初始化相关服务，例如日志、本地存储等
  // await initServices();

  runApp(
    const ProviderScope(
      child: RetroCamApp(),
    ),
  );
}
