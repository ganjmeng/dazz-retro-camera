// image_edit_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// 设计哲学：Darkroom Aesthetics — 纯黑背景，白色控件，复用相机页所有效果逻辑
// 底部工具按钮显示/隐藏由当前相机 uiCap 决定，完全复用拍摄页逻辑
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../models/camera_definition.dart';
import '../../models/camera_registry.dart';
import '../camera/camera_notifier.dart';
import '../camera/camera_config_sheet.dart';
import '../camera/capture_pipeline.dart';
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

  // 跳转到编辑页前移除遮罩（页面内有自己的通用加载动画）
  // 注意：必须在 push 之前移除，否则 Overlay 会一直覆盖在编辑页上方
  loadingOverlay.remove();
  loadingOverlay = null;

  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (ctx) => UncontrolledProviderScope(
        container: ProviderScope.containerOf(context),
        child: ImageEditScreen(imagePath: file.path),
      ),
      fullscreenDialog: true,
    ),
  );
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
  final String? initialCameraId;
  const ImageEditScreen({
    super.key,
    required this.imagePath,
    this.initialCameraId,
  });
  @override
  ConsumerState<ImageEditScreen> createState() => _ImageEditScreenState();
}

class _ImageEditScreenState extends ConsumerState<ImageEditScreen> {
  // ── 编辑参数 ──────────────────────────────────────────────────────────────
  double _fineRotation = 0.0; // 精细旋转：-45 ~ 45 度（刻度尺控制）
  int _coarseRotation = 0; // 粗旋转：0/90/180/270（旋转按钮控制）
  bool _flipH = false;
  bool _isCropMode = false;
  Rect _cropRect = const Rect.fromLTWH(0, 0, 1, 1);

  // ── 预览手势（缩放/拖动）────────────────────────────────────────────────
  double _previewScale = 1.0; // 当前缩放倍率
  double _scaleStart = 1.0; // 捏合手势开始时的缩放倍率
  Offset _previewOffset = Offset.zero; // 当前平移偏移
  Offset _panStart = Offset.zero; // 拖动手势开始时的偏移

  // ── 面板状态 ──────────────────────────────────────────────────────────────
  String? _activePanel; // 'filter' | 'frame' | 'watermark' | null

  // ── 加载/保存 ─────────────────────────────────────────────────────────────
  bool _isLoading = true;
  bool _isSaving = false;

  // ── GPU 预览（已改为 Flutter 纯渲染，以下变量仅保留供 _save 使用）────────────
  static const MethodChannel _gpuChannel =
      MethodChannel('com.retrocam.app/camera_control');
  // 预览不再使用 GPU，以下变量仅供 _save 时保存高质量成片
  // String? _gpuPreviewPath;    // 已废弃：预览不再走 GPU
  // bool _gpuProcessing = false;
  // int _gpuRequestId = 0;
  // String? _lastGpuParamsSignature;

  // ── 高清图片缩小后的预览源路径（避免 OOM）──────────────────────────────────
  String? _resizedPreviewPath; // 缩小到 ≤4096px 的预览源
  static const int _kMaxPreviewDim = 4096;
  int _originalW = 0;
  int _originalH = 0;

  // ── 白平衡/曝光控件状态 ──────────────────────────────────────────────────
  bool _showExposureSlider = false;
  bool _showWbPanel = false;

  double get _totalRotation => _coarseRotation.toDouble() + _fineRotation;

  @override
  void initState() {
    super.initState();
    unawaited(_applyInitialCamera());
    _initPreview();
  }

  Future<void> _applyInitialCamera() async {
    final requestedCameraId = (widget.initialCameraId ?? '').trim();
    if (requestedCameraId.isEmpty) return;
    if (!kAllCameras.any((camera) => camera.id == requestedCameraId)) return;
    final notifier = ref.read(cameraAppProvider.notifier);
    final currentCameraId = ref.read(cameraAppProvider).activeCameraId;
    if (currentCameraId == requestedCameraId) return;
    await notifier.switchToCamera(requestedCameraId);
  }

  /// 初始化预览：先缩小高清图片到安全尺寸（在 isolate 中执行，避免卡 UI）
  /// 预览已改为 Flutter 纯渲染（ColorFiltered），无需 GPU 预处理
  Future<void> _initPreview() async {
    try {
      // 1. 读取原图并检查尺寸
      final originalBytes = await File(widget.imagePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(originalBytes);
      final frame = await codec.getNextFrame();
      final srcW = frame.image.width;
      final srcH = frame.image.height;
      _originalW = srcW;
      _originalH = srcH;
      frame.image.dispose();

      // 2. 如果原图过大，在后台 isolate 中缩小（避免卡 UI / OOM）
      // 分级策略：超大图用更保守尺寸；中大图尽量保留更多像素，兼顾画质与稳定。
      final maxSrcDim = math.max(srcW, srcH);
      final previewMaxDim = maxSrcDim >= 12000
          ? 4096
          : maxSrcDim >= 8000
              ? 4608
              : _kMaxPreviewDim;
      if (srcW > previewMaxDim || srcH > previewMaxDim) {
        final scale = previewMaxDim / maxSrcDim;
        final newW = (srcW * scale).round();
        final newH = (srcH * scale).round();
        // 在独立 isolate 中执行 CPU 密集的解码+缩放，主线程保持响应
        final resizedJpg = await Isolate.run(() {
          final decoded = image_lib.decodeImage(originalBytes);
          if (decoded == null) return null;
          final resized = image_lib.copyResize(decoded,
              width: newW,
              height: newH,
              interpolation: image_lib.Interpolation.linear);
          return image_lib.encodeJpg(resized, quality: 92);
        });
        if (resizedJpg != null) {
          final tmpPath =
              '${Directory.systemTemp.path}/dazz_resized_${DateTime.now().millisecondsSinceEpoch}.jpg';
          await File(tmpPath).writeAsBytes(resizedJpg);
          _resizedPreviewPath = tmpPath;
          debugPrint(
              '[ImageEditScreen] Resized ${srcW}x$srcH → ${newW}x$newH for preview');
        }
      }

      if (!mounted) return;
      // 预览直接显示（Flutter ColorFiltered 渲染，无需等待 GPU）
      setState(() => _isLoading = false);
    } catch (e) {
      debugPrint('[ImageEditScreen] _initPreview error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// 预览使用的源路径（缩小后的 or 原图）
  String get _previewSourcePath => _resizedPreviewPath ?? widget.imagePath;

  // ── 以下 GPU 预览方法已废弃（预览改为 Flutter 纯渲染），仅保留注释供参考 ──────
  // Future<void> _waitForCameraAndRefresh() async { ... }
  // Future<void> _refreshGpuPreview() async { ... }

  @override
  void dispose() {
    // 清理缩小后的预览源临时文件
    if (_resizedPreviewPath != null) {
      try {
        File(_resizedPreviewPath!).deleteSync();
      } catch (_) {}
    }
    super.dispose();
  }

  void _rotate90() =>
      setState(() => _coarseRotation = (_coarseRotation + 90) % 360);
  void _flipHorizontal() => setState(() => _flipH = !_flipH);
  void _resetRotation() => setState(() => _fineRotation = 0.0);

  void _togglePanel(String panel) {
    setState(() => _activePanel = _activePanel == panel ? null : panel);
  }

  // ── 保存 ──────────────────────────────────────────────────────────────────
  Future<void> _save() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    String? gpuTmpPath;
    String? transformTmpPath;
    String? composeTmpPath;
    try {
      final st = ref.read(cameraAppProvider);
      final camera = st.camera;
      if (camera == null) {
        _showSnack(sOf(ref.read(languageProvider)).selectCameraFirst);
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
            // 关键：限制中间结果最大边长，避免 2 亿像素机型返回超大图导致后续 OOM
            'maxDimension': CapturePipeline.kMaxDimHigh,
            'jpegQuality': CapturePipeline.kJpegQualityHigh,
          });
          if (result != null && result['filePath'] != null) {
            gpuSourceForSave = result['filePath'] as String;
            if (gpuSourceForSave != widget.imagePath) {
              gpuTmpPath = gpuSourceForSave;
            }
          }
        } catch (e) {
          debugPrint(
              '[ImageEditScreen] GPU save processing failed, using original: $e');
          // 降级：使用原始高清图
          gpuSourceForSave = widget.imagePath;
        }
      }

      final hasUserTransform = _hasTransformEdits();
      final hasFrame = (st.activeFrameId ?? '').isNotEmpty &&
          st.activeFrameId != 'none' &&
          st.activeFrameId != 'frame_none';
      final hasWatermark = (st.activeWatermarkId ?? '').isNotEmpty &&
          st.activeWatermarkId != 'none';
      // 只要用户做了裁剪/旋转/翻转且存在缩小预览源，就优先用缩小源做变换。
      // 这样可避免对超大原图进行 Dart 端 decodeImage 引发内存峰值崩溃。
      // 仅在超大图时走安全缩小源，避免中等分辨率也被过度降质。
      final needSafeTransformSource = hasUserTransform &&
          _resizedPreviewPath != null &&
          math.max(_originalW, _originalH) >= 7000;
      final transformSourcePath =
          needSafeTransformSource ? _resizedPreviewPath! : gpuSourceForSave;
      if (needSafeTransformSource) {
        debugPrint(
            '[ImageEditScreen] large image safeguard: use resized source for transforms '
            '${_originalW}x$_originalH -> $_resizedPreviewPath');
      }

      final saveTitle = 'DAZZ_${DateTime.now().millisecondsSinceEpoch}';
      final perm = await PhotoManager.requestPermissionExtend();
      if (!perm.hasAccess) {
        _showSnack(sOf(ref.read(languageProvider)).needGalleryPermission);
        return;
      }

      String pathForCompose = gpuSourceForSave;

      if (hasUserTransform) {
        final transformedBytes =
            await _applyTransforms(sourcePath: transformSourcePath);
        if (transformedBytes == null) {
          _showSnack(sOf(ref.read(languageProvider)).imageProcessFailed);
          return;
        }
        transformTmpPath =
            '${Directory.systemTemp.path}/dazz_edit_${DateTime.now().millisecondsSinceEpoch}.jpg';
        await File(transformTmpPath).writeAsBytes(transformedBytes);
        pathForCompose = transformTmpPath;
      }

      String pathToSave = pathForCompose;
      // 无变换且无相框/水印：直接保存文件路径，避免大图 bytes 往返拷贝。
      if (hasUserTransform || hasFrame || hasWatermark) {
        final pipeline = CapturePipeline(camera: camera);
        const maxDim = CapturePipeline.kMaxDimHigh;
        const jpegQ = CapturePipeline.kJpegQualityHigh;
        final result = await pipeline.process(
          imagePath: pathForCompose,
          useGpu: false, // 跳过 GPU 色彩处理
          renderParams: null, // 跳过 Dart 降级色彩处理（色彩已由前置 GPU 完成）
          selectedRatioId: st.activeRatioId ?? '',
          selectedFrameId: st.activeFrameId ?? '',
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
        final finalBytes = result?.bytes;
        if (finalBytes == null) {
          _showSnack(sOf(ref.read(languageProvider)).imageProcessFailed);
          return;
        }
        composeTmpPath =
            '${Directory.systemTemp.path}/dazz_compose_${DateTime.now().millisecondsSinceEpoch}.jpg';
        await File(composeTmpPath).writeAsBytes(finalBytes);
        pathToSave = composeTmpPath;
      }

      await PhotoManager.editor.saveImageWithPath(
        pathToSave,
        title: saveTitle,
      );

      if (mounted) {
        HapticFeedback.mediumImpact();
        _showSnack(sOf(ref.read(languageProvider)).savedToGallery);
        await Future.delayed(const Duration(milliseconds: 800));
        if (mounted) Navigator.of(context).pop();
      }
    } catch (e) {
      debugPrint('[ImageEditScreen] save error: $e');
      _showSnack(sOf(ref.read(languageProvider)).saveError);
    } finally {
      if (transformTmpPath != null) {
        try {
          await File(transformTmpPath).delete();
        } catch (_) {}
      }
      if (composeTmpPath != null) {
        try {
          await File(composeTmpPath).delete();
        } catch (_) {}
      }
      if (gpuTmpPath != null) {
        try {
          File(gpuTmpPath).deleteSync();
        } catch (_) {}
      }
      if (mounted) setState(() => _isSaving = false);
    }
  }

  bool _hasTransformEdits() {
    final cropEdited = (_cropRect.left - 0.0).abs() > 0.0001 ||
        (_cropRect.top - 0.0).abs() > 0.0001 ||
        (_cropRect.width - 1.0).abs() > 0.0001 ||
        (_cropRect.height - 1.0).abs() > 0.0001;
    return _flipH || _totalRotation.abs() > 0.1 || cropEdited;
  }

  /// 应用裁剪/旋转/翻转变换
  /// 使用 image_lib 在后台 isolate 中处理，避免 rawRgba 大内存导致 OOM 崩溃
  Future<Uint8List?> _applyTransforms({String? sourcePath}) async {
    try {
      final path = sourcePath ?? _previewSourcePath;
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
          x: cropX,
          y: cropY,
          width: cropW,
          height: cropH,
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

    // 预览已改为 Flutter 纯渲染（ColorFiltered），无需监听参数变化触发 GPU
    // ref.watch(cameraAppProvider) 已经保证参数变化时自动重建 Widget

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
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2),
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

    // FIX: 相机切换时（isLoading=true）显示加载指示器，避免预览区空白或闪烁
    final isCameraLoading = st.isLoading;

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
                        // 相框预览：仅当相框功能开启、当前比例支持相框、且选中了非 none 相框时显示
                        if (camera != null &&
                            camera.isFrameEnabled(st.activeRatioId) &&
                            st.activeFrame != null &&
                            !st.activeFrame!.isNone)
                          IgnorePointer(
                            child: _FramePreviewOverlay(
                              frame: st.activeFrame!,
                              ratioId: st.activeRatioId ?? '',
                              backgroundColorOverride: st.frameBackgroundColor,
                            ),
                          ),
                        if (st.activeWatermark != null &&
                            !st.activeWatermark!.isNone)
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
                            onCropChanged: (rect) =>
                                setState(() => _cropRect = rect),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        // FIX: 相机切换加载时显示半透明转圈，告知用户正在处理
        if (isCameraLoading)
          Positioned.fill(
            child: Container(
              color: Colors.black.withAlpha(100),
              child: const Center(
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2.5,
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
                _showWbPanel
                    ? Icons.keyboard_arrow_down
                    : Icons.thermostat_outlined,
                size: 16,
                color: (_showWbPanel || st.wbMode != 'auto')
                    ? Colors.black
                    : Colors.white,
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
                  _showExposureSlider
                      ? Icons.keyboard_arrow_down
                      : Icons.wb_sunny_outlined,
                  size: 14,
                  color: (_showExposureSlider || st.exposureValue != 0)
                      ? Colors.black
                      : Colors.white,
                ),
                const SizedBox(width: 5),
                Text(
                  st.exposureValue == 0
                      ? '0.0'
                      : (st.exposureValue > 0 ? '+' : '') +
                          st.exposureValue.toStringAsFixed(1),
                  style: TextStyle(
                    color: (_showExposureSlider || st.exposureValue != 0)
                        ? Colors.black
                        : Colors.white,
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
    // Flutter 纯渲染预览：ColorFiltered + buildColorMatrix，不走原生 GPU 管线
    // 优先使用缩小后的预览源（避免高清图 OOM），无缩小版时使用原图
    final previewFile = File(_previewSourcePath);
    final renderParams = st.renderParams;
    Widget imageWidget = Image.file(
      previewFile,
      fit: BoxFit.cover,
      width: constraints.maxWidth,
      height: constraints.maxHeight,
      key: ValueKey(_previewSourcePath),
    );
    // 叠加颜色矩阵滤镜（与拍立得成片管线 Dart 降级路径保持一致）
    if (renderParams != null) {
      final colorMatrix = CapturePipeline.buildColorMatrix(renderParams);
      imageWidget = ColorFiltered(
        colorFilter: ColorFilter.matrix(colorMatrix),
        child: imageWidget,
      );
    }
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..rotateZ(_totalRotation * math.pi / 180.0)
        ..scale(_flipH ? -1.0 : 1.0, 1.0),
      child: imageWidget,
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
                  icon: _isCropMode
                      ? Icons.check_circle_outline
                      : Icons.crop_outlined,
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
                _activePanel == 'filter'
                    ? sOf(ref.read(languageProvider)).filter
                    : _activePanel == 'frame'
                        ? sOf(ref.read(languageProvider)).frame
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
                child: const Icon(Icons.keyboard_arrow_down,
                    color: Colors.white54, size: 22),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 面板内容
          switch (_activePanel) {
            'filter' => _FilterRow(
                filters: camera.modules.filters,
                activeId: st.activeFilterId,
                onSelect: (id) =>
                    ref.read(cameraAppProvider.notifier).selectFilter(id),
              ),
            'frame' => _FrameRow(
                frames: camera.modules.frames,
                activeId: st.activeFrameId,
                onSelect: (id) =>
                    ref.read(cameraAppProvider.notifier).selectFrame(id),
              ),
            'watermark' => _WatermarkRow(
                presets: camera.modules.watermarks.presets,
                activeId: st.activeWatermarkId,
                onSelect: (id) =>
                    ref.read(cameraAppProvider.notifier).selectWatermark(id),
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
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 4),
          // 三个预设按钮
          _WbPresetBtn(
              label: 'A',
              isActive: wbMode == 'auto',
              onTap: () => onPreset('auto')),
          const SizedBox(width: 4),
          _WbPresetBtn(
              icon: Icons.wb_sunny_outlined,
              isActive: wbMode == 'daylight',
              onTap: () => onPreset('daylight')),
          const SizedBox(width: 4),
          _WbPresetBtn(
              icon: Icons.lightbulb_outline,
              isActive: wbMode == 'incandescent',
              onTap: () => onPreset('incandescent')),
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
  const _WbPresetBtn(
      {this.label, this.icon, required this.isActive, required this.onTap});
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
                  color: isActive
                      ? const Color(0xFF1C1C1E)
                      : Colors.white.withAlpha(180),
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
  final double value; // -45 ~ 45
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
      final tickH = isZero
          ? 20.0
          : isMajor
              ? 14.0
              : 8.0;
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
  const _RulerIconBtn(
      {required this.icon, required this.onTap, this.isActive = false});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isActive
              ? const Color(0xFFFF8C00).withOpacity(0.2)
              : Colors.white10,
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
  const _FilterRow(
      {required this.filters, this.activeId, required this.onSelect});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 114,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: filters.length,
        itemBuilder: (ctx, i) {
          final f = filters[i];
          final isActive = f.id == activeId;
          const cardWidth = 120.0;
          const cardHeight = 80.0; // 800:533 ≈ 1.50
          return GestureDetector(
            onTap: () => onSelect(f.id),
            child: Container(
              width: cardWidth,
              margin: const EdgeInsets.only(right: 10),
              child: Column(
                children: [
                  Container(
                    width: cardWidth,
                    height: cardHeight,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2A2A),
                      borderRadius: BorderRadius.circular(10),
                      border: isActive
                          ? Border.all(color: const Color(0xFFFF8C00), width: 2)
                          : Border.all(color: Colors.white12),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: f.thumbnail != null && f.thumbnail!.isNotEmpty
                        ? Image.asset(
                            f.thumbnail!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Icon(
                              Icons.filter_vintage_outlined,
                              color: isActive
                                  ? const Color(0xFFFF8C00)
                                  : Colors.white38,
                              size: 28,
                            ),
                          )
                        : Icon(
                            Icons.filter_vintage_outlined,
                            color: isActive
                                ? const Color(0xFFFF8C00)
                                : Colors.white38,
                            size: 28,
                          ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    f.nameEn,
                    style: TextStyle(
                      color:
                          isActive ? const Color(0xFFFF8C00) : Colors.white38,
                      fontSize: 11,
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
  const _FrameRow(
      {required this.frames, this.activeId, required this.onSelect});
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
                          ? Border.all(
                              color: const Color(0xFFFF8C00), width: 2.5)
                          : Border.all(color: Colors.white12),
                    ),
                    child: opt.color == Colors.transparent
                        ? const Icon(Icons.block,
                            color: Colors.white38, size: 20)
                        : isActive
                            ? const Icon(Icons.check,
                                color: Color(0xFFFF8C00), size: 20)
                            : null,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    opt.name,
                    style: TextStyle(
                      color:
                          isActive ? const Color(0xFFFF8C00) : Colors.white38,
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
  const _WatermarkRow(
      {required this.presets, this.activeId, required this.onSelect});
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
                          ? const Icon(Icons.block,
                              color: Colors.white38, size: 20)
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
                      color:
                          isActive ? const Color(0xFFFF8C00) : Colors.white38,
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
    if ((pos - r.bottomRight).distance < _hitSlop)
      return _CropHandle.bottomRight;
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
    if (_activeHandle == null || _dragStart == null || _rectAtDragStart == null)
      return;
    final dx = d.localPosition.dx / size.width - _dragStart!.dx / size.width;
    final dy = d.localPosition.dy / size.height - _dragStart!.dy / size.height;
    final r = _rectAtDragStart!;
    Rect newRect;
    switch (_activeHandle!) {
      case _CropHandle.topLeft:
        newRect = Rect.fromLTRB(
          (r.left + dx).clamp(0.0, r.right - minSize),
          (r.top + dy).clamp(0.0, r.bottom - minSize),
          r.right,
          r.bottom,
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
          r.top,
          r.right,
          (r.bottom + dy).clamp(r.top + minSize, 1.0),
        );
        break;
      case _CropHandle.bottomRight:
        newRect = Rect.fromLTRB(
          r.left,
          r.top,
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
// 相框预览 Overlay（在编辑页预览区叠加相框效果）
// FIX: 新增此 Widget，修复编辑页预览区相框不显示的问题
// ─────────────────────────────────────────────────────────────────────────────
class _FramePreviewOverlay extends StatefulWidget {
  final FrameDefinition frame;
  final String ratioId;
  final String? backgroundColorOverride;

  const _FramePreviewOverlay({
    required this.frame,
    required this.ratioId,
    this.backgroundColorOverride,
  });

  @override
  State<_FramePreviewOverlay> createState() => _FramePreviewOverlayState();
}

class _FramePreviewOverlayState extends State<_FramePreviewOverlay> {
  ui.Image? _pngImage;
  String? _loadedAsset;

  @override
  void didUpdateWidget(_FramePreviewOverlay old) {
    super.didUpdateWidget(old);
    final newAsset = widget.frame.assetForRatio(widget.ratioId);
    if (newAsset != _loadedAsset) {
      _pngImage = null;
      _loadedAsset = null;
      if (newAsset != null && newAsset.isNotEmpty) _loadPng(newAsset);
    }
  }

  @override
  void initState() {
    super.initState();
    final asset = widget.frame.assetForRatio(widget.ratioId);
    if (asset != null && asset.isNotEmpty) _loadPng(asset);
  }

  Future<void> _loadPng(String assetPath) async {
    try {
      final data = await rootBundle.load(assetPath);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      if (mounted)
        setState(() {
          _pngImage = frame.image;
          _loadedAsset = assetPath;
        });
    } catch (e) {
      debugPrint('[FramePreviewOverlay] asset load error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final frame = widget.frame;
    final ratioId = widget.ratioId;
    final backgroundColorOverride = widget.backgroundColorOverride;

    // 解析相框背景色（与 capture_pipeline 一致）
    Color bgColor = const Color(0xFFF5F2EA);
    final bgHexSrc =
        (backgroundColorOverride != null && backgroundColorOverride!.isNotEmpty)
            ? backgroundColorOverride!
            : frame.backgroundColor;
    try {
      if (bgHexSrc.toLowerCase() == 'transparent') {
        bgColor = Colors.transparent;
      } else {
        final hex = bgHexSrc.replaceAll('#', '');
        bgColor = Color(int.parse('FF$hex', radix: 16));
      }
    } catch (_) {}

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final refSize = math.min(w, h);
        final scale = refSize / 1080.0;

        // 获取当前比例对应的 inset
        final activeInset = frame.insetForRatio(ratioId);
        final topPx = activeInset.top * scale;
        final bottomPx = activeInset.bottom * scale;
        final leftPx = activeInset.left * scale;
        final rightPx = activeInset.right * scale;

        // outerPadding：在相框外周加白边（拍立得风格）
        final outerPad =
            frame.outerPadding > 0 ? frame.outerPadding * scale : 0.0;

        // cornerRadius
        final cornerRad =
            frame.cornerRadius > 0 ? frame.cornerRadius * scale : 0.0;

        // 判断是否有 PNG 资源
        final resolvedAsset = frame.assetForRatio(ratioId);
        final hasPng = resolvedAsset != null && resolvedAsset.isNotEmpty;

        return CustomPaint(
          painter: _FrameOverlayPainter(
            bgColor: bgColor,
            topPx: topPx,
            bottomPx: bottomPx,
            leftPx: leftPx,
            rightPx: rightPx,
            outerPad: outerPad,
            cornerRad: cornerRad,
            innerShadow: frame.innerShadow,
            hasPng: hasPng,
            pngImage: _pngImage,
          ),
        );
      },
    );
  }
}

/// CustomPainter 实现相框预览（与 capture_pipeline Dart 降级路径保持一致）
class _FrameOverlayPainter extends CustomPainter {
  final Color bgColor;
  final double topPx, bottomPx, leftPx, rightPx;
  final double outerPad;
  final double cornerRad;
  final bool innerShadow;
  final bool hasPng;
  final ui.Image? pngImage;

  const _FrameOverlayPainter({
    required this.bgColor,
    required this.topPx,
    required this.bottomPx,
    required this.leftPx,
    required this.rightPx,
    required this.outerPad,
    required this.cornerRad,
    required this.innerShadow,
    required this.hasPng,
    this.pngImage,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    if (hasPng) {
      // PNG 资源模式：只画四边相框色块（PNG 层由 Image.asset 在上方另行叠加）
      // 上
      if (topPx > 0 && bgColor != Colors.transparent) {
        canvas.drawRect(
            Rect.fromLTWH(0, 0, w, topPx), Paint()..color = bgColor);
      }
      // 下
      if (bottomPx > 0 && bgColor != Colors.transparent) {
        canvas.drawRect(Rect.fromLTWH(0, h - bottomPx, w, bottomPx),
            Paint()..color = bgColor);
      }
      // 左
      if (leftPx > 0 && bgColor != Colors.transparent) {
        canvas.drawRect(Rect.fromLTWH(0, topPx, leftPx, h - topPx - bottomPx),
            Paint()..color = bgColor);
      }
      // 右
      if (rightPx > 0 && bgColor != Colors.transparent) {
        canvas.drawRect(
            Rect.fromLTWH(w - rightPx, topPx, rightPx, h - topPx - bottomPx),
            Paint()..color = bgColor);
      }
      // 叠加 PNG 纹理
      if (pngImage != null) {
        canvas.drawImageRect(
          pngImage!,
          Rect.fromLTWH(
              0, 0, pngImage!.width.toDouble(), pngImage!.height.toDouble()),
          Rect.fromLTWH(0, 0, w, h),
          Paint()..filterQuality = FilterQuality.medium,
        );
      }
    } else {
      // 纯色块模式：四边 + outerPadding + cornerRadius
      if (bgColor == Colors.transparent) return;
      // outerPad 外层背景
      if (outerPad > 0) {
        canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = bgColor);
      }
      // 四边色块
      final paint = Paint()..color = bgColor;
      if (topPx > 0)
        canvas.drawRect(
            Rect.fromLTWH(outerPad, outerPad, w - outerPad * 2, topPx), paint);
      if (bottomPx > 0)
        canvas.drawRect(
            Rect.fromLTWH(
                outerPad, h - outerPad - bottomPx, w - outerPad * 2, bottomPx),
            paint);
      if (leftPx > 0)
        canvas.drawRect(
            Rect.fromLTWH(outerPad, outerPad + topPx, leftPx,
                h - outerPad * 2 - topPx - bottomPx),
            paint);
      if (rightPx > 0)
        canvas.drawRect(
            Rect.fromLTWH(w - outerPad - rightPx, outerPad + topPx, rightPx,
                h - outerPad * 2 - topPx - bottomPx),
            paint);
    }

    // innerShadow：在图片区域边缘画渐变阴影
    if (innerShadow) {
      const shadowColor = Color(0x55000000);
      const shadowWidthFraction = 0.06;
      final imgX = (hasPng ? 0.0 : outerPad) + leftPx;
      final imgY = (hasPng ? 0.0 : outerPad) + topPx;
      final imgW = w - (hasPng ? 0.0 : outerPad * 2) - leftPx - rightPx;
      final imgH = h - (hasPng ? 0.0 : outerPad * 2) - topPx - bottomPx;
      final sw = math.min(imgW, imgH) * shadowWidthFraction;
      // 上
      canvas.drawRect(
        Rect.fromLTWH(imgX, imgY, imgW, sw),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [shadowColor, Colors.transparent],
          ).createShader(Rect.fromLTWH(imgX, imgY, imgW, sw)),
      );
      // 下
      canvas.drawRect(
        Rect.fromLTWH(imgX, imgY + imgH - sw, imgW, sw),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [shadowColor, Colors.transparent],
          ).createShader(Rect.fromLTWH(imgX, imgY + imgH - sw, imgW, sw)),
      );
      // 左
      canvas.drawRect(
        Rect.fromLTWH(imgX, imgY, sw, imgH),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [shadowColor, Colors.transparent],
          ).createShader(Rect.fromLTWH(imgX, imgY, sw, imgH)),
      );
      // 右
      canvas.drawRect(
        Rect.fromLTWH(imgX + imgW - sw, imgY, sw, imgH),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.centerRight,
            end: Alignment.centerLeft,
            colors: [shadowColor, Colors.transparent],
          ).createShader(Rect.fromLTWH(imgX + imgW - sw, imgY, sw, imgH)),
      );
    }
  }

  @override
  bool shouldRepaint(_FrameOverlayPainter old) =>
      old.bgColor != bgColor ||
      old.topPx != topPx ||
      old.bottomPx != bottomPx ||
      old.leftPx != leftPx ||
      old.rightPx != rightPx ||
      old.outerPad != outerPad ||
      old.cornerRad != cornerRad ||
      old.innerShadow != innerShadow ||
      old.hasPng != hasPng ||
      old.pngImage != pngImage;
}

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
      case 'bottom_left':
        align = Alignment.bottomLeft;
        break;
      case 'bottom_center':
        align = Alignment.bottomCenter;
        break;
      case 'top_right':
        align = Alignment.topRight;
        break;
      case 'top_left':
        align = Alignment.topLeft;
        break;
      default:
        align = Alignment.bottomRight;
    }
    return Align(
      alignment: align,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          watermark.name,
          style: TextStyle(
            color: textColor,
            fontSize: 12.0,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
