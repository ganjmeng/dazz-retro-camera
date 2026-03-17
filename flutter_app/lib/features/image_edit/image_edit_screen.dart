// ImageEditScreen — 导入图片编辑页
// 设计哲学：Darkroom Aesthetics — 纯黑背景，白色控件，复用相机页所有效果逻辑
// 底部工具按钮显示/隐藏由当前相机 uiCap 决定，完全复用拍摄页逻辑
import 'dart:io';
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
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (ctx) => ProviderScope(
        parent: ProviderScope.containerOf(context),
        child: ImageEditScreen(imagePath: file.path),
      ),
      fullscreenDialog: true,
    ),
  );
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

  double get _totalRotation => _coarseRotation.toDouble() + _fineRotation;

  @override
  void initState() {
    super.initState();
    _initPreview();
  }

  Future<void> _initPreview() async {
    try {
      await File(widget.imagePath).readAsBytes();
      if (mounted) setState(() => _isLoading = false);
      // 初始 GPU 预览
      _refreshGpuPreview();
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

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
        'filePath': widget.imagePath,
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
      final transformedBytes = await _applyTransforms();
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
      // _applyTransforms 已使用 GPU 预览图（带滤镜效果），
      // pipeline.process 中跳过色彩处理（useGpu=false + renderParams=null），
      // 仅做相框/水印合成
      final result = await pipeline.process(
        imagePath: tmpPath,
        useGpu: false,        // 跳过 GPU 色彩处理
        renderParams: null,   // 跳过 Dart 降级色彩处理（色彩已由 GPU 预览完成）
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

  /// 应用裁剪/旋转/翻转变换，输入源为 GPU 预览图（已带滤镜效果）或原图
  Future<Uint8List?> _applyTransforms() async {
    try {
      // 优先使用 GPU 预览图（已带滤镜效果），降级时使用原图
      final sourcePath = _gpuPreviewPath ?? widget.imagePath;
      final bytes = await File(sourcePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final src = frame.image;
      final srcW = src.width.toDouble();
      final srcH = src.height.toDouble();
      final cropX = _cropRect.left * srcW;
      final cropY = _cropRect.top * srcH;
      final cropW = _cropRect.width * srcW;
      final cropH = _cropRect.height * srcH;
      final totalRad = _totalRotation * math.pi / 180.0;
      final absCos = math.cos(totalRad).abs();
      final absSin = math.sin(totalRad).abs();
      final outW = (cropW * absCos + cropH * absSin).toInt();
      final outH = (cropW * absSin + cropH * absCos).toInt();
      // 安全检查：避免 0 尺寸导致崩溃
      if (outW <= 0 || outH <= 0) {
        debugPrint('[ImageEditScreen] Invalid output dimensions: ${outW}x$outH');
        return null;
      }
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.translate(outW / 2.0, outH / 2.0);
      canvas.rotate(totalRad);
      if (_flipH) canvas.scale(-1.0, 1.0);
      canvas.drawImageRect(
        src,
        Rect.fromLTWH(cropX, cropY, cropW, cropH),
        Rect.fromLTWH(-cropW / 2.0, -cropH / 2.0, cropW, cropH),
        Paint()..filterQuality = FilterQuality.high,
      );
      final picture = recorder.endRecording();
      final outputImage = await picture.toImage(outW, outH);
      final byteData = await outputImage.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return null;
      final img = image_lib.Image.fromBytes(
        width: outW,
        height: outH,
        bytes: byteData.buffer,
        format: image_lib.Format.uint8,
        numChannels: 4,
      );
      return image_lib.encodeJpg(img, quality: 95);
    } catch (e) {
      debugPrint('[ImageEditScreen] _applyTransforms error: $e');
      return null;
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final st = ref.watch(cameraAppProvider);
    final camera = st.camera;
    final uiCap = camera?.uiCapabilities;

    // 监听相机/滤镜/参数变化，实时刷新 GPU 预览
    ref.listen<CameraAppState>(cameraAppProvider, (prev, next) {
      // renderParams 变化时重新生成 GPU 预览（切换相机、滤镜、曝光等）
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
            // ── 图片预览区 ──────────────────────────────────────────────────
            Expanded(
              child: _buildPreviewArea(st, camera),
            ),
            // ── 旋转刻度尺 ──────────────────────────────────────────────────
            _buildRotationRuler(),
            // ── 相机菜单（常驻底部）────────────────────────────────────────
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

  // ── 图片预览区 ────────────────────────────────────────────────────────────
  Widget _buildPreviewArea(CameraAppState st, CameraDefinition? camera) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
      );
    }
    return GestureDetector(
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
                    if (st.activeFrame != null)
                      IgnorePointer(
                        child: _FramePreviewOverlay(
                          frame: st.activeFrame!,
                          ratioId: st.activeRatioId ?? '',
                        ),
                      ),
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
    );
  }

  Widget _buildTransformedImage(CameraAppState st, BoxConstraints constraints) {
    // 显示 GPU Shader 处理后的预览图（带滤镜效果），降级时显示原图
    final previewFile = _gpuPreviewPath != null
        ? File(_gpuPreviewPath!)
        : File(widget.imagePath);
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
        key: ValueKey(_gpuPreviewPath ?? widget.imagePath),
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

  // ── 常驻底部相机菜单 ─────────────────────────────────────────────────
  Widget _buildInlineCameraMenu(CameraAppState st) {
    return const CameraConfigInlinePanel(showLens: false);
  }

  // ── 相机选择横向列表（备用，已不在主流程中使用）─────────────────────────────
  Widget _buildCameraSelector(CameraAppState st) {
    return GestureDetector(
      onTap: () => showCameraConfigSheet(context),
      child: Container(
        height: 52,
        color: const Color(0xFF111111),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const Icon(Icons.camera_alt_outlined, color: Colors.white54, size: 18),
            const SizedBox(width: 8),
            Text(
              st.camera?.name ?? sOf(ref.read(languageProvider)).selectCamera,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.keyboard_arrow_up, color: Colors.white38, size: 18),
            const Spacer(),
            // 当前滤镜/边框标签
            if (st.activeFilterId != null)
              _TagChip(label: st.activeFilterId!),
            if (st.activeFrameId != null && st.activeFrameId != 'none')
              _TagChip(label: sOf(ref.read(languageProvider)).frame),
          ],
        ),
      ),
    );
  }

  // ── 底部工具按钮行 ────────────────────────────────────────────────────────
  Widget _buildBottomToolbar(CameraAppState st, CameraDefinition? camera, UiCapabilities? uiCap) {
    if (camera == null) {
      return const SizedBox(height: 72);
    }
    return Container(
      height: 80,
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // 水印开关（由uiCap.enableWatermark决定）
          if (uiCap?.enableWatermark == true)
            _ToolIconBtn(
              icon: st.activeWatermark != null && !st.activeWatermark!.isNone
                  ? Icons.access_time
                  : Icons.access_time_outlined,
              label: sOf(ref.read(languageProvider)).watermark,
              isActive: st.activeWatermark != null && !st.activeWatermark!.isNone,
              onTap: () => _togglePanel('watermark'),
            ),
          // 边框开关（由uiCap.enableFrame决定）
          if (uiCap?.enableFrame == true)
            _ToolIconBtn(
              icon: st.activeFrameId != null && st.activeFrameId != 'none'
                  ? Icons.crop_square
                  : Icons.crop_square_outlined,
              label: sOf(ref.read(languageProvider)).frame,
              isActive: st.activeFrameId != null && st.activeFrameId != 'none',
              onTap: () => _togglePanel('frame'),
            ),
          // 滤镜（由uiCap.enableFilter决定）
          if (uiCap?.enableFilter == true)
            _ToolIconBtn(
              icon: Icons.filter_vintage_outlined,
              label: sOf(ref.read(languageProvider)).filter,
              isActive: _activePanel == 'filter',
              onTap: () => _togglePanel('filter'),
            ),
          // 翻转（始终显示）
          _ToolIconBtn(
            icon: Icons.flip_outlined,
            label: sOf(ref.read(languageProvider)).flip,
            isActive: _flipH,
            onTap: _flipHorizontal,
          ),
          // 裁剪（始终显示）
          _ToolIconBtn(
            icon: Icons.crop_outlined,
            label: sOf(ref.read(languageProvider)).crop,
            isActive: _isCropMode,
            onTap: () => setState(() => _isCropMode = !_isCropMode),
          ),
        ],
      ),
    );
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

class _ToolIconBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isActive;
  const _ToolIconBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isActive = false,
  });
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isActive
                  ? const Color(0xFFFF8C00).withOpacity(0.2)
                  : Colors.white10,
              border: isActive
                  ? Border.all(color: const Color(0xFFFF8C00), width: 1.5)
                  : null,
            ),
            child: Icon(
              icon,
              color: isActive ? const Color(0xFFFF8C00) : Colors.white70,
              size: 22,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: isActive ? const Color(0xFFFF8C00) : Colors.white38,
              fontSize: 11,
            ),
          ),
        ],
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
// 相框预览 Overlay（复用拍摄页）
// ─────────────────────────────────────────────────────────────────────────────
class _FramePreviewOverlay extends StatelessWidget {
  final FrameDefinition frame;
  final String ratioId;
  const _FramePreviewOverlay({required this.frame, required this.ratioId});
  @override
  Widget build(BuildContext context) {
    final assetPath = frame.assetForRatio(ratioId);
    if (assetPath == null) return const SizedBox.shrink();
    return Image.asset(
      assetPath,
      fit: BoxFit.fill,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }
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
