import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

bool get kEnableAndroidDebugCrashOverlay =>
    kDebugMode && !kIsWeb && Platform.isAndroid;

@immutable
class DebugCrashInfo {
  final String title;
  final String message;
  final String? stackTrace;
  final DateTime timestamp;

  const DebugCrashInfo({
    required this.title,
    required this.message,
    this.stackTrace,
    required this.timestamp,
  });

  String get timestampLabel => timestamp.toIso8601String();
}

class DebugCrashOverlayController {
  DebugCrashOverlayController._();

  static final DebugCrashOverlayController instance =
      DebugCrashOverlayController._();

  final ValueNotifier<DebugCrashInfo?> current = ValueNotifier<DebugCrashInfo?>(
    null,
  );

  void report({
    required String title,
    required Object error,
    StackTrace? stackTrace,
  }) {
    if (!kEnableAndroidDebugCrashOverlay) return;
    current.value = DebugCrashInfo(
      title: title,
      message: error.toString(),
      stackTrace: stackTrace?.toString(),
      timestamp: DateTime.now(),
    );
  }

  void reportMessage({
    required String title,
    required String message,
    String? stackTrace,
  }) {
    if (!kEnableAndroidDebugCrashOverlay) return;
    current.value = DebugCrashInfo(
      title: title,
      message: message,
      stackTrace: stackTrace,
      timestamp: DateTime.now(),
    );
  }

  void clear() {
    current.value = null;
  }
}

class DebugCrashOverlay extends StatelessWidget {
  const DebugCrashOverlay({
    super.key,
    required this.info,
    required this.onDismiss,
  });

  final DebugCrashInfo info;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xF2151518),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0x33FF5A5F),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.error_outline,
                      color: Color(0xFFFF6B70),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          info.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          info.timestampLabel,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: onDismiss,
                    child: const Text('关闭'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1F),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      [
                        info.message.trim(),
                        if ((info.stackTrace ?? '').trim().isNotEmpty)
                          info.stackTrace!.trim(),
                      ].join('\n\n'),
                      style: const TextStyle(
                        color: Color(0xFFF6F7F9),
                        fontSize: 13,
                        height: 1.45,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                '仅 Android Debug 模式显示。原生进程级闪退不会被这个页面接住。',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
