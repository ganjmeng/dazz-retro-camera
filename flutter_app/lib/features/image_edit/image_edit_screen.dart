
// ─────────────────────────────────────────────────────────────────────────────
// 设计哲学：Darkroom Aesthetics — 纯黑背景，白色控件，复用相机页所有效果逻辑
// 底部工具按钮显示/隐藏由当前相机 uiCap 决定，完全复用拍摄页逻辑
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../models/camera_definition.dart';
import '../camera/camera_notifier.dart';
import '../camera/camera_config_sheet.dart';
import '../camera/capture_pipeline.dart';
import '../camera/preview_renderer.dart' as renderer_lib;
import 'package:image/image.dart' as image_lib;
import '../../core/l10n.dart';


// ─────────────────────────────────────────────────────────────────────────────
// 入口
// ─────────────────────────────────────────────────────────────────────────────
Future<void> openImageImportFlow(BuildContext context) async {
  final picker = ImagePicker();
  final XFile? file = await picker.pickImage(source: ImageSource.gallery);
  if (file == null) return;
  if (!context.mounted) return;

  // 显示转圈遮罩：图片选好后到页面跳转前，高清图片需要时间处理
  OverlayEntry? loadingOverlay;
  loadingOverlay = OverlayEntry(
    builder: (_) => const _ImportLoadingOverlay(),
  );
  Overlay.of(context).insert(loadingOverlay);

  try {
    // 预读取图片大小，确保文件可访问
    await File(file.path).length();
  } catch (_) {}

  if (!context.mounted) {
    loadingOverlay.remove();
    return;
  }

  // 跳转到编辑页（页面内有自己的通用加载动画）
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (ctx) => ProviderScope(
        parent: ProviderScope.containerOf(context),
        child: ImageEditScreen(imagePath: file.path),
      ),
      fullscreenDialog: true,
    ),
  ).then((_) => loadingOverlay?.remove()).catchError((_) => loadingOverlay?.remove());
  // 如果 push 前尚未移除，在返回后移除
  loadingOverlay.remove();
}

/// 导入图片时的转圈加载遮罩（独立于现有通用加载动画）
class _ImportLoadingOverlay extends StatelessWidget {
  const _ImportLoadingOverlay();

  @override
  Widget build(BuildContext context) {
    return const Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          // 半透明黑色背景
          Positioned.fill(
            child: ColoredBox(color: Color(0xCC000000)),
          ),
          // 居中转圈
          Center(
            child: SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ImageEditScreen
// ─────────────────────────────────────────────────────────────────────────────
class ImageEditScreen extends ConsumerStatefulWidget {
  final String imagePath;
  const ImageEditScreen({super.key, required this.imagePath});
  @override
  ConsumerState<ImageEditScreen> createState() => _ImageEditScreenState();
}

class _ImageEditScreenState extends ConsumerState<ImageEditScreen> {
  // ── 编辑参数 ──────────────────────────────────────────────────────────────
  double _fineRotation = 0.0;  // 精细旋转：-45 ~ 45 度（刻度尺控制）
  int _coarseRotation = 0;     // 粗旋转：0/90/180/270（旋转按钮控制）
  bool _flipH = false;
  bool _isCropMode = false;
  Rect _cropRect = const Rect.fromLTWH(0, 0, 1, 1);

  // ── 预览手势（缩放/拖动）────────────────────────────────────────────────
  double _previewScale = 1.0;       // 当前缩放倍率
  double _scaleStart = 1.0;         // 捏合手势开始时的缩放倍率
  Offset _previewOffset = Offset.zero; // 当前平移偏移
  Offset _panStart = Offset.zero;   // 拖动手势开始时的偏移

  // ── 面板状态 ──────────────────────────────────────────────────────────────
  String? _activePanel; // 'filter' | 'frame' | 'watermark' | null

  // ── 加载/保存 ─────────────────────────────────────────────────────────────
  bool _isLoading = true;
  bool _isSaving = false;

  // ── GPU 预览 ─────────────────────────────────────────────────────────────
  static const MethodChannel _gpuChannel = MethodChannel('com.retrocam.app/camera_control');
  String? _gpuPreviewPath;       // GPU 处理后的预览图临时文件路径
  bool _gpuProcessing = false;   // 是否正在 GPU 处理中
  int _gpuRequestId = 0;         // 用于取消过期的 GPU 请求

  // ── 高清图片缩小后的预览源路径（避免 OOM）──────────────────────────────────
  String? _resizedPreviewPath;   // 缩小到 ≤4096px 的预览源
  static const int _kMaxPreviewDim = 4096;

  // ── 白平衡/曝光控件状态 ──────────────────────────────────────────────────
  bool _showExposureSlider = false;
  bool _showWbPanel = false;

  double get _totalRotation => _coarseRotation.toDouble() + _fineRotation;

  @override
  void initState() {
    super.initState();
    _initPreview();
  }

  /// 初始化预览：先缩小高清图片到安全尺寸（在 isolate 中执行，避免卡 UI），再生成 GPU 预览
  Future<void> _initPreview() async {
    try {
      // 1. 读取原图并检查尺寸
      final originalBytes = await File(widget.imagePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(originalBytes);
      final frame = await codec.getNextFrame();
      final srcW = frame.image.width;
      final srcH = frame.image.height;
      frame.image.dispose();

      // 2. 如果原图超过 _kMaxPreviewDim，在后台 isolate 中缩小（避免卡 UI，让加载动画正常渲染）
      if (srcW > _kMaxPreviewDim || srcH > _kMaxPreviewDim) {
        final scale = _kMaxPreviewDim / math.max(srcW, srcH);
        final newW = (srcW * scale).round();
        final newH = (srcH * scale).round();
        // 在独立 isolate 中执行 CPU 密集的解码+缩放，主线程保持响应
        final resizedJpg = await Isolate.run(() {
          final decoded = image_lib.decodeImage(originalBytes);
          if (decoded == null) return null;
          final resized = image_lib.copyResize(decoded, width: newW, height: newH,
              interpolation: image_lib.Interpolation.linear);
          return image_lib.encodeJpg(resized, quality: 92);
        });
        if (resizedJpg != null) {
          final tmpPath = '${Directory.systemTemp.path}/dazz_resized_${DateTime.now().millisecondsSinceEpoch}.jpg';
          await File(tmpPath).writeAsBytes(resizedJpg);
          _resizedPreviewPath = tmpPath;
          debugPrint('[ImageEditScreen] Resized ${srcW}x$srcH → ${newW}x$newH for preview');
        }
      }

      if (!mounted) return;
      setState(() => _isLoading = false);

      // 3. 等待 camera 就绪后再触发 GPU 预览
      //    renderParams 依赖 camera != null，camera 由持久化异步加载，
      //    此处轮询最多 3 秒，就绪后立即刷新；超时则降级显示原图。
      await _waitForCameraAndRefresh();
    } catch (e) {
      debugPrint('[ImageEditScreen] _initPreview error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// 等待 camera 就绪（最多 3 秒），就绪后触发 GPU 预览
  Future<void> _waitForCameraAndRefresh() async {
    // 先尝试直接刷新（camera 可能已经就绪）
    if (ref.read(cameraAppProvider).renderParams != null) {
      _refreshGpuPreview();
      return;
    }
    // camera 尚未就绪，监听状态变化，最多等待 3 秒
    const maxWait = Duration(seconds: 3);
    const pollInterval = Duration(milliseconds: 100);
    final deadline = DateTime.now().add(maxWait);
    while (mounted && DateTime.now().isBefore(deadline)) {
      await Future.delayed(pollInterval);
      if (!mounted) return;
      if (ref.read(cameraAppProvider).renderParams != null) {
        _refreshGpuPreview();
        return;
      }
    }
    // 超时：camera 未就绪，降级显示原图（_gpuPreviewPath 为 null 时 _buildTransformedImage 显示原图）
    debugPrint('[ImageEditScreen] Camera not ready after 3s, showing original image');
  }

  /// GPU 预览使用的源路径（缩小后的 or 原图）
  String get _previewSourcePath => _resizedPreviewPath ?? widget.imagePath;

  /// 调用 Native GPU Shader 生成带滤镜效果的预览图
  Future<void> _refreshGpuPreview() async {
    final st = ref.read(cameraAppProvider);
    final renderParams = st.renderParams;
    if (renderParams == null) return;

    final requestId = ++_gpuRequestId;
    if (_gpuProcessing) return; // 已有请求在处理中，等下一次
    _gpuProcessing = true;

    try {
      final result = await _gpuChannel.invokeMethod<Map>('processWithGpu', {
        'filePath': _previewSourcePath,
        'params': renderParams.toJson(),
      });
      // 检查请求是否过期（用户可能已经切换了相机/滤镜）
      if (!mounted || requestId != _gpuRequestId) return;
      if (result != null && result['filePath'] != null) {
        // 删除旧的预览临时文件
        if (_gpuPreviewPath != null) {
          try { File(_gpuPreviewPath!).deleteSync(); } catch (_) {}
        }
        setState(() => _gpuPreviewPath = result['filePath'] as String);
      }
    } catch (e) {
      debugPrint('[ImageEditScreen] GPU preview failed: $e');
    } finally {
      _gpuProcessing = false;
      // 如果有新的请求排队（requestId 已递增），立即处理
      if (mounted && requestId != _gpuRequestId) {
        _refreshGpuPreview();
      }
    }
  }

  @override
  void dispose() {
    // 清理 GPU 预览临时文件
    if (_gpuPreviewPath != null) {
      try { File(_gpuPreviewPath!).deleteSync(); } catch (_) {}
    }
    // 清理缩小后的预览源
    if (_resizedPreviewPath != null) {
      try { File(_resizedPreviewPath!).deleteSync(); } catch (_) {}
    }
    super.dispose();
  }

  void _rotate90() => setState(() => _coarseRotation = (_coarseRotation + 90) % 360);
  void _flipHorizontal() => setState(() => _flipH = !_flipH);
  void _resetRotation() => setState(() => _fineRotation = 0.0);

  void _togglePanel(String panel) {
    setState(() => _activePanel = _activePanel == panel ? null : panel);
  }

  // ── 保存 ──────────────────────────────────────────────────────────────────
  Future<void> _save() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      final st = ref.read(cameraAppProvider);
      final camera = st.camera;
      if (camera == null) {
        _showSnack(sOf(ref.read(languageProvider)).selectCameraFirst);
        setState(() => _isSaving = false);
        return;
      }

      // 保存时使用原始高清图重新 GPU 处理（保证成片质量）
      final renderParams = st.renderParams;
      String gpuSourceForSave = widget.imagePath;

      if (renderParams != null) {
        try {
          final result = await _gpuChannel.invokeMethod<Map>('processWithGpu', {
            'filePath': widget.imagePath, // 使用原始高清图
            'params': renderParams.toJson(),
          });
          if (result != null && result['filePath'] != null) {
            gpuSourceForSave = result['filePath'] as String;
          }
        } catch (e) {
          debugPrint('[ImageEditScreen] GPU save processing failed, using preview: $e');
          // 降级：使用预览图
          gpuSourceForSave = _gpuPreviewPath ?? widget.imagePath;
        }
      }

      final transformedBytes = await _applyTransforms(sourcePath: gpuSourceForSave);
      // 清理保存用的 GPU 临时文件
      if (gpuSourceForSave != widget.imagePath && gpuSourceForSave != _gpuPreviewPath) {
        try { File(gpuSourceForSave).deleteSync(); } catch (_) {}
      }

      if (transformedBytes == null) {
        _showSnack(sOf(ref.read(languageProvider)).imageProcessFailed);
        setState(() => _isSaving = false);
        return;
      }
      // 临时文件使用 .jpg 扩展名
      final tmpPath = '${Directory.systemTemp.path}/dazz_edit_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(tmpPath).writeAsBytes(transformedBytes);
      final pipeline = CapturePipeline(camera: camera);
      const maxDim = CapturePipeline.kMaxDimHigh;
      const jpegQ = CapturePipeline.kJpegQualityHigh;
      // pipeline.process 中跳过色彩处理（useGpu=false + renderParams=null），
      // 仅做水印合成（相框已取消）
      final result = await pipeline.process(
        imagePath: tmpPath,
        useGpu: false,        // 跳过 GPU 色彩处理
        renderParams: null,   // 跳过 Dart 降级色彩处理（色彩已由 GPU 完成）
        selectedRatioId: st.activeRatioId ?? '',
        selectedFrameId: '',  // 编辑页不使用相框
        selectedWatermarkId: st.activeWatermarkId ?? '',
        frameBackgroundColor: st.frameBackgroundColor,
        watermarkColorOverride: st.watermarkColor,
        watermarkPositionOverride: st.watermarkPosition,
        watermarkSizeOverride: st.watermarkSize,
        watermarkDirectionOverride: st.watermarkDirection,
        watermarkStyleOverride: st.watermarkStyle,
        maxDimension: maxDim,
        jpegQuality: jpegQ,
      );
      final finalBytes = result?.bytes ?? transformedBytes;
      await File(tmpPath).writeAsBytes(finalBytes);
      final perm = await PhotoManager.requestPermissionExtend();
      if (!perm.hasAccess) {
        _showSnack(sOf(ref.read(languageProvider)).needGalleryPermission);
        setState(() => _isSaving = false);
        return;
      }
      final saved = await PhotoManager.editor.saveImageWithPath(
        tmpPath,
        title: 'DAZZ_${DateTime.now().millisecondsSinceEpoch}',
      );
      try { await File(tmpPath).delete(); } catch (_) {}
      if (saved != null && mounted) {
        HapticFeedback.mediumImpact();
        _showSnack(sOf(ref.read(languageProvider)).savedToGallery);
        await Future.delayed(const Duration(milliseconds: 800));
        if (mounted) Navigator.of(context).pop();
      } else {
        _showSnack(sOf(ref.read(languageProvider)).saveFailed);
      }
    } catch (e) {
      debugPrint('[ImageEditScreen] save error: $e');
      _showSnack(sOf(ref.read(languageProvider)).saveError);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// 应用裁剪/旋转/翻转变换
  /// 使用 image_lib 在后台 isolate 中处理，避免 rawRgba 大内存导致 OOM 崩溃
  Future<Uint8List?> _applyTransforms({String? sourcePath}) async {
    try {
      final path = sourcePath ?? _gpuPreviewPath ?? _previewSourcePath;
      final bytes = await File(path).readAsBytes();

      // 捕获当前变换参数（不能在 isolate 中访问 'this'）
      final cropRect = _cropRect;
      final totalRotation = _totalRotation;
      final flipH = _flipH;

      // 在独立 isolate 中执行 CPU 密集的图像处理，避免主线程 OOM
      final result = await Isolate.run(() {
        final decoded = image_lib.decodeImage(bytes);
        if (decoded == null) return null;

        final srcW = decoded.width.toDouble();
        final srcH = decoded.height.toDouble();
        final cropX = (cropRect.left * srcW).round();
        final cropY = (cropRect.top * srcH).round();
        final cropW = (cropRect.width * srcW).round();
        final cropH = (cropRect.height * srcH).round();

        if (cropW <= 0 || cropH <= 0) return null;

        // 裁剪
        image_lib.Image current = image_lib.copyCrop(
          decoded,
          x: cropX, y: cropY, width: cropW, height: cropH,
        );

        // 翻转
        if (flipH) {
          current = image_lib.flipHorizontal(current);
        }

        // 旋转（image_lib 使用度数）
        if (totalRotation.abs() > 0.1) {
          current = image_lib.copyRotate(current, angle: totalRotation);
        }

        return image_lib.encodeJpg(current, quality: 95);
      });

      return result;
    } catch (e) {
      debugPrint('[ImageEditScreen] _applyTransforms error: $e');
      return null;
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final st = ref.watch(cameraAppProvider);
    final camera = st.camera;

    // 监听相机/滤镜/参数变化，实时刷新 GPU 预览
    ref.listen<CameraAppState>(cameraAppProvider, (prev, next) {
      // renderParams 变化时重新生成 GPU 预览（切换相机、滤镜、镜头、曝光、白平衡等）
      if (prev?.renderParams?.toJson().toString() != next.renderParams?.toJson().toString()) {
        _refreshGpuPreview();
      }
    });

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // ── 顶部导航栏 ──────────────────────────────────────────────────
            _buildTopBar(),
            // ── 图片预览区（含白平衡/曝光控件）────────────────────────────────
            Expanded(
              child: _buildPreviewArea(st, camera),
            ),
            // ── 旋转刻度尺 ──────────────────────────────────────────────────
            _buildRotationRuler(),
            // ── 相机菜单（常驻底部，含镜头选择）────────────────────────────────
            _buildInlineCameraMenu(st),
            // ── 上滑子面板 ──────────────────────────────────────────────────
            if (_activePanel != null && camera != null)
              _buildSubPanel(st, camera),
          ],
        ),
      ),
    );
  }

  // ── 顶部导航栏 ────────────────────────────────────────────────────────────
  Widget _buildTopBar() {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white12,
              ),
              child: const Icon(Icons.close, color: Colors.white, size: 20),
            ),
          ),
          const Spacer(),
          Text(
            sOf(ref.watch(languageProvider)).edit,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: _isSaving ? null : _save,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: _isSaving ? Colors.white24 : const Color(0xFFFF8C00),
                borderRadius: BorderRadius.circular(20),
              ),
              child: _isSaving
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                    )
                  : Text(
                      sOf(ref.watch(languageProvider)).save,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 图片预览区（含白平衡/曝光胶囊控件）──────────────────────────────────────
  Widget _buildPreviewArea(CameraAppState st, CameraDefinition? camera) {
    if (_isLoading) {
      // 带 App Icon 的加载过渡动画（同拍摄界面）
      return Center(
        child: AnimatedScale(
          scale: 1.0,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutBack,
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(120),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: Image.asset(
                'assets/images/app_icon.png',
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Center(
                  child: Icon(Icons.camera_alt, color: Colors.white, size: 48),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Stack(
      children: [
        // 图片预览（可缩放/拖动）
        GestureDetector(
          // 双击重置缩放
          onDoubleTap: () => setState(() {
            _previewScale = 1.0;
            _previewOffset = Offset.zero;
          }),
          // 捕合缩放
          onScaleStart: (d) {
            _scaleStart = _previewScale;
            _panStart = d.focalPoint - _previewOffset;
          },
          onScaleUpdate: (d) {
            setState(() {
              // 缩放：1.0 ~ 5.0
              _previewScale = (_scaleStart * d.scale).clamp(1.0, 5.0);
              // 拖动（只在缩放 > 1 时允许拖动）
              if (_previewScale > 1.0) {
                _previewOffset = d.focalPoint - _panStart;
              } else {
                _previewOffset = Offset.zero;
              }
            });
          },
          child: Center(
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..translate(_previewOffset.dx, _previewOffset.dy)
                ..scale(_previewScale),
              child: AspectRatio(
                aspectRatio: st.previewAspectRatio,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipRect(
                          child: _buildTransformedImage(st, constraints),
                        ),
                        // 相框预览已取消（用户要求）
                        if (st.activeWatermark != null && !st.activeWatermark!.isNone)
                          IgnorePointer(
                            child: _WatermarkPreviewOverlay(
                              watermark: st.activeWatermark!,
                              colorOverride: st.watermarkColor,
                              positionOverride: st.watermarkPosition,
                              sizeOverride: st.watermarkSize,
                              directionOverride: st.watermarkDirection,
                              styleId: st.watermarkStyle,
                            ),
                          ),
                        if (_isCropMode)
                          _CropOverlay(
                            cropRect: _cropRect,
                            onCropChanged: (rect) => setState(() => _cropRect = rect),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        // ── 白平衡+曝光胶囊控件（预览区底部，同取景框位置）──
        Positioned(
          left: 0,
          right: 0,
          bottom: _showExposureSlider || _showWbPanel ? 64 : 12,
          child: Center(child: _buildEditControlCapsule(st)),
        ),
        // ── 曝光滑动条（胶囊上方展开）──
        if (_showExposureSlider)
          Positioned(
            left: 0,
            right: 0,
            bottom: 12,
            height: 52,
            child: Center(
              child: _ExposureHorizontalSlider(
                value: st.exposureValue,
                onChanged: (v) =>
                    ref.read(cameraAppProvider.notifier).setExposure(v),
                onReset: () =>
                    ref.read(cameraAppProvider.notifier).setExposure(0),
              ),
            ),
          ),
        // ── 白平衡面板（胶囊上方展开）──
        if (_showWbPanel && !_showExposureSlider)
          Positioned(
            left: 0,
            right: 0,
            bottom: 12,
            height: 52,
            child: Center(
              child: _WbControlPanel(
                colorTempK: st.colorTempK,
                wbMode: st.wbMode,
                onTempChanged: (k) =>
                    ref.read(cameraAppProvider.notifier).setColorTempK(k),
                onPreset: (mode) {
                  ref.read(cameraAppProvider.notifier).setWhiteBalance(mode);
                },
              ),
            ),
          ),
      ],
    );
  }

  /// 编辑页的白平衡+曝光胶囊控件（同拍摄界面风格，无缩放按钮）
  Widget _buildEditControlCapsule(CameraAppState st) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 色温按钮（圆形，点击弹出色温面板）
        GestureDetector(
          onTap: () {
            setState(() {
              _showWbPanel = !_showWbPanel;
              if (_showWbPanel) _showExposureSlider = false; // 互斥
            });
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (_showWbPanel || st.wbMode != 'auto')
                  ? Colors.white.withAlpha(230)
                  : Colors.black.withAlpha(160),
            ),
            child: Center(
              child: Icon(
                _showWbPanel ? Icons.keyboard_arrow_down : Icons.thermostat_outlined,
                size: 16,
                color: (_showWbPanel || st.wbMode != 'auto') ? Colors.black : Colors.white,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        // 曝光按钮（胶囊形，点击展开水平滑动条）
        GestureDetector(
          onTap: () {
            setState(() {
              _showExposureSlider = !_showExposureSlider;
              if (_showExposureSlider) _showWbPanel = false; // 与色温面板互斥
            });
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: (_showExposureSlider || st.exposureValue != 0)
                  ? Colors.white.withAlpha(230)
                  : Colors.black.withAlpha(160),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _showExposureSlider ? Icons.keyboard_arrow_down : Icons.wb_sunny_outlined,
                  size: 14,
                  color: (_showExposureSlider || st.exposureValue != 0) ? Colors.black : Colors.white,
                ),
                const SizedBox(width: 5),
                Text(
                  st.exposureValue == 0
                      ? '0.0'
                      : (st.exposureValue > 0 ? '+' : '') +
                          st.exposureValue.toStringAsFixed(1),
                  style: TextStyle(
                    color: (_showExposureSlider || st.exposureValue != 0) ? Colors.black : Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTransformedImage(CameraAppState st, BoxConstraints constraints) {
    // 显示 GPU Shader 处理后的预览图（带滤镜效果），降级时显示缩小后的预览源
    final previewFile = _gpuPreviewPath != null
        ? File(_gpuPreviewPath!)
        : File(_previewSourcePath);
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..rotateZ(_totalRotation * math.pi / 180.0)
        ..scale(_flipH ? -1.0 : 1.0, 1.0),
      child: Image.file(
        previewFile,
        fit: BoxFit.cover,
        width: constraints.maxWidth,
        height: constraints.maxHeight,
        // 当 GPU 预览更新时强制刷新（避免 Flutter 缓存旧图片）
        key: ValueKey(_gpuPreviewPath ?? _previewSourcePath),
      ),
    );
  }

  // ── 旋转刻度尺 ────────────────────────────────────────────────────────────
  Widget _buildRotationRuler() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 角度数值 + 重置 + 旋转按钮
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                // 翻转按钮
                _RulerIconBtn(
                  icon: Icons.flip_outlined,
                  onTap: _flipHorizontal,
                ),
                const SizedBox(width: 8),
                // 旋转90度按钮
                _RulerIconBtn(
                  icon: Icons.rotate_90_degrees_ccw_outlined,
                  onTap: _rotate90,
                ),
                const Spacer(),
                // 角度数值
                GestureDetector(
                  onTap: _resetRotation,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: _fineRotation.abs() > 0.1
                          ? const Color(0xFFFF8C00).withOpacity(0.2)
                          : Colors.white10,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${_fineRotation >= 0 ? '+' : ''}${_fineRotation.toStringAsFixed(1)}°',
                      style: TextStyle(
                        color: _fineRotation.abs() > 0.1
                            ? const Color(0xFFFF8C00)
                            : Colors.white54,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                // 裁剪模式按钮
                _RulerIconBtn(
                  icon: _isCropMode ? Icons.check_circle_outline : Icons.crop_outlined,
                  isActive: _isCropMode,
                  onTap: () => setState(() => _isCropMode = !_isCropMode),
                ),
                const SizedBox(width: 8),
                // 重置裁剪
                _RulerIconBtn(
                  icon: Icons.restart_alt_outlined,
                  onTap: () => setState(() {
                    _cropRect = const Rect.fromLTWH(0, 0, 1, 1);
                    _isCropMode = false;
                    _fineRotation = 0.0;
                  }),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // 刻度尺
          SizedBox(
            height: 40,
            child: _RotationRuler(
              value: _fineRotation,
              onChanged: (v) => setState(() => _fineRotation = v),
            ),
          ),
        ],
      ),
    );
  }

  // ── 常驻底部相机菜单（含镜头选择）────────────────────────────────────────
  Widget _buildInlineCameraMenu(CameraAppState st) {
    return const CameraConfigInlinePanel(showLens: true);
  }

  // ── 上滑子面板 ────────────────────────────────────────────────────────────
  Widget _buildSubPanel(CameraAppState st, CameraDefinition camera) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      color: const Color(0xFF1A1A1A),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 面板标题 + 关闭按钮
          Row(
            children: [
              Text(
                _activePanel == 'filter' ? sOf(ref.read(languageProvider)).filter
                    : _activePanel == 'frame' ? sOf(ref.read(languageProvider)).frame
                    : sOf(ref.read(languageProvider)).watermark,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => setState(() => _activePanel = null),
                child: const Icon(Icons.keyboard_arrow_down, color: Colors.white54, size: 22),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 面板内容
          switch (_activePanel) {
            'filter' => _FilterRow(
                filters: camera.modules.filters,
                activeId: st.activeFilterId,
                onSelect: (id) => ref.read(cameraAppProvider.notifier).selectFilter(id),
              ),
            'frame' => _FrameRow(
                frames: camera.modules.frames,
                activeId: st.activeFrameId,
                onSelect: (id) => ref.read(cameraAppProvider.notifier).selectFrame(id),
              ),
            'watermark' => _WatermarkRow(
                presets: camera.modules.watermarks.presets,
                activeId: st.activeWatermarkId,
                onSelect: (id) => ref.read(cameraAppProvider.notifier).selectWatermark(id),
              ),
            _ => const SizedBox.shrink(),
          },
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 曝光水平滑动条（复用拍摄页风格）
// ─────────────────────────────────────────────────────────────────────────────
class _ExposureHorizontalSlider extends StatelessWidget {
  final double value; // -2.0 .. 2.0
  final ValueChanged<double> onChanged;
  final VoidCallback onReset;

  const _ExposureHorizontalSlider({
    required this.value,
    required this.onChanged,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          // 重置按钮
          GestureDetector(
            onTap: onReset,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withAlpha(180),
                border: Border.all(color: Colors.white.withAlpha(60), width: 1),
              ),
              child: const Center(
                child: Icon(Icons.refresh, color: Colors.white, size: 20),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 水平滑动轨道
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white.withAlpha(80),
                thumbColor: Colors.white,
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 10,
                  elevation: 0,
                ),
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Slider(
                value: value.clamp(-2.0, 2.0),
                min: -2.0,
                max: 2.0,
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 白平衡控制面板（复用拍摄页风格）
// ─────────────────────────────────────────────────────────────────────────────
class _WbControlPanel extends StatelessWidget {
  final int colorTempK;
  final String wbMode;
  final ValueChanged<int> onTempChanged;
  final ValueChanged<String> onPreset;

  const _WbControlPanel({
    required this.colorTempK,
    required this.wbMode,
    required this.onTempChanged,
    required this.onPreset,
  });

  @override
  Widget build(BuildContext context) {
    final sliderVal = ((colorTempK - 1800) / (8000 - 1800)).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          // 渐变滑动条
          Expanded(
            flex: 3,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  height: 30,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    gradient: const LinearGradient(
                          colors: [
                            Color(0xFFE8A05A), // 暖橙（左=1800K最暖）
                            Color(0xFFB08AE0), // 中紫
                            Color(0xFF6B8FE8), // 冷蓝（右=8000K最冷）
                          ],
                        ),
                  ),
                ),
                Positioned.fill(
                  child: CustomPaint(painter: _WbTrackDotsPainter()),
                ),
                SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 0,
                    activeTrackColor: Colors.transparent,
                    inactiveTrackColor: Colors.transparent,
                    thumbColor: Colors.white,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 10,
                      elevation: 2,
                    ),
                    overlayShape: SliderComponentShape.noOverlay,
                  ),
                  child: Slider(
                    value: sliderVal,
                    min: 0.0,
                    max: 1.0,
                    onChanged: (v) {
                      final k = (1800 + v * (8000 - 1800)).round();
                      onTempChanged(k);
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // K 值标签
          SizedBox(
            width: 42,
            child: Text(
              '${colorTempK}K',
              style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 4),
          // 三个预设按钮
          _WbPresetBtn(label: 'A', isActive: wbMode == 'auto', onTap: () => onPreset('auto')),
          const SizedBox(width: 4),
          _WbPresetBtn(icon: Icons.wb_sunny_outlined, isActive: wbMode == 'daylight', onTap: () => onPreset('daylight')),
          const SizedBox(width: 4),
          _WbPresetBtn(icon: Icons.lightbulb_outline, isActive: wbMode == 'incandescent', onTap: () => onPreset('incandescent')),
        ],
      ),
    );
  }
}

class _WbPresetBtn extends StatelessWidget {
  final String? label;
  final IconData? icon;
  final bool isActive;
  final VoidCallback onTap;
  const _WbPresetBtn({this.label, this.icon, required this.isActive, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isActive ? Colors.white : const Color(0xFF3A3A3C),
        ),
        child: Center(
          child: label != null
              ? Text(
                  label!,
                  style: TextStyle(
                    color: isActive ? const Color(0xFFE8A05A) : Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                )
              : Icon(
                  icon,
                  color: isActive ? const Color(0xFF1C1C1E) : Colors.white.withAlpha(180),
                  size: 16,
                ),
        ),
      ),
    );
  }
}

class _WbTrackDotsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withAlpha(80)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.fill;
    const dotR = 1.5;
    const spacing = 10.0;
    final cy = size.height / 2;
    var x = spacing;
    while (x < size.width - spacing) {
      canvas.drawCircle(Offset(x, cy), dotR, paint);
      x += spacing;
    }
  }
  @override
  bool shouldRepaint(_WbTrackDotsPainter old) => false;
}

// ─────────────────────────────────────────────────────────────────────────────
// 旋转刻度尺 Widget
// ─────────────────────────────────────────────────────────────────────────────
class _RotationRuler extends StatefulWidget {
  final double value;       // -45 ~ 45
  final ValueChanged<double> onChanged;
  const _RotationRuler({required this.value, required this.onChanged});
  @override
  State<_RotationRuler> createState() => _RotationRulerState();
}

class _RotationRulerState extends State<_RotationRuler> {
  double _dragStartX = 0;
  double _dragStartValue = 0;
  static const double _pixelsPerDegree = 6.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragStart: (d) {
        _dragStartX = d.localPosition.dx;
        _dragStartValue = widget.value;
      },
      onHorizontalDragUpdate: (d) {
        final delta = (d.localPosition.dx - _dragStartX) / _pixelsPerDegree;
        final newVal = (_dragStartValue - delta).clamp(-45.0, 45.0);
        widget.onChanged(newVal);
      },
      child: CustomPaint(
        painter: _RulerPainter(value: widget.value),
        size: const Size(double.infinity, 40),
      ),
    );
  }
}

class _RulerPainter extends CustomPainter {
  final double value;
  _RulerPainter({required this.value});

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final cy = size.height / 2;
    const pixelsPerDegree = 6.0;

    // 绘制刻度线
    for (int deg = -45; deg <= 45; deg++) {
      final x = centerX + (deg - value) * pixelsPerDegree;
      if (x < 0 || x > size.width) continue;

      final isMajor = deg % 5 == 0;
      final isZero = deg == 0;
      final tickH = isZero ? 20.0 : isMajor ? 14.0 : 8.0;
      final color = isZero
          ? const Color(0xFFFF8C00)
          : isMajor
              ? Colors.white54
              : Colors.white24;

      canvas.drawLine(
        Offset(x, cy - tickH / 2),
        Offset(x, cy + tickH / 2),
        Paint()
          ..color = color
          ..strokeWidth = isZero ? 2.0 : 1.0
          ..strokeCap = StrokeCap.round,
      );

      // 主刻度数字
      if (isMajor && deg != 0) {
        final tp = TextPainter(
          text: TextSpan(
            text: '${deg.abs()}',
            style: TextStyle(
              color: Colors.white24,
              fontSize: 8,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x - tp.width / 2, cy + tickH / 2 + 2));
      }
    }

    // 中心指示器（三角形）
    final path = Path()
      ..moveTo(centerX - 5, 0)
      ..lineTo(centerX + 5, 0)
      ..lineTo(centerX, 7)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFFFF8C00));
  }

  @override
  bool shouldRepaint(_RulerPainter old) => old.value != value;
}

// ─────────────────────────────────────────────────────────────────────────────
// 小组件
// ─────────────────────────────────────────────────────────────────────────────
class _RulerIconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool isActive;
  const _RulerIconBtn({required this.icon, required this.onTap, this.isActive = false});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isActive ? const Color(0xFFFF8C00).withOpacity(0.2) : Colors.white10,
        ),
        child: Icon(
          icon,
          color: isActive ? const Color(0xFFFF8C00) : Colors.white54,
          size: 18,
        ),
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  final String label;
  const _TagChip({required this.label});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFFF8C00).withOpacity(0.2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFF8C00).withOpacity(0.5)),
      ),
      child: Text(
        label,
        style: const TextStyle(color: Color(0xFFFF8C00), fontSize: 10),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 滤镜行（复用拍摄页逻辑）
// ─────────────────────────────────────────────────────────────────────────────
class _FilterRow extends StatelessWidget {
  final List<FilterDefinition> filters;
  final String? activeId;
  final ValueChanged<String> onSelect;
  const _FilterRow({required this.filters, this.activeId, required this.onSelect});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 80,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: filters.length,
        itemBuilder: (ctx, i) {
          final f = filters[i];
          final isActive = f.id == activeId;
          return GestureDetector(
            onTap: () => onSelect(f.id),
            child: Container(
              width: 64,
              margin: const EdgeInsets.only(right: 10),
              child: Column(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2A2A),
                      borderRadius: BorderRadius.circular(10),
                      border: isActive
                          ? Border.all(color: const Color(0xFFFF8C00), width: 2)
                          : Border.all(color: Colors.white12),
                    ),
                    child: Icon(
                      Icons.filter_vintage_outlined,
                      color: isActive ? const Color(0xFFFF8C00) : Colors.white38,
                      size: 24,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    f.nameEn,
                    style: TextStyle(
                      color: isActive ? const Color(0xFFFF8C00) : Colors.white38,
                      fontSize: 10,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 边框行（横向滚动，复用拍摄页逻辑）
// ─────────────────────────────────────────────────────────────────────────────
class _FrameRow extends ConsumerWidget {
  final List<FrameDefinition> frames;
  final String? activeId;
  final ValueChanged<String> onSelect;
  const _FrameRow({required this.frames, this.activeId, required this.onSelect});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = sOf(ref.watch(languageProvider));
    final allFrames = [
      _FrameOpt(id: 'none', name: s.none, color: Colors.transparent),
      ...frames.map((f) {
        Color c = const Color(0xFFF5F2EA);
        try {
          final hex = f.backgroundColor.replaceAll('#', '');
          c = Color(int.parse('FF$hex', radix: 16));
        } catch (_) {}
        return _FrameOpt(id: f.id, name: f.nameEn, color: c);
      }),
    ];
    return SizedBox(
      height: 80,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: allFrames.length,
        itemBuilder: (ctx, i) {
          final opt = allFrames[i];
          final isActive = opt.id == (activeId ?? 'none');
          return GestureDetector(
            onTap: () => onSelect(opt.id),
            child: Container(
              width: 64,
              margin: const EdgeInsets.only(right: 10),
              child: Column(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: opt.color == Colors.transparent
                          ? const Color(0xFF2A2A2A)
                          : opt.color,
                      border: isActive
                          ? Border.all(color: const Color(0xFFFF8C00), width: 2.5)
                          : Border.all(color: Colors.white12),
                    ),
                    child: opt.color == Colors.transparent
                        ? const Icon(Icons.block, color: Colors.white38, size: 20)
                        : isActive
                            ? const Icon(Icons.check, color: Color(0xFFFF8C00), size: 20)
                            : null,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    opt.name,
                    style: TextStyle(
                      color: isActive ? const Color(0xFFFF8C00) : Colors.white38,
                      fontSize: 10,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _FrameOpt {
  final String id;
  final String name;
  final Color color;
  const _FrameOpt({required this.id, required this.name, required this.color});
}

// ─────────────────────────────────────────────────────────────────────────────
// 水印行（复用拍摄页逻辑）
// ─────────────────────────────────────────────────────────────────────────────
class _WatermarkRow extends StatelessWidget {
  final List<WatermarkPreset> presets;
  final String? activeId;
  final ValueChanged<String> onSelect;
  const _WatermarkRow({required this.presets, this.activeId, required this.onSelect});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 80,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: presets.length,
        itemBuilder: (ctx, i) {
          final wm = presets[i];
          final isActive = wm.id == activeId;
          Color dotColor = const Color(0xFFFF8C00);
          if (wm.color != null && wm.color!.isNotEmpty) {
            try {
              final hex = wm.color!.replaceAll('#', '');
              dotColor = Color(int.parse('FF$hex', radix: 16));
            } catch (_) {}
          }
          return GestureDetector(
            onTap: () => onSelect(wm.id),
            child: Container(
              width: 64,
              margin: const EdgeInsets.only(right: 10),
              child: Column(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2A2A),
                      borderRadius: BorderRadius.circular(10),
                      border: isActive
                          ? Border.all(color: const Color(0xFFFF8C00), width: 2)
                          : Border.all(color: Colors.white12),
                    ),
                    child: Center(
                      child: wm.isNone
                          ? const Icon(Icons.block, color: Colors.white38, size: 20)
                          : Container(
                              width: 18,
                              height: 18,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: dotColor,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    wm.name,
                    style: TextStyle(
                      color: isActive ? const Color(0xFFFF8C00) : Colors.white38,
                      fontSize: 10,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 裁剪框 Overlay（保持不变）
// ─────────────────────────────────────────────────────────────────────────────
class _CropOverlay extends StatefulWidget {
  final Rect cropRect;
  final ValueChanged<Rect> onCropChanged;
  const _CropOverlay({required this.cropRect, required this.onCropChanged});
  @override
  State<_CropOverlay> createState() => _CropOverlayState();
}

class _CropOverlayState extends State<_CropOverlay> {
  _CropHandle? _activeHandle;
  Offset? _dragStart;
  Rect? _rectAtDragStart;

  static const double _hitSlop = 24.0;
  static const double minSize = 0.1;

  _CropHandle? _hitTest(Offset pos, Size size) {
    final r = Rect.fromLTWH(
      widget.cropRect.left * size.width,
      widget.cropRect.top * size.height,
      widget.cropRect.width * size.width,
      widget.cropRect.height * size.height,
    );
    if ((pos - r.topLeft).distance < _hitSlop) return _CropHandle.topLeft;
    if ((pos - r.topRight).distance < _hitSlop) return _CropHandle.topRight;
    if ((pos - r.bottomLeft).distance < _hitSlop) return _CropHandle.bottomLeft;
    if ((pos - r.bottomRight).distance < _hitSlop) return _CropHandle.bottomRight;
    if (r.contains(pos)) return _CropHandle.move;
    return null;
  }

  void _onPanStart(DragStartDetails d, Size size) {
    _activeHandle = _hitTest(d.localPosition, size);
    if (_activeHandle != null) {
      _dragStart = d.localPosition;
      _rectAtDragStart = widget.cropRect;
    }
  }

  void _onPanUpdate(DragUpdateDetails d, Size size) {
    if (_activeHandle == null || _dragStart == null || _rectAtDragStart == null) return;
    final dx = d.localPosition.dx / size.width - _dragStart!.dx / size.width;
    final dy = d.localPosition.dy / size.height - _dragStart!.dy / size.height;
    final r = _rectAtDragStart!;
    Rect newRect;
    switch (_activeHandle!) {
      case _CropHandle.topLeft:
        newRect = Rect.fromLTRB(
          (r.left + dx).clamp(0.0, r.right - minSize),
          (r.top + dy).clamp(0.0, r.bottom - minSize),
          r.right, r.bottom,
        );
        break;
      case _CropHandle.topRight:
        newRect = Rect.fromLTRB(
          r.left,
          (r.top + dy).clamp(0.0, r.bottom - minSize),
          (r.right + dx).clamp(r.left + minSize, 1.0),
          r.bottom,
        );
        break;
      case _CropHandle.bottomLeft:
        newRect = Rect.fromLTRB(
          (r.left + dx).clamp(0.0, r.right - minSize),
          r.top, r.right,
          (r.bottom + dy).clamp(r.top + minSize, 1.0),
        );
        break;
      case _CropHandle.bottomRight:
        newRect = Rect.fromLTRB(
          r.left, r.top,
          (r.right + dx).clamp(r.left + minSize, 1.0),
          (r.bottom + dy).clamp(r.top + minSize, 1.0),
        );
        break;
      case _CropHandle.move:
        final newL = (r.left + dx).clamp(0.0, 1.0 - r.width);
        final newT = (r.top + dy).clamp(0.0, 1.0 - r.height);
        newRect = Rect.fromLTWH(newL, newT, r.width, r.height);
        break;
    }
    setState(() => _rectAtDragStart = newRect);
    widget.onCropChanged(newRect);
  }

  void _onPanEnd(DragEndDetails d) {
    _activeHandle = null;
    _dragStart = null;
    _rectAtDragStart = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          onPanStart: (d) => _onPanStart(d, size),
          onPanUpdate: (d) => _onPanUpdate(d, size),
          onPanEnd: _onPanEnd,
          child: CustomPaint(
            size: size,
            painter: _CropPainter(rect: widget.cropRect),
          ),
        );
      },
    );
  }
}

class _CropPainter extends CustomPainter {
  final Rect rect;
  _CropPainter({required this.rect});
  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTWH(
      rect.left * size.width,
      rect.top * size.height,
      rect.width * size.width,
      rect.height * size.height,
    );
    final dimPaint = Paint()..color = Colors.black.withAlpha(130);
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRect(r)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, dimPaint);
    canvas.drawRect(
      r,
      Paint()
        ..color = Colors.white
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
    final gridPaint = Paint()
      ..color = Colors.white38
      ..strokeWidth = 0.5;
    for (int i = 1; i < 3; i++) {
      final x = r.left + r.width * i / 3;
      final y = r.top + r.height * i / 3;
      canvas.drawLine(Offset(x, r.top), Offset(x, r.bottom), gridPaint);
      canvas.drawLine(Offset(r.left, y), Offset(r.right, y), gridPaint);
    }
    final hp = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    const hl = 16.0;
    canvas.drawLine(r.topLeft, r.topLeft + const Offset(hl, 0), hp);
    canvas.drawLine(r.topLeft, r.topLeft + const Offset(0, hl), hp);
    canvas.drawLine(r.topRight, r.topRight + const Offset(-hl, 0), hp);
    canvas.drawLine(r.topRight, r.topRight + const Offset(0, hl), hp);
    canvas.drawLine(r.bottomLeft, r.bottomLeft + const Offset(hl, 0), hp);
    canvas.drawLine(r.bottomLeft, r.bottomLeft + const Offset(0, -hl), hp);
    canvas.drawLine(r.bottomRight, r.bottomRight + const Offset(-hl, 0), hp);
    canvas.drawLine(r.bottomRight, r.bottomRight + const Offset(0, -hl), hp);
  }
  @override
  bool shouldRepaint(_CropPainter old) => old.rect != rect;
}

enum _CropHandle { topLeft, topRight, bottomLeft, bottomRight, move }

// ─────────────────────────────────────────────────────────────────────────────
// 水印预览 Overlay（复用拍摄页）
// ─────────────────────────────────────────────────────────────────────────────
class _WatermarkPreviewOverlay extends StatelessWidget {
  final WatermarkPreset watermark;
  final String? colorOverride;
  final String? positionOverride;
  final String? sizeOverride; // 'small'|'medium'|'large'
  final String? directionOverride;
  final String? styleId;
  const _WatermarkPreviewOverlay({
    required this.watermark,
    this.colorOverride,
    this.positionOverride,
    this.sizeOverride,
    this.directionOverride,
    this.styleId,
  });
  @override
  Widget build(BuildContext context) {
    if (watermark.isNone) return const SizedBox.shrink();
    final colorSrc = colorOverride ?? watermark.color;
    Color textColor = const Color(0xFFFF8C00);
    if (colorSrc != null && colorSrc.isNotEmpty) {
      try {
        final hex = colorSrc.replaceAll('#', '');
        textColor = Color(int.parse('FF$hex', radix: 16));
      } catch (_) {}
    }
    final position = positionOverride ?? watermark.position ?? 'bottom_right';
    Alignment align;
    switch (position) {
      case 'bottom_left': align = Alignment.bottomLeft; break;
      case 'bottom_center': align = Alignment.bottomCenter; break;
      case 'top_right': align = Alignment.topRight; break;
      case 'top_left': align = Alignment.topLeft; break;
      default: align = Alignment.bottomRight;
    }
    final fontSize = 12.0;
    return Align(
      alignment: align,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          watermark.name,
          style: TextStyle(
            color: textColor,
            fontSize: fontSize,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
