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
//   3. 崩溃时通过 ValueNotifier 驱动 AppLogOverlay 弹出弹框
//      （不依赖 navigatorKey，即使路由层崩溃也能显示）
//   4. AppLogOverlay Widget：debug 模式下悬浮查看日志 + 崩溃弹框
//
// 使用：
//   AppLogger.d('tag', 'message');
//   AppLogger.e('tag', 'error', error: e, stackTrace: st);
//   AppLogger.installCrashHandlers();  // 在 main() 中调用
//   // 在 MaterialApp builder 中包裹：
//   builder: (ctx, child) => AppLogOverlay(child: child!)
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

  /// 日志条数变化通知（AppLogOverlay 监听此 notifier 刷新 UI）
  static final ValueNotifier<int> logCount = ValueNotifier(0);

  /// 最新错误通知（AppLogOverlay 监听此 notifier 弹出崩溃弹框）
  /// 值为 null 表示无待显示错误
  static final ValueNotifier<LogEntry?> pendingError = ValueNotifier(null);

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

    // 通知日志面板刷新
    logCount.value = _buffer.length;

    // 同步打印到 console（debug 模式）
    if (kDebugMode) {
      final prefix = '[${entry.levelLabel}][$tag]';
      if (level == LogLevel.error || level == LogLevel.warning) {
        debugPrint('$prefix $message'
            '${error != null ? '\n$error' : ''}'
            '${stackTrace != null ? '\n$stackTrace' : ''}');
      } else {
        debugPrint('$prefix $message');
      }
    }

    // 错误级别：通过 ValueNotifier 通知 AppLogOverlay 弹出崩溃弹框
    // 不依赖 navigatorKey，AppLogOverlay 在 MaterialApp.builder 层监听，
    // 即使路由层崩溃也能显示
    if (level == LogLevel.error) {
      // 用微任务避免在帧渲染中途修改状态
      Future.microtask(() {
        pendingError.value = entry;
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
  static void installCrashHandlers() {
    // Flutter 框架层错误（Widget build 异常等）
    FlutterError.onError = (FlutterErrorDetails details) {
      e('FlutterError', details.exceptionAsString(),
          error: details.exception,
          stackTrace: details.stack);
      // 保留默认处理（red screen / console）
      FlutterError.presentError(details);
    };

    // Dart 异步错误（Zone 外未捕获异常）
    PlatformDispatcher.instance.onError = (error, stack) {
      AppLogger.e('UncaughtError', error.toString(),
          error: error, stackTrace: stack);
      return true; // true = 已处理，不再向上传播
    };
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AppLogOverlay — debug 模式下悬浮日志查看器 + 崩溃弹框
//
// 在 MaterialApp 的 builder 中包裹：
//   builder: (context, child) => AppLogOverlay(child: child!),
//
// 崩溃弹框原理：
//   监听 AppLogger.pendingError ValueNotifier，有新错误时直接在当前
//   Overlay 层插入弹框 Widget，完全不依赖 Navigator/GoRouter。
// ─────────────────────────────────────────────────────────────────────────────
class AppLogOverlay extends StatefulWidget {
  final Widget child;
  const AppLogOverlay({super.key, required this.child});

  @override
  State<AppLogOverlay> createState() => _AppLogOverlayState();
}

class _AppLogOverlayState extends State<AppLogOverlay> {
  bool _logPanelVisible = false;
  List<LogEntry> _entries = [];

  // 当前显示的崩溃弹框 entry（null = 不显示）
  LogEntry? _crashEntry;

  @override
  void initState() {
    super.initState();
    AppLogger.logCount.addListener(_onNewLog);
    AppLogger.pendingError.addListener(_onNewError);
  }

  @override
  void dispose() {
    AppLogger.logCount.removeListener(_onNewLog);
    AppLogger.pendingError.removeListener(_onNewError);
    super.dispose();
  }

  void _onNewLog() {
    if (_logPanelVisible && mounted) {
      setState(() => _entries = AppLogger.getAll().reversed.toList());
    } else if (mounted) {
      // 仅刷新徽标数字
      setState(() {});
    }
  }

  void _onNewError() {
    final entry = AppLogger.pendingError.value;
    if (entry != null && mounted) {
      setState(() => _crashEntry = entry);
      // 消费掉，避免重复弹
      AppLogger.pendingError.value = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // release 模式不显示任何 debug UI
    if (!kDebugMode) return widget.child;

    return Stack(
      children: [
        widget.child,

        // ── 悬浮触发按钮（右下角）──────────────────────────────────────────
        Positioned(
          right: 12,
          bottom: 80,
          child: GestureDetector(
            onTap: () {
              setState(() {
                _logPanelVisible = !_logPanelVisible;
                if (_logPanelVisible) {
                  _entries = AppLogger.getAll().reversed.toList();
                }
              });
            },
            child: _FloatingLogButton(),
          ),
        ),

        // ── 日志面板（底部滑出）──────────────────────────────────────────────
        if (_logPanelVisible)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _LogPanel(
              entries: _entries,
              onClose: () => setState(() => _logPanelVisible = false),
            ),
          ),

        // ── 崩溃弹框（全屏遮罩，最高层）─────────────────────────────────────
        if (_crashEntry != null)
          Positioned.fill(
            child: _CrashOverlay(
              entry: _crashEntry!,
              onDismiss: () => setState(() => _crashEntry = null),
            ),
          ),
      ],
    );
  }
}

// ── 悬浮按钮 ─────────────────────────────────────────────────────────────────
class _FloatingLogButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final errorCount = AppLogger.getErrors().length;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: errorCount > 0
            ? const Color(0xFFEF5350).withOpacity(0.9)
            : const Color(0xFF212121).withOpacity(0.85),
        shape: BoxShape.circle,
        border: Border.all(
          color: errorCount > 0 ? const Color(0xFFEF5350) : Colors.white24,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.4),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Center(
        child: Text(
          errorCount > 0 ? '$errorCount' : '🪲',
          style: const TextStyle(fontSize: 13, color: Colors.white),
        ),
      ),
    );
  }
}

// ── 崩溃弹框 Overlay（不依赖 Navigator）─────────────────────────────────────
class _CrashOverlay extends StatelessWidget {
  final LogEntry entry;
  final VoidCallback onDismiss;
  const _CrashOverlay({required this.entry, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final fullText = entry.toFullString();
    return Material(
      color: Colors.black.withOpacity(0.75),
      child: SafeArea(
        child: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFEF5350).withOpacity(0.5)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题栏
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: const BoxDecoration(
                    color: Color(0xFF2A1A1A),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.bug_report, color: Color(0xFFEF5350), size: 18),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Crash / Error',
                          style: TextStyle(
                            color: Color(0xFFEF5350),
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: onDismiss,
                        child: const Icon(Icons.close, color: Colors.white54, size: 18),
                      ),
                    ],
                  ),
                ),
                // 日志内容
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.45,
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
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
                // 操作按钮
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: _ActionButton(
                          icon: Icons.copy,
                          label: '复制崩溃日志',
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: fullText));
                            _showToast(context, '已复制崩溃日志');
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _ActionButton(
                          icon: Icons.list_alt,
                          label: '复制全部日志',
                          onTap: () {
                            Clipboard.setData(
                                ClipboardData(text: AppLogger.exportAll()));
                            _showToast(context, '已复制全部日志');
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showToast(BuildContext context, String msg) {
    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (_) => Positioned(
        bottom: 60,
        left: 0,
        right: 0,
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(msg,
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(const Duration(seconds: 2), entry.remove);
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ActionButton(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white24),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: Colors.white60),
            const SizedBox(width: 4),
            Text(label,
                style: const TextStyle(color: Colors.white60, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

// ── 日志面板 ─────────────────────────────────────────────────────────────────
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
                    Clipboard.setData(
                        ClipboardData(text: AppLogger.exportAll()));
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.copy, color: Colors.white54, size: 16),
                  ),
                ),
                GestureDetector(
                  onTap: AppLogger.clear,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child:
                        Icon(Icons.delete_outline, color: Colors.white54, size: 16),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
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
