
// ─────────────────────────────────────────────────────────────────────────────
// 设计哲学：Darkroom Aesthetics — 纯黑背景，白色控件
// 编辑页完全独立，不读写 cameraAppProvider，所有状态均为本地一次性状态
// 进入时直接显示原图，用户点击相机后才渲染 GPU 预览效果
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
import '../../models/camera_registry.dart';
import '../camera/camera_notifier.dart';
import '../camera/capture_pipeline.dart';
import '../camera/preview_renderer.dart' as renderer_lib;
import 'package:image/image.dart' as image_lib;
import '../../core/l10n.dart';
import '../../services/camera_manager_service.dart';


// ─────────────────────────────────────────────────────────────────────────────
// 入口
// ─────────────────────────────────────────────────────────────────────────────
Future<void> openImageImportFlow(BuildContext context) async {
  final picker = ImagePicker();
  final XFile? file = await picker.pickImage(source: ImageSource.gallery);
  if (file == null) return;
  if (!context.mounted) return;

  // 显示转圈遮罩：图片选好后到页面跳转前
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

  // 跳转到编辑页，遮罩在页面加载完成后由编辑页内部移除
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (ctx) => ProviderScope(
        parent: ProviderScope.containerOf(context),
        child: ImageEditScreen(
          imagePath: file.path,
          loadingOverlay: loadingOverlay,
        ),
      ),
      fullscreenDialog: true,
    ),
  );
  // 如果页面没有移除遮罩（异常情况），在这里兜底移除
  try { loadingOverlay?.remove(); } catch (_) {}
}

/// 导入图片时的转圈加载遮罩
class _ImportLoadingOverlay extends StatelessWidget {
  const _ImportLoadingOverlay();

  @override
  Widget build(BuildContext context) {
    return const Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(color: Color(0xCC000000)),
          ),
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
  /// 来自 openImageImportFlow 的加载遮罩，页面就绪后移除
  final OverlayEntry? loadingOverlay;
  const ImageEditScreen({super.key, required this.imagePath, this.loadingOverlay});
  @override
  ConsumerState<ImageEditScreen> createState() => _ImageEditScreenState();
}

class _ImageEditScreenState extends ConsumerState<ImageEditScreen> {
  // ── 编辑参数 ──────────────────────────────────────────────────────────────
  double _fineRotation = 0.0;
  int _coarseRotation = 0;
  bool _flipH = false;
  bool _isCropMode = false;
  Rect _cropRect = const Rect.fromLTWH(0, 0, 1, 1);

  // ── 预览手势 ──────────────────────────────────────────────────────────────
  double _previewScale = 1.0;
  double _scaleStart = 1.0;
  Offset _previewOffset = Offset.zero;
  Offset _panStart = Offset.zero;

  // ── 面板状态 ──────────────────────────────────────────────────────────────
  String? _activePanel; // 'filter' | 'frame' | 'watermark' | null

  // ── 保存状态 ──────────────────────────────────────────────────────────────
  bool _isSaving = false;

  // ── GPU 预览 ─────────────────────────────────────────────────────────────
  static const MethodChannel _gpuChannel = MethodChannel('com.retrocam.app/camera_control');
  String? _gpuPreviewPath;
  bool _gpuProcessing = false;
  int _gpuRequestId = 0;

  // ── 高清图片缩小后的预览源路径 ──────────────────────────────────────────────
  String? _resizedPreviewPath;
  static const int _kMaxPreviewDim = 4096;

  // ── 白平衡/曝光控件状态 ──────────────────────────────────────────────────
  bool _showExposureSlider = false;
  bool _showWbPanel = false;

  // ── 本地相机/效果状态（完全独立，不影响拍摄页）──────────────────────────────
  CameraDefinition? _camera;        // 当前选中的相机定义
  String? _activeCameraId;          // 当前选中的相机 ID
  bool _cameraLoading = false;      // 是否正在加载相机
  String? _activeFilterId;
  String? _activeLensId;
  String? _activeRatioId;
  String? _activeWatermarkId;
  double _temperatureOffset = 0;
  double _exposureValue = 0;
  String _wbMode = 'auto';
  int _colorTempK = 6300;
  String? _watermarkColor;
  String? _watermarkPosition;
  String? _watermarkSize;
  String? _watermarkDirection;
  String? _watermarkStyle;

  double get _totalRotation => _coarseRotation.toDouble() + _fineRotation;

  // ── 从本地状态构建 renderParams ──────────────────────────────────────────
  renderer_lib.PreviewRenderParams? get _renderParams {
    final cam = _camera;
    if (cam == null) return null;
    final filter = _activeFilterId != null
        ? cam.modules.filters.where((f) => f.id == _activeFilterId).firstOrNull
        : null;
    final lens = _activeLensId != null
        ? cam.modules.lenses.where((l) => l.id == _activeLensId).firstOrNull
        : null;
    return renderer_lib.PreviewRenderParams(
      defaultLook: cam.defaultLook,
      activeFilter: filter,
      activeLens: lens,
      temperatureOffset: _temperatureOffset,
      exposureOffset: _exposureValue,
      policy: cam.previewPolicy,
    );
  }

  double get _previewAspectRatio {
    final cam = _camera;
    if (cam == null || _activeRatioId == null) return 3 / 4;
    try {
      final ratio = cam.modules.ratios.firstWhere((r) => r.id == _activeRatioId);
      return ratio.width / ratio.height;
    } catch (_) {
      return 3 / 4;
    }
  }

  WatermarkPreset? get _activeWatermark {
    final cam = _camera;
    if (cam == null || _activeWatermarkId == null) return null;
    try {
      return cam.modules.watermarks.presets.firstWhere((w) => w.id == _activeWatermarkId);
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _initPreview();
  }

  /// 初始化预览：直接显示原图，同时在后台缩小高清图（如需要）
  Future<void> _initPreview() async {
    try {
      // 读取原图并检查尺寸
      final originalBytes = await File(widget.imagePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(originalBytes);
      final frame = await codec.getNextFrame();
      final srcW = frame.image.width;
      final srcH = frame.image.height;
      frame.image.dispose();

      // 如果原图超过 _kMaxPreviewDim，在后台 isolate 中缩小
      if (srcW > _kMaxPreviewDim || srcH > _kMaxPreviewDim) {
        final scale = _kMaxPreviewDim / math.max(srcW, srcH);
        final newW = (srcW * scale).round();
        final newH = (srcH * scale).round();
        final resizedJpg = await Isolate.run(() {
          final decoded = image_lib.decodeImage(originalBytes);
          if (decoded == null) return null;
          final resized = image_lib.copyResize(decoded, width: newW, height: newH,
              interpolation: image_lib.Interpolation.linear);
          return image_lib.encodeJpg(resized, quality: 92);
        });
        if (resizedJpg != null && mounted) {
          final tmpPath = '${Directory.systemTemp.path}/dazz_resized_${DateTime.now().millisecondsSinceEpoch}.jpg';
          await File(tmpPath).writeAsBytes(resizedJpg);
          if (mounted) setState(() => _resizedPreviewPath = tmpPath);
        }
      }
    } catch (e) {
      debugPrint('[ImageEditScreen] _initPreview error: $e');
    } finally {
      // 图片就绪，移除外部加载遮罩
      if (mounted) {
        try { widget.loadingOverlay?.remove(); } catch (_) {}
      }
    }
  }

  /// GPU 预览使用的源路径
  String get _previewSourcePath => _resizedPreviewPath ?? widget.imagePath;

  /// 用户选择相机后，加载相机定义并触发 GPU 渲染
  Future<void> _selectCamera(String cameraId) async {
    if (_activeCameraId == cameraId && _camera != null) return;
    if (_cameraLoading) return;

    setState(() {
      _cameraLoading = true;
      _activeCameraId = cameraId;
    });

    try {
      final camera = await loadCamera(cameraId);
      if (!mounted) return;
      final defaults = camera.defaultSelection;
      setState(() {
        _camera = camera;
        _cameraLoading = false;
        _activeFilterId = defaults.filterId;
        _activeLensId = defaults.lensId;
        _activeRatioId = defaults.ratioId;
        _activeWatermarkId = defaults.watermarkPresetId;
        _temperatureOffset = 0;
        _exposureValue = 0;
        _wbMode = 'auto';
        _colorTempK = 6300;
        _watermarkColor = null;
        _watermarkPosition = null;
        _watermarkSize = null;
        _watermarkDirection = null;
        _watermarkStyle = null;
      });
      // 加载完成后立即渲染 GPU 预览
      await _refreshGpuPreview();
    } catch (e) {
      debugPrint('[ImageEditScreen] _selectCamera error: $e');
      if (mounted) setState(() => _cameraLoading = false);
    }
  }

  /// 调用 Native GPU Shader 生成带滤镜效果的预览图
  Future<void> _refreshGpuPreview() async {
    final renderParams = _renderParams;
    if (renderParams == null) return;

    final requestId = ++_gpuRequestId;
    if (_gpuProcessing) return;
    _gpuProcessing = true;

    try {
      final result = await _gpuChannel.invokeMethod<Map>('processWithGpu', {
        'filePath': _previewSourcePath,
        'params': renderParams.toJson(),
      });
      if (!mounted || requestId != _gpuRequestId) return;
      if (result != null && result['filePath'] != null) {
        if (_gpuPreviewPath != null) {
          try { File(_gpuPreviewPath!).deleteSync(); } catch (_) {}
        }
        setState(() => _gpuPreviewPath = result['filePath'] as String);
      }
    } catch (e) {
      debugPrint('[ImageEditScreen] GPU preview failed: $e');
    } finally {
      _gpuProcessing = false;
      if (mounted && requestId != _gpuRequestId) {
        _refreshGpuPreview();
      }
    }
  }

  @override
  void dispose() {
    if (_gpuPreviewPath != null) {
      try { File(_gpuPreviewPath!).deleteSync(); } catch (_) {}
    }
    if (_resizedPreviewPath != null) {
      try { File(_resizedPreviewPath!).deleteSync(); } catch (_) {}
    }
    // 兜底：如果遮罩还没移除
    try { widget.loadingOverlay?.remove(); } catch (_) {}
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
      final camera = _camera;
      if (camera == null) {
        _showSnack(sOf(ref.read(languageProvider)).selectCameraFirst);
        setState(() => _isSaving = false);
        return;
      }

      final renderParams = _renderParams;
      String gpuSourceForSave = widget.imagePath;

      if (renderParams != null) {
        try {
          final result = await _gpuChannel.invokeMethod<Map>('processWithGpu', {
            'filePath': widget.imagePath,
            'params': renderParams.toJson(),
          });
          if (result != null && result['filePath'] != null) {
            gpuSourceForSave = result['filePath'] as String;
          }
        } catch (e) {
          debugPrint('[ImageEditScreen] GPU save processing failed: $e');
          gpuSourceForSave = _gpuPreviewPath ?? widget.imagePath;
        }
      }

      final transformedBytes = await _applyTransforms(sourcePath: gpuSourceForSave);
      if (gpuSourceForSave != widget.imagePath && gpuSourceForSave != _gpuPreviewPath) {
        try { File(gpuSourceForSave).deleteSync(); } catch (_) {}
      }

      if (transformedBytes == null) {
        _showSnack(sOf(ref.read(languageProvider)).imageProcessFailed);
        setState(() => _isSaving = false);
        return;
      }

      final tmpPath = '${Directory.systemTemp.path}/dazz_edit_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(tmpPath).writeAsBytes(transformedBytes);
      final pipeline = CapturePipeline(camera: camera);
      const maxDim = CapturePipeline.kMaxDimHigh;
      const jpegQ = CapturePipeline.kJpegQualityHigh;
      final result = await pipeline.process(
        imagePath: tmpPath,
        useGpu: false,
        renderParams: null,
        selectedRatioId: _activeRatioId ?? '',
        selectedFrameId: '',
        selectedWatermarkId: _activeWatermarkId ?? '',
        watermarkColorOverride: _watermarkColor,
        watermarkPositionOverride: _watermarkPosition,
        watermarkSizeOverride: _watermarkSize,
        watermarkDirectionOverride: _watermarkDirection,
        watermarkStyleOverride: _watermarkStyle,
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
  Future<Uint8List?> _applyTransforms({String? sourcePath}) async {
    try {
      final path = sourcePath ?? _gpuPreviewPath ?? _previewSourcePath;
      final bytes = await File(path).readAsBytes();
      final cropRect = _cropRect;
      final totalRotation = _totalRotation;
      final flipH = _flipH;
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
        image_lib.Image current = image_lib.copyCrop(
          decoded, x: cropX, y: cropY, width: cropW, height: cropH,
        );
        if (flipH) current = image_lib.flipHorizontal(current);
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
    final lang = ref.watch(languageProvider);
    final s = sOf(lang);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(s),
            Expanded(child: _buildPreviewArea()),
            _buildRotationRuler(),
            _buildInlineCameraMenu(s),
            if (_activePanel != null && _camera != null)
              _buildSubPanel(s),
          ],
        ),
      ),
    );
  }

  // ── 顶部导航栏 ────────────────────────────────────────────────────────────
  Widget _buildTopBar(S s) {
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
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white12,
              ),
              child: const Icon(Icons.close, color: Colors.white, size: 20),
            ),
          ),
          const Spacer(),
          Text(
            s.edit,
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
                      s.save,
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
  Widget _buildPreviewArea() {
    return Stack(
      children: [
        GestureDetector(
          onDoubleTap: () => setState(() {
            _previewScale = 1.0;
            _previewOffset = Offset.zero;
          }),
          onScaleStart: (d) {
            _scaleStart = _previewScale;
            _panStart = d.focalPoint - _previewOffset;
          },
          onScaleUpdate: (d) {
            setState(() {
              _previewScale = (_scaleStart * d.scale).clamp(1.0, 5.0);
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
                aspectRatio: _previewAspectRatio,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipRect(child: _buildTransformedImage(constraints)),
                        if (_activeWatermark != null && !_activeWatermark!.isNone)
                          IgnorePointer(
                            child: _WatermarkPreviewOverlay(
                              watermark: _activeWatermark!,
                              colorOverride: _watermarkColor,
                              positionOverride: _watermarkPosition,
                              sizeOverride: _watermarkSize,
                              directionOverride: _watermarkDirection,
                              styleId: _watermarkStyle,
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
        // 相机加载中转圈（覆盖在预览图上方）
        if (_cameraLoading)
          const Positioned.fill(
            child: Center(
              child: SizedBox(
                width: 48,
                height: 48,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 3,
                ),
              ),
            ),
          ),
        // 白平衡+曝光胶囊控件
        Positioned(
          left: 0, right: 0,
          bottom: _showExposureSlider || _showWbPanel ? 64 : 12,
          child: Center(child: _buildEditControlCapsule()),
        ),
        if (_showExposureSlider)
          Positioned(
            left: 0, right: 0, bottom: 12, height: 52,
            child: Center(
              child: _ExposureHorizontalSlider(
                value: _exposureValue,
                onChanged: (v) {
                  setState(() => _exposureValue = v);
                  _refreshGpuPreview();
                },
                onReset: () {
                  setState(() => _exposureValue = 0);
                  _refreshGpuPreview();
                },
              ),
            ),
          ),
        if (_showWbPanel && !_showExposureSlider)
          Positioned(
            left: 0, right: 0, bottom: 12, height: 52,
            child: Center(
              child: _WbControlPanel(
                colorTempK: _colorTempK,
                wbMode: _wbMode,
                onTempChanged: (k) {
                  setState(() => _colorTempK = k);
                  _refreshGpuPreview();
                },
                onPreset: (mode) {
                  setState(() => _wbMode = mode);
                  _refreshGpuPreview();
                },
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildEditControlCapsule() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () {
            setState(() {
              _showWbPanel = !_showWbPanel;
              if (_showWbPanel) _showExposureSlider = false;
            });
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 34, height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (_showWbPanel || _wbMode != 'auto')
                  ? Colors.white.withAlpha(230)
                  : Colors.black.withAlpha(160),
            ),
            child: Center(
              child: Icon(
                _showWbPanel ? Icons.keyboard_arrow_down : Icons.thermostat_outlined,
                size: 16,
                color: (_showWbPanel || _wbMode != 'auto') ? Colors.black : Colors.white,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        GestureDetector(
          onTap: () {
            setState(() {
              _showExposureSlider = !_showExposureSlider;
              if (_showExposureSlider) _showWbPanel = false;
            });
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: (_showExposureSlider || _exposureValue != 0)
                  ? Colors.white.withAlpha(230)
                  : Colors.black.withAlpha(160),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _showExposureSlider ? Icons.keyboard_arrow_down : Icons.wb_sunny_outlined,
                  size: 14,
                  color: (_showExposureSlider || _exposureValue != 0) ? Colors.black : Colors.white,
                ),
                const SizedBox(width: 5),
                Text(
                  _exposureValue == 0
                      ? '0.0'
                      : (_exposureValue > 0 ? '+' : '') + _exposureValue.toStringAsFixed(1),
                  style: TextStyle(
                    color: (_showExposureSlider || _exposureValue != 0) ? Colors.black : Colors.white,
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

  Widget _buildTransformedImage(BoxConstraints constraints) {
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _RulerIconBtn(icon: Icons.flip_outlined, onTap: _flipHorizontal),
                const SizedBox(width: 8),
                _RulerIconBtn(icon: Icons.rotate_90_degrees_ccw_outlined, onTap: _rotate90),
                const Spacer(),
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
                _RulerIconBtn(
                  icon: _isCropMode ? Icons.check_circle_outline : Icons.crop_outlined,
                  isActive: _isCropMode,
                  onTap: () => setState(() => _isCropMode = !_isCropMode),
                ),
                const SizedBox(width: 8),
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

  // ── 常驻底部相机菜单 ──────────────────────────────────────────────────────
  Widget _buildInlineCameraMenu(S s) {
    return _EditCameraPanel(
      activeCameraId: _activeCameraId,
      activeCamera: _camera,
      activeFilterId: _activeFilterId,
      activeLensId: _activeLensId,
      activeWatermarkId: _activeWatermarkId,
      onCameraSelected: _selectCamera,
      onFilterTap: () => _togglePanel('filter'),
      onWatermarkTap: () => _togglePanel('watermark'),
      onLensSelected: (id) {
        setState(() => _activeLensId = id);
        _refreshGpuPreview();
      },
    );
  }

  // ── 上滑子面板 ────────────────────────────────────────────────────────────
  Widget _buildSubPanel(S s) {
    final camera = _camera!;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      color: const Color(0xFF1A1A1A),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                _activePanel == 'filter' ? s.filter
                    : _activePanel == 'frame' ? s.frame
                    : s.watermark,
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
          switch (_activePanel) {
            'filter' => _FilterRow(
                filters: camera.modules.filters,
                activeId: _activeFilterId,
                onSelect: (id) {
                  setState(() => _activeFilterId = id);
                  _refreshGpuPreview();
                },
              ),
            'watermark' => _WatermarkRow(
                presets: camera.modules.watermarks.presets,
                activeId: _activeWatermarkId,
                onSelect: (id) => setState(() => _activeWatermarkId = id),
              ),
            _ => const SizedBox.shrink(),
          },
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 编辑页底部相机面板（独立，不依赖 cameraAppProvider）
// ─────────────────────────────────────────────────────────────────────────────
class _EditCameraPanel extends ConsumerWidget {
  final String? activeCameraId;
  final CameraDefinition? activeCamera;
  final String? activeFilterId;
  final String? activeLensId;
  final String? activeWatermarkId;
  final ValueChanged<String> onCameraSelected;
  final VoidCallback onFilterTap;
  final VoidCallback onWatermarkTap;
  final ValueChanged<String> onLensSelected;

  const _EditCameraPanel({
    required this.activeCameraId,
    required this.activeCamera,
    required this.activeFilterId,
    required this.activeLensId,
    required this.activeWatermarkId,
    required this.onCameraSelected,
    required this.onFilterTap,
    required this.onWatermarkTap,
    required this.onLensSelected,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final managerAsync = ref.watch(cameraManagerProvider);
    final s = sOf(ref.watch(languageProvider));

    final List<CameraEntry> orderedCameras;
    if (managerAsync.hasValue) {
      final mgr = managerAsync.value!;
      final sortedIds = [
        ...mgr.favoriteIds,
        ...mgr.nonFavoriteIds,
      ].where((id) => mgr.enabledIds.contains(id)).toList();
      orderedCameras = sortedIds
          .map((id) => kAllCameras.where((c) => c.id == id).firstOrNull)
          .whereType<CameraEntry>()
          .toList();
    } else {
      orderedCameras = List.from(kAllCameras);
    }

    final cam = activeCamera;
    final uiCap = cam?.uiCapabilities;

    return Container(
      color: const Color(0xFF1A1A1A),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(height: 1, color: Color(0xFF3A3A3C)),
          // 相机列表行
          SizedBox(
            height: 110,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: orderedCameras.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (ctx, i) {
                final entry = orderedCameras[i];
                final isActive = activeCameraId == entry.id;
                final isFav = managerAsync.hasValue
                    ? managerAsync.value!.favoritedIds.contains(entry.id)
                    : false;
                return _EditCameraCell(
                  entry: entry,
                  isActive: isActive,
                  isFavorite: isFav,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onCameraSelected(entry.id);
                  },
                );
              },
            ),
          ),
          const Divider(height: 1, color: Color(0xFF3A3A3C)),
          // 功能图标行（仅在相机已加载时显示）
          if (cam != null && uiCap != null) ...[
            SizedBox(
              height: 90,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                children: [
                  if (uiCap.enableWatermark) ...[
                    _EditFuncBtn(
                      label: s.watermark,
                      isActive: activeWatermarkId != null && activeWatermarkId != 'none',
                      onTap: onWatermarkTap,
                      child: Icon(
                        Icons.water_drop_outlined,
                        size: 22,
                        color: (activeWatermarkId != null && activeWatermarkId != 'none')
                            ? const Color(0xFFFF9500)
                            : Colors.white54,
                      ),
                    ),
                    const SizedBox(width: 16),
                  ],
                  if (uiCap.enableFilter) ...[
                    _EditFuncBtn(
                      label: s.filter,
                      isActive: false,
                      onTap: onFilterTap,
                      child: const Icon(Icons.filter_vintage_outlined, size: 22, color: Colors.white54),
                    ),
                    const SizedBox(width: 16),
                  ],
                  // 分隔点
                  if (uiCap.enableLens && cam.modules.lenses.isNotEmpty) ...[
                    const _EditDotSeparator(),
                    const SizedBox(width: 16),
                    ...cam.modules.lenses.map((lens) => Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: _EditLensBtn(
                        lens: lens,
                        isActive: activeLensId == lens.id,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          onLensSelected(lens.id);
                        },
                      ),
                    )),
                  ],
                ],
              ),
            ),
          ],
          SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
        ],
      ),
    );
  }
}

class _EditCameraCell extends StatelessWidget {
  final CameraEntry entry;
  final bool isActive;
  final bool isFavorite;
  final VoidCallback onTap;
  const _EditCameraCell({
    required this.entry,
    required this.isActive,
    required this.onTap,
    this.isFavorite = false,
  });
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 72,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2C2C2E),
                    borderRadius: BorderRadius.circular(12),
                    border: isActive
                        ? Border.all(color: const Color(0xFFFF9500), width: 2.5)
                        : null,
                  ),
                  child: (entry.iconPath?.isNotEmpty ?? false)
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.asset(
                            entry.iconPath!,
                            width: 64, height: 64,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Center(
                              child: Icon(
                                Icons.camera_alt_outlined,
                                color: isActive ? const Color(0xFFFF9500) : const Color(0xFF8E8E93),
                                size: 28,
                              ),
                            ),
                          ),
                        )
                      : Center(
                          child: Icon(
                            Icons.camera_alt_outlined,
                            color: isActive ? const Color(0xFFFF9500) : const Color(0xFF8E8E93),
                            size: 28,
                          ),
                        ),
                ),
                if (isFavorite)
                  Positioned(
                    top: -2, left: -2,
                    child: Container(
                      width: 18, height: 18,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A1A),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: const Center(
                        child: Text('★', style: TextStyle(fontSize: 11, color: Color(0xFFFFCC00), height: 1.0)),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              entry.name,
              style: TextStyle(
                color: isActive ? const Color(0xFFFF9500) : Colors.white,
                fontSize: 11,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _EditFuncBtn extends StatelessWidget {
  final String label;
  final Widget child;
  final bool isActive;
  final VoidCallback onTap;
  const _EditFuncBtn({required this.label, required this.child, required this.isActive, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 52,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isActive
                    ? const Color(0xFFFF9500).withOpacity(0.15)
                    : const Color(0xFF2C2C2E),
              ),
              child: Center(child: child),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: isActive ? const Color(0xFFFF9500) : const Color(0xFF8E8E93),
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
  }
}

class _EditDotSeparator extends StatelessWidget {
  const _EditDotSeparator();
  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 6, height: 74,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Dot(), SizedBox(height: 4), _Dot(), SizedBox(height: 4), _Dot(),
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 3, height: 3,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFF8E8E93),
      ),
    );
  }
}

class _EditLensBtn extends StatelessWidget {
  final LensDefinition lens;
  final bool isActive;
  final VoidCallback onTap;
  const _EditLensBtn({required this.lens, required this.isActive, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 52,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isActive
                    ? const Color(0xFFFF9500).withOpacity(0.15)
                    : const Color(0xFF2C2C2E),
                border: isActive
                    ? Border.all(color: const Color(0xFFFF9500), width: 1.5)
                    : null,
              ),
              child: Center(
                child: Text(
                  '${lens.zoomFactor == lens.zoomFactor.truncateToDouble() ? lens.zoomFactor.toInt() : lens.zoomFactor}×',
                  style: TextStyle(
                    color: isActive ? const Color(0xFFFF9500) : Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              lens.nameEn,
              style: TextStyle(
                color: isActive ? const Color(0xFFFF9500) : const Color(0xFF8E8E93),
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
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 曝光水平滑动条
// ─────────────────────────────────────────────────────────────────────────────
class _ExposureHorizontalSlider extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;
  final VoidCallback onReset;
  const _ExposureHorizontalSlider({required this.value, required this.onChanged, required this.onReset});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          GestureDetector(
            onTap: onReset,
            child: Container(
              width: 38, height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withAlpha(180),
                border: Border.all(color: Colors.white.withAlpha(60), width: 1),
              ),
              child: const Center(child: Icon(Icons.refresh, color: Colors.white, size: 20)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white.withAlpha(80),
                thumbColor: Colors.white,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10, elevation: 0),
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Slider(
                value: value.clamp(-2.0, 2.0),
                min: -2.0, max: 2.0,
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
// 白平衡控制面板
// ─────────────────────────────────────────────────────────────────────────────
class _WbControlPanel extends StatelessWidget {
  final int colorTempK;
  final String wbMode;
  final ValueChanged<int> onTempChanged;
  final ValueChanged<String> onPreset;
  const _WbControlPanel({required this.colorTempK, required this.wbMode, required this.onTempChanged, required this.onPreset});
  @override
  Widget build(BuildContext context) {
    final sliderVal = ((colorTempK - 1800) / (8000 - 1800)).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
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
                      colors: [Color(0xFFE8A05A), Color(0xFFB08AE0), Color(0xFF6B8FE8)],
                    ),
                  ),
                ),
                Positioned.fill(child: CustomPaint(painter: _WbTrackDotsPainter())),
                SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 0,
                    activeTrackColor: Colors.transparent,
                    inactiveTrackColor: Colors.transparent,
                    thumbColor: Colors.white,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10, elevation: 2),
                    overlayShape: SliderComponentShape.noOverlay,
                  ),
                  child: Slider(
                    value: sliderVal, min: 0.0, max: 1.0,
                    onChanged: (v) => onTempChanged((1800 + v * (8000 - 1800)).round()),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 42,
            child: Text('${colorTempK}K',
              style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 4),
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
        width: 30, height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isActive ? Colors.white : const Color(0xFF3A3A3C),
        ),
        child: Center(
          child: label != null
              ? Text(label!, style: TextStyle(
                  color: isActive ? const Color(0xFFE8A05A) : Colors.white70,
                  fontSize: 13, fontWeight: FontWeight.w700))
              : Icon(icon,
                  color: isActive ? const Color(0xFF1C1C1E) : Colors.white.withAlpha(180),
                  size: 16),
        ),
      ),
    );
  }
}

class _WbTrackDotsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withAlpha(80)..strokeWidth = 1.5..style = PaintingStyle.fill;
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
  final double value;
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
    for (int deg = -45; deg <= 45; deg++) {
      final x = centerX + (deg - value) * pixelsPerDegree;
      if (x < 0 || x > size.width) continue;
      final isMajor = deg % 5 == 0;
      final isZero = deg == 0;
      final tickH = isZero ? 20.0 : isMajor ? 14.0 : 8.0;
      final color = isZero ? const Color(0xFFFF8C00) : isMajor ? Colors.white54 : Colors.white24;
      canvas.drawLine(
        Offset(x, cy - tickH / 2), Offset(x, cy + tickH / 2),
        Paint()..color = color..strokeWidth = isZero ? 2.0 : 1.0..strokeCap = StrokeCap.round,
      );
      if (isMajor && deg != 0) {
        final tp = TextPainter(
          text: TextSpan(text: '${deg.abs()}', style: TextStyle(
            color: Colors.white24, fontSize: 8,
            fontFeatures: const [FontFeature.tabularFigures()],
          )),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x - tp.width / 2, cy + tickH / 2 + 2));
      }
    }
    final path = Path()
      ..moveTo(centerX - 5, 0)..lineTo(centerX + 5, 0)..lineTo(centerX, 7)..close();
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
        width: 34, height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isActive ? const Color(0xFFFF8C00).withOpacity(0.2) : Colors.white10,
        ),
        child: Icon(icon, color: isActive ? const Color(0xFFFF8C00) : Colors.white54, size: 18),
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
      child: Text(label, style: const TextStyle(color: Color(0xFFFF8C00), fontSize: 10)),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 滤镜行
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
                    width: 52, height: 52,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2A2A),
                      borderRadius: BorderRadius.circular(10),
                      border: isActive
                          ? Border.all(color: const Color(0xFFFF8C00), width: 2)
                          : Border.all(color: Colors.white12),
                    ),
                    child: Icon(Icons.filter_vintage_outlined,
                      color: isActive ? const Color(0xFFFF8C00) : Colors.white38, size: 24),
                  ),
                  const SizedBox(height: 4),
                  Text(f.nameEn, style: TextStyle(
                    color: isActive ? const Color(0xFFFF8C00) : Colors.white38, fontSize: 10),
                    maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
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
// 水印行
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
                    width: 52, height: 52,
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
                          : Container(width: 18, height: 18,
                              decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor)),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(wm.name, style: TextStyle(
                    color: isActive ? const Color(0xFFFF8C00) : Colors.white38, fontSize: 10),
                    maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
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
// 裁剪框 Overlay
// ─────────────────────────────────────────────────────────────────────────────
class _CropOverlay extends StatefulWidget {
  final Rect cropRect;
  final ValueChanged<Rect> onCropChanged;
  const _CropOverlay({required this.cropRect, required this.onCropChanged});
  @override
  State<_CropOverlay> createState() => _CropOverlayState();
}

enum _CropHandle { topLeft, topRight, bottomLeft, bottomRight, move }

class _CropOverlayState extends State<_CropOverlay> {
  _CropHandle? _activeHandle;
  Offset? _dragStart;
  Rect? _rectAtDragStart;

  _CropHandle? _hitTest(Offset pos, Size size) {
    final r = widget.cropRect;
    final tl = Offset(r.left * size.width, r.top * size.height);
    final tr = Offset(r.right * size.width, r.top * size.height);
    final bl = Offset(r.left * size.width, r.bottom * size.height);
    final br = Offset(r.right * size.width, r.bottom * size.height);
    const hitRadius = 24.0;
    if ((pos - tl).distance < hitRadius) return _CropHandle.topLeft;
    if ((pos - tr).distance < hitRadius) return _CropHandle.topRight;
    if ((pos - bl).distance < hitRadius) return _CropHandle.bottomLeft;
    if ((pos - br).distance < hitRadius) return _CropHandle.bottomRight;
    final rectPx = Rect.fromLTRB(tl.dx, tl.dy, br.dx, br.dy);
    if (rectPx.contains(pos)) return _CropHandle.move;
    return null;
  }

  void _onPanStart(DragStartDetails d, Size size) {
    _activeHandle = _hitTest(d.localPosition, size);
    _dragStart = d.localPosition;
    _rectAtDragStart = widget.cropRect;
  }

  void _onPanUpdate(DragUpdateDetails d, Size size) {
    if (_activeHandle == null || _dragStart == null || _rectAtDragStart == null) return;
    final dx = d.localPosition.dx / size.width - _dragStart!.dx / size.width;
    final dy = d.localPosition.dy / size.height - _dragStart!.dy / size.height;
    final r = _rectAtDragStart!;
    const minSize = 0.1;
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
          child: CustomPaint(size: size, painter: _CropPainter(rect: widget.cropRect)),
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
      rect.left * size.width, rect.top * size.height,
      rect.width * size.width, rect.height * size.height,
    );
    final dimPaint = Paint()..color = Colors.black.withAlpha(120);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, r.top), dimPaint);
    canvas.drawRect(Rect.fromLTWH(0, r.bottom, size.width, size.height - r.bottom), dimPaint);
    canvas.drawRect(Rect.fromLTWH(0, r.top, r.left, r.height), dimPaint);
    canvas.drawRect(Rect.fromLTWH(r.right, r.top, size.width - r.right, r.height), dimPaint);
    final borderPaint = Paint()..color = Colors.white..strokeWidth = 1.5..style = PaintingStyle.stroke;
    canvas.drawRect(r, borderPaint);
    final cornerPaint = Paint()..color = Colors.white..strokeWidth = 3..style = PaintingStyle.stroke..strokeCap = StrokeCap.round;
    const cl = 16.0;
    for (final corner in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
      final dx = corner == r.topLeft || corner == r.bottomLeft ? cl : -cl;
      final dy = corner == r.topLeft || corner == r.topRight ? cl : -cl;
      canvas.drawLine(corner, corner + Offset(dx, 0), cornerPaint);
      canvas.drawLine(corner, corner + Offset(0, dy), cornerPaint);
    }
  }
  @override
  bool shouldRepaint(_CropPainter old) => old.rect != rect;
}

// ─────────────────────────────────────────────────────────────────────────────
// 水印预览 Overlay
// ─────────────────────────────────────────────────────────────────────────────
class _WatermarkPreviewOverlay extends StatelessWidget {
  final WatermarkPreset watermark;
  final String? colorOverride;
  final String? positionOverride;
  final String? sizeOverride;
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
    return Align(
      alignment: align,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          watermark.name,
          style: TextStyle(color: textColor, fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}
