// camera_lifecycle_manager.dart
// ─────────────────────────────────────────────────────────────────────────────
// 统一相机生命周期状态机
//
// 解决问题：
//   1. 启动/权限/切换/后台等场景导致预览失效
//   2. 原生层 Renderer 重建期间参数丢失（竞态条件）
//   3. 多处散落的 initCamera + 参数重放代码
//
// 状态机：
//   Idle → Starting → Running → Paused → Starting → Running
//                  ↘ Error → Starting (retry)
//
// 核心机制：
//   - 所有参数更新操作在 Running 状态下立即执行
//   - 在 Starting/Reconfiguring 状态下排队，Running 后统一执行
//   - 后台进入 Paused，前台恢复自动重走 Starting → Running
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/camera_definition.dart';
import 'camera_service.dart';

// ── 状态枚举 ──────────────────────────────────────────────────────────────────

enum CameraLifecycleState {
  /// 未初始化（权限未授予或首次启动前）
  idle,
  /// 正在初始化原生硬件（initCamera + setSharpen）
  starting,
  /// 预览正常运行中，可以拍照/调参
  running,
  /// 应用在后台或进入二级页面，原生会话已暂停
  paused,
  /// 正在重新配置（切换分辨率/切换镜头触发 Renderer 重建）
  reconfiguring,
  /// 发生不可恢复的错误
  error,
}

// ── 参数快照（用于重放）────────────────────────────────────────────────────────

class _CameraParamSnapshot {
  final CameraDefinition? camera;
  final String? lensId;
  final double sharpenLevel;
  final double zoomLevel;
  final bool mirrorFrontCamera;
  final Map<String, dynamic>? renderParams;

  const _CameraParamSnapshot({
    this.camera,
    this.lensId,
    this.sharpenLevel = 0.5,
    this.zoomLevel = 1.0,
    this.mirrorFrontCamera = true,
    this.renderParams,
  });
}

// ── CameraLifecycleManager ────────────────────────────────────────────────────

class CameraLifecycleManager extends ChangeNotifier {
  final Ref _ref;

  CameraLifecycleManager(this._ref);

  // 当前状态
  CameraLifecycleState _state = CameraLifecycleState.idle;
  CameraLifecycleState get state => _state;

  // 错误信息
  String? _error;
  String? get error => _error;

  // 最新参数快照（用于重建后重放）
  _CameraParamSnapshot _snapshot = const _CameraParamSnapshot();

  // 操作队列：在 Starting/Reconfiguring 时排队，Running 后执行
  final List<Future<void> Function()> _pendingOps = [];

  // 防止并发初始化
  bool _isInitializing = false;

  // ── 状态转换 ────────────────────────────────────────────────────────────────

  void _setState(CameraLifecycleState newState, {String? errorMsg}) {
    if (_state == newState) return;
    debugPrint('[CameraLifecycle] ${_state.name} → ${newState.name}'
        '${errorMsg != null ? " ($errorMsg)" : ""}');
    _state = newState;
    _error = errorMsg;
    notifyListeners();
  }

  // ── 公开接口 ────────────────────────────────────────────────────────────────

  /// 更新参数快照（由 camera_notifier 在每次状态变化时调用）
  void updateSnapshot({
    CameraDefinition? camera,
    String? lensId,
    double? sharpenLevel,
    double? zoomLevel,
    bool? mirrorFrontCamera,
    Map<String, dynamic>? renderParams,
  }) {
    _snapshot = _CameraParamSnapshot(
      camera: camera ?? _snapshot.camera,
      lensId: lensId ?? _snapshot.lensId,
      sharpenLevel: sharpenLevel ?? _snapshot.sharpenLevel,
      zoomLevel: zoomLevel ?? _snapshot.zoomLevel,
      mirrorFrontCamera: mirrorFrontCamera ?? _snapshot.mirrorFrontCamera,
      renderParams: renderParams ?? _snapshot.renderParams,
    );
  }

  /// 启动相机（首次初始化或从 Paused 恢复）
  /// [force] = true 时即使已在 Running 也重新初始化（用于切换分辨率）
  Future<void> start({bool force = false}) async {
    if (_isInitializing) {
      debugPrint('[CameraLifecycle] start() called while initializing, skipping');
      return;
    }
    if (_state == CameraLifecycleState.running && !force) {
      debugPrint('[CameraLifecycle] already running, skipping start()');
      return;
    }

    _isInitializing = true;
    _setState(CameraLifecycleState.starting);

    try {
      final svc = _ref.read(cameraServiceProvider.notifier);

      // 1. 初始化原生相机硬件（获取 textureId）
      await svc.initCamera();

      // 2. 重放所有参数（确保 Renderer 就绪后再发送）
      await _replayParams();

      _setState(CameraLifecycleState.running);

      // 3. 执行排队的操作
      await _flushPendingOps();
    } catch (e) {
      _setState(CameraLifecycleState.error, errorMsg: e.toString());
    } finally {
      _isInitializing = false;
    }
  }

  /// 暂停相机（进入后台或跳转二级页面时调用）
  Future<void> pause() async {
    if (_state != CameraLifecycleState.running) return;
    _setState(CameraLifecycleState.paused);
    try {
      await _ref.read(cameraServiceProvider.notifier).stopPreview();
    } catch (e) {
      debugPrint('[CameraLifecycle] pause() stopPreview error: $e');
    }
  }

  /// 恢复相机（从后台切回或从二级页面返回时调用）
  Future<void> resume() async {
    if (_state != CameraLifecycleState.paused &&
        _state != CameraLifecycleState.error) return;
    await start();
  }

  /// 重新配置（切换分辨率时调用，会重建 Renderer）
  Future<void> reconfigure() async {
    if (_state != CameraLifecycleState.running) return;
    _setState(CameraLifecycleState.reconfiguring);
    _isInitializing = true;
    try {
      final svc = _ref.read(cameraServiceProvider.notifier);
      await svc.initCamera();
      await _replayParams();
      _setState(CameraLifecycleState.running);
      await _flushPendingOps();
    } catch (e) {
      _setState(CameraLifecycleState.error, errorMsg: e.toString());
    } finally {
      _isInitializing = false;
    }
  }

  /// 提交参数更新操作
  /// 如果当前 Running，立即执行；否则排队等待
  Future<void> submitParamUpdate(Future<void> Function() op) async {
    if (_state == CameraLifecycleState.running) {
      await op();
    } else {
      _pendingOps.add(op);
    }
  }

  // ── 核心：统一参数重放 ───────────────────────────────────────────────────────

  /// 将当前快照中的所有参数重新发送到原生层
  /// 在每次 initCamera 完成后调用，确保 Renderer 参数完整
  Future<void> _replayParams() async {
    final svc = _ref.read(cameraServiceProvider.notifier);
    final snap = _snapshot;

    // STEP 1: 设置清晰度档位（会触发 Android rebind，必须最先执行）
    await svc.setSharpen(snap.sharpenLevel);

    // STEP 2: 发送相机基础配置（defaultLook、cameraId 等）
    if (snap.camera != null) {
      await svc.setCamera(snap.camera!);
    }

    // STEP 3: 发送镜头参数
    if (snap.camera != null && snap.lensId != null) {
      final lens = snap.camera!.lensById(snap.lensId);
      await svc.updateLensParams(
        distortion:           lens?.distortion           ?? 0.0,
        vignette:             lens?.vignette             ?? 0.0,
        zoomFactor:           lens?.zoomFactor           ?? 1.0,
        fisheyeMode:          lens?.fisheyeMode          ?? false,
        chromaticAberration:  lens?.chromaticAberration  ?? 0.0,
        bloom:                lens?.bloom                ?? 0.0,
        softFocus:            lens?.softFocus            ?? 0.0,
        exposure:             lens?.exposure             ?? 0.0,
        contrast:             lens?.contrast             ?? 0.0,
        saturation:           lens?.saturation           ?? 0.0,
        highlightCompression: lens?.highlightCompression ?? 0.0,
      );
    }

    // STEP 4: 发送完整渲染参数（滤镜 + defaultLook 组合值）
    if (snap.renderParams != null) {
      svc.updateRenderParams(snap.renderParams!);
    }

    // STEP 5: 恢复缩放
    if (snap.zoomLevel != 1.0) {
      await svc.setZoom(snap.zoomLevel);
    }

    // STEP 6: 恢复镜像设置
    await svc.setMirrorFrontCamera(snap.mirrorFrontCamera);
  }

  // ── 内部工具 ────────────────────────────────────────────────────────────────

  Future<void> _flushPendingOps() async {
    if (_pendingOps.isEmpty) return;
    final ops = List<Future<void> Function()>.from(_pendingOps);
    _pendingOps.clear();
    for (final op in ops) {
      try {
        await op();
      } catch (e) {
        debugPrint('[CameraLifecycle] pending op error: $e');
      }
    }
  }

  @override
  void dispose() {
    _pendingOps.clear();
    super.dispose();
  }
}

// ── Provider ──────────────────────────────────────────────────────────────────

final cameraLifecycleProvider = ChangeNotifierProvider<CameraLifecycleManager>((ref) {
  return CameraLifecycleManager(ref);
});
