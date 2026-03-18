// ignore_for_file: avoid_print
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ─────────────────────────────────────────────────────────────────────────────
// AppLogger — 专业 Debug 日志系统
//
// 功能：
//   1. 内存环形缓冲（最近 500 条），不写磁盘，不影响性能
//   2. 全局 FlutterError + PlatformDispatcher 崩溃捕获
//   3. 崩溃时自动弹出可复制堆栈的 ErrorOverlay
//   4. 提供 AppLogOverlay Widget，可在 debug 模式下悬浮查看日志
//
// 使用：
//   AppLogger.d('tag', 'message');
//   AppLogger.e('tag', 'error', error: e, stackTrace: st);
//   AppLogger.installCrashHandlers(navigatorKey);  // 在 main() 中调用
// ─────────────────────────────────────────────────────────────────────────────

enum LogLevel { verbose, debug, info, warning, error }

class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String tag;
  final String message;
  final Object? error;
  final StackTrace? stackTrace;

  const LogEntry({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
    this.error,
    this.stackTrace,
  });

  String get levelLabel {
    switch (level) {
      case LogLevel.verbose: return 'V';
      case LogLevel.debug:   return 'D';
      case LogLevel.info:    return 'I';
      case LogLevel.warning: return 'W';
      case LogLevel.error:   return 'E';
    }
  }

  Color get levelColor {
    switch (level) {
      case LogLevel.verbose: return const Color(0xFF9E9E9E);
      case LogLevel.debug:   return const Color(0xFF64B5F6);
      case LogLevel.info:    return const Color(0xFF81C784);
      case LogLevel.warning: return const Color(0xFFFFD54F);
      case LogLevel.error:   return const Color(0xFFEF5350);
    }
  }

  String toFullString() {
    final ts = '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}.'
        '${time.millisecond.toString().padLeft(3, '0')}';
    final buf = StringBuffer('[$ts][$levelLabel][$tag] $message');
    if (error != null) buf.write('\nError: $error');
    if (stackTrace != null) buf.write('\nStackTrace:\n$stackTrace');
    return buf.toString();
  }
}

class AppLogger {
  AppLogger._();

  static const int _maxEntries = 500;
  static final Queue<LogEntry> _buffer = Queue<LogEntry>();
  static final ValueNotifier<int> logCount = ValueNotifier(0);
  static GlobalKey<NavigatorState>? _navigatorKey;

  // ── 写入 ──────────────────────────────────────────────────────────────────

  static void v(String tag, String message) =>
      _log(LogLevel.verbose, tag, message);

  static void d(String tag, String message) =>
      _log(LogLevel.debug, tag, message);

  static void i(String tag, String message) =>
      _log(LogLevel.info, tag, message);

  static void w(String tag, String message, {Object? error, StackTrace? stackTrace}) =>
      _log(LogLevel.warning, tag, message, error: error, stackTrace: stackTrace);

  static void e(String tag, String message, {Object? error, StackTrace? stackTrace}) =>
      _log(LogLevel.error, tag, message, error: error, stackTrace: stackTrace);

  static void _log(
    LogLevel level,
    String tag,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    final entry = LogEntry(
      time: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
      error: error,
      stackTrace: stackTrace,
    );
    _buffer.addLast(entry);
    if (_buffer.length > _maxEntries) _buffer.removeFirst();
    logCount.value = _buffer.length;

    // 同步打印到 console（debug 模式）
    if (kDebugMode) {
      final prefix = '[${entry.levelLabel}][$tag]';
      if (level == LogLevel.error || level == LogLevel.warning) {
        debugPrint('$prefix $message${error != null ? '\n$error' : ''}${stackTrace != null ? '\n$stackTrace' : ''}');
      } else {
        debugPrint('$prefix $message');
      }
    }

    // 崩溃级别：弹出 ErrorOverlay
    if (level == LogLevel.error && _navigatorKey != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showErrorOverlay(entry);
      });
    }
  }

  // ── 读取 ──────────────────────────────────────────────────────────────────

  static List<LogEntry> getAll() => _buffer.toList();

  static List<LogEntry> getErrors() =>
      _buffer.where((e) => e.level == LogLevel.error).toList();

  static String exportAll() => _buffer.map((e) => e.toFullString()).join('\n\n');

  static void clear() {
    _buffer.clear();
    logCount.value = 0;
  }

  // ── 崩溃捕获 ──────────────────────────────────────────────────────────────

  /// 在 main() 中调用，安装全局崩溃处理器
  static void installCrashHandlers(GlobalKey<NavigatorState> navigatorKey) {
    _navigatorKey = navigatorKey;

    // Flutter 框架层错误（Widget build 异常等）
    FlutterError.onError = (FlutterErrorDetails details) {
      e('FlutterError', details.exceptionAsString(),
          error: details.exception,
          stackTrace: details.stack);
      // 保留默认处理（红屏 / console）
      FlutterError.presentError(details);
    };

    // Dart 异步错误（Zone 外未捕获异常）
    PlatformDispatcher.instance.onError = (error, stack) {
      AppLogger.e('UncaughtError', error.toString(),
          error: error, stackTrace: stack);
      return true; // true = 已处理，不再向上传播
    };
  }

  // ── ErrorOverlay ──────────────────────────────────────────────────────────

  static void _showErrorOverlay(LogEntry entry) {
    final context = _navigatorKey?.currentContext;
    if (context == null) return;
    // 避免重复弹出
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => _CrashDialog(entry: entry),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _CrashDialog — 崩溃弹窗，支持一键复制完整堆栈
// ─────────────────────────────────────────────────────────────────────────────
class _CrashDialog extends StatelessWidget {
  final LogEntry entry;
  const _CrashDialog({required this.entry});

  @override
  Widget build(BuildContext context) {
    final fullText = entry.toFullString();
    return Dialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bug_report, color: Color(0xFFEF5350), size: 20),
                const SizedBox(width: 8),
                const Text(
                  'Crash / Error',
                  style: TextStyle(
                    color: Color(0xFFEF5350),
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                  onPressed: () => Navigator.of(context).pop(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.5,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF0D0D0D),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(10),
                child: SelectableText(
                  fullText,
                  style: const TextStyle(
                    color: Color(0xFFEF9A9A),
                    fontSize: 11,
                    fontFamily: 'monospace',
                    height: 1.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: fullText));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('已复制崩溃日志'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('复制崩溃日志'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      final all = AppLogger.exportAll();
                      Clipboard.setData(ClipboardData(text: all));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('已复制全部日志'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    icon: const Icon(Icons.list_alt, size: 16),
                    label: const Text('复制全部日志'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AppLogOverlay — debug 模式下悬浮日志查看器
// 在 MaterialApp 的 builder 中包裹即可：
//   builder: (context, child) => AppLogOverlay(child: child!),
// ─────────────────────────────────────────────────────────────────────────────
class AppLogOverlay extends StatefulWidget {
  final Widget child;
  const AppLogOverlay({super.key, required this.child});

  @override
  State<AppLogOverlay> createState() => _AppLogOverlayState();
}

class _AppLogOverlayState extends State<AppLogOverlay> {
  bool _visible = false;
  List<LogEntry> _entries = [];

  @override
  void initState() {
    super.initState();
    AppLogger.logCount.addListener(_onNewLog);
  }

  @override
  void dispose() {
    AppLogger.logCount.removeListener(_onNewLog);
    super.dispose();
  }

  void _onNewLog() {
    if (_visible && mounted) {
      setState(() => _entries = AppLogger.getAll().reversed.toList());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return widget.child;
    return Stack(
      children: [
        widget.child,
        // 悬浮触发按钮（右下角）
        Positioned(
          right: 12,
          bottom: 80,
          child: ValueListenableBuilder<int>(
            valueListenable: AppLogger.logCount,
            builder: (_, count, __) {
              final errorCount = AppLogger.getErrors().length;
              return GestureDetector(
                onTap: () {
                  setState(() {
                    _visible = !_visible;
                    if (_visible) {
                      _entries = AppLogger.getAll().reversed.toList();
                    }
                  });
                },
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: errorCount > 0
                        ? const Color(0xFFEF5350).withOpacity(0.85)
                        : const Color(0xFF212121).withOpacity(0.85),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: errorCount > 0
                          ? const Color(0xFFEF5350)
                          : Colors.white24,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      errorCount > 0 ? '$errorCount' : '🪲',
                      style: const TextStyle(fontSize: 13, color: Colors.white),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        // 日志面板
        if (_visible)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _LogPanel(
              entries: _entries,
              onClose: () => setState(() => _visible = false),
            ),
          ),
      ],
    );
  }
}

class _LogPanel extends StatelessWidget {
  final List<LogEntry> entries;
  final VoidCallback onClose;
  const _LogPanel({required this.entries, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.45,
      decoration: const BoxDecoration(
        color: Color(0xEE0D0D0D),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        children: [
          // 标题栏
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: const Color(0xFF1A1A1A),
            child: Row(
              children: [
                const Icon(Icons.terminal, color: Colors.white54, size: 16),
                const SizedBox(width: 6),
                Text(
                  'Debug Log (${entries.length})',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () {
                    final all = AppLogger.exportAll();
                    Clipboard.setData(ClipboardData(text: all));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('日志已复制到剪贴板'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.copy, color: Colors.white54, size: 16),
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    AppLogger.clear();
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(Icons.delete_outline, color: Colors.white54, size: 16),
                  ),
                ),
                GestureDetector(
                  onTap: onClose,
                  child: const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(Icons.close, color: Colors.white54, size: 16),
                  ),
                ),
              ],
            ),
          ),
          // 日志列表
          Expanded(
            child: ListView.builder(
              itemCount: entries.length,
              itemBuilder: (_, i) {
                final entry = entries[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                  child: RichText(
                    text: TextSpan(
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontFamily: 'monospace',
                        height: 1.4,
                      ),
                      children: [
                        TextSpan(
                          text: '[${entry.levelLabel}]',
                          style: TextStyle(color: entry.levelColor),
                        ),
                        TextSpan(
                          text: '[${entry.tag}] ',
                          style: const TextStyle(color: Color(0xFFB0BEC5)),
                        ),
                        TextSpan(
                          text: entry.message,
                          style: TextStyle(
                            color: entry.level == LogLevel.error
                                ? const Color(0xFFEF9A9A)
                                : Colors.white70,
                          ),
                        ),
                        if (entry.error != null)
                          TextSpan(
                            text: '\n  ${entry.error}',
                            style: const TextStyle(color: Color(0xFFEF5350)),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
