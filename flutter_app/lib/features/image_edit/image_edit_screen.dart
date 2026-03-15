// ImageEditScreen — 导入图片编辑页
// 功能：裁剪/旋转/水平调整 + 相机滤镜/水印/相框/比例实时预览 → 保存到成片
//
// 设计哲学：Darkroom Aesthetics — 纯黑背景，白色控件，复用相机页所有效果逻辑
// 关键复用：
//   - CameraAppState (cameraAppProvider) 管理相机/滤镜/水印/相框/比例选择
//   - CapturePipeline.process() 处理最终输出
//   - PreviewFilterWidget.buildColorMatrix() 颜色矩阵
//   - showCameraConfigSheet() 底部相机配置菜单

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

// ─────────────────────────────────────────────────────────────────────────────
// 入口：从相机页导入图片按钮调用
// ─────────────────────────────────────────────────────────────────────────────

/// 打开系统相册选择一张图片，然后跳转到编辑页
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
  int _rotation = 0;          // 旋转：0/90/180/270 度
  double _skew = 0.0;         // 水平调整（倾斜）：-0.3 ~ 0.3 rad
  bool _flipH = false;        // 水平翻转
  bool _isCropMode = false;   // 是否处于裁剪模式

  // 裁剪区域（归一化 0.0~1.0）
  Rect _cropRect = const Rect.fromLTWH(0, 0, 1, 1);

  // ── 工具栏 Tab ────────────────────────────────────────────────────────────
  _EditTab _activeTab = _EditTab.adjust;

  // ── 图片加载 ──────────────────────────────────────────────────────────────
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    // 预加载图片以确认可读
    _preloadImage();
  }

  Future<void> _preloadImage() async {
    try {
      await File(widget.imagePath).readAsBytes();
      if (mounted) setState(() => _isLoading = false);
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── 旋转 ──────────────────────────────────────────────────────────────────
  void _rotate90() => setState(() => _rotation = (_rotation + 90) % 360);

  // ── 翻转 ──────────────────────────────────────────────────────────────────
  void _flipHorizontal() => setState(() => _flipH = !_flipH);

  // ── 保存 ──────────────────────────────────────────────────────────────────
  Future<void> _save() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

    try {
      final st = ref.read(cameraAppProvider);
      final camera = st.camera;
      if (camera == null) {
        _showSnack('请先选择相机');
        setState(() => _isSaving = false);
        return;
      }

      // 1. 将旋转/翻转/裁剪应用到图片
      final transformedBytes = await _applyTransforms();
      if (transformedBytes == null) {
        _showSnack('图片处理失败');
        setState(() => _isSaving = false);
        return;
      }

      // 写入临时文件
      final tmpPath = '${Directory.systemTemp.path}/dazz_edit_${DateTime.now().millisecondsSinceEpoch}.png';
      await File(tmpPath).writeAsBytes(transformedBytes);

      // 2. 通过 CapturePipeline 应用滤镜/水印/相框/比例
      final pipeline = CapturePipeline(camera: camera);
      final processed = await pipeline.process(
        imagePath: tmpPath,
        selectedRatioId: st.activeRatioId ?? '',
        selectedFrameId: st.activeFrameId ?? '',
        selectedWatermarkId: st.activeWatermarkId ?? '',
        frameBackgroundColor: st.frameBackgroundColor,
        watermarkColorOverride: st.watermarkColor,
        watermarkPositionOverride: st.watermarkPosition,
        watermarkSizeOverride: st.watermarkSize,
        watermarkDirectionOverride: st.watermarkDirection,
        renderParams: st.renderParams,
      );

      final finalBytes = processed ?? transformedBytes;
      await File(tmpPath).writeAsBytes(finalBytes);

      // 3. 保存到相册
      final perm = await PhotoManager.requestPermissionExtend();
      if (!perm.hasAccess) {
        _showSnack('需要相册权限才能保存');
        setState(() => _isSaving = false);
        return;
      }

      final saved = await PhotoManager.editor.saveImageWithPath(
        tmpPath,
        title: 'DAZZ_${DateTime.now().millisecondsSinceEpoch}',
      );

      // 清理临时文件
      try { await File(tmpPath).delete(); } catch (_) {}

      if (saved != null && mounted) {
        HapticFeedback.mediumImpact();
        _showSnack('已保存到相册');
        await Future.delayed(const Duration(milliseconds: 800));
        if (mounted) Navigator.of(context).pop();
      } else {
        _showSnack('保存失败，请重试');
      }
    } catch (e) {
      debugPrint('[ImageEditScreen] save error: $e');
      _showSnack('保存失败');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// 将旋转/翻转/裁剪应用到图片，返回 PNG bytes
  Future<Uint8List?> _applyTransforms() async {
    try {
      final bytes = await File(widget.imagePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final src = frame.image;

      final srcW = src.width.toDouble();
      final srcH = src.height.toDouble();

      // 裁剪区域（像素）
      final cropX = _cropRect.left * srcW;
      final cropY = _cropRect.top * srcH;
      final cropW = _cropRect.width * srcW;
      final cropH = _cropRect.height * srcH;

      // 旋转后的输出尺寸
      final isRotated90or270 = _rotation == 90 || _rotation == 270;
      final outW = (isRotated90or270 ? cropH : cropW).toInt();
      final outH = (isRotated90or270 ? cropW : cropH).toInt();

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);

      canvas.translate(outW / 2.0, outH / 2.0);
      canvas.rotate(_rotation * math.pi / 180.0);
      if (_flipH) canvas.scale(-1.0, 1.0);
      if (_skew.abs() > 0.001) canvas.skew(_skew, 0.0);

      final drawW = isRotated90or270 ? cropH : cropW;
      final drawH = isRotated90or270 ? cropW : cropH;

      canvas.drawImageRect(
        src,
        Rect.fromLTWH(cropX, cropY, cropW, cropH),
        Rect.fromLTWH(-drawW / 2.0, -drawH / 2.0, drawW, drawH),
        Paint()..filterQuality = FilterQuality.high,
      );

      final picture = recorder.endRecording();
      final outputImage = await picture.toImage(outW, outH);
      final byteData = await outputImage.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
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

            // ── 编辑工具栏 ──────────────────────────────────────────────────
            _buildEditToolbar(),

            // ── 底部相机配置入口 ────────────────────────────────────────────
            _buildBottomConfigEntry(),
          ],
        ),
      ),
    );
  }

  // ── 顶部导航栏 ────────────────────────────────────────────────────────────
  Widget _buildTopBar() {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: const Text(
              '取消',
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
          ),
          const Spacer(),
          const Text(
            '编辑',
            style: TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: _isSaving ? null : _save,
            child: _isSaving
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2,
                    ),
                  )
                : const Text(
                    '保存',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
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

    return Center(
      child: AspectRatio(
        aspectRatio: st.previewAspectRatio,
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Stack(
              fit: StackFit.expand,
              children: [
                // Layer 1: 图片（带变换 + 颜色滤镜）
                ClipRect(
                  child: _buildTransformedImage(st, constraints),
                ),

                // Layer 2: 相框预览 overlay
                if (st.activeFrame != null)
                  IgnorePointer(
                    child: _FramePreviewOverlay(
                      frame: st.activeFrame!,
                      ratioId: st.activeRatioId ?? '',
                    ),
                  ),

                // Layer 3: 水印预览 overlay
                if (st.activeWatermark != null && !st.activeWatermark!.isNone)
                  IgnorePointer(
                    child: _WatermarkPreviewOverlay(
                      watermark: st.activeWatermark!,
                      colorOverride: st.watermarkColor,
                      positionOverride: st.watermarkPosition,
                      sizeOverride: st.watermarkSize,
                      directionOverride: st.watermarkDirection,
                    ),
                  ),

                // Layer 4: 裁剪框（裁剪模式下显示）
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
    );
  }

  Widget _buildTransformedImage(CameraAppState st, BoxConstraints constraints) {
    final params = st.renderParams ?? const renderer_lib.PreviewRenderParams();
    final colorMatrix = renderer_lib.computeColorMatrix(params);

    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..rotateZ(_rotation * math.pi / 180.0)
        ..scale(_flipH ? -1.0 : 1.0, 1.0)
        ..setEntry(0, 1, _skew),
      child: ColorFiltered(
        colorFilter: ColorFilter.matrix(colorMatrix),
        child: Image.file(
          File(widget.imagePath),
          fit: BoxFit.cover,
          width: constraints.maxWidth,
          height: constraints.maxHeight,
        ),
      ),
    );
  }

  // ── 编辑工具栏 ────────────────────────────────────────────────────────────
  Widget _buildEditToolbar() {
    return Container(
      color: Colors.black,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildEditTabRow(),
          _buildEditTabContent(),
        ],
      ),
    );
  }

  Widget _buildEditTabRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: _EditTab.values.map((tab) {
          final isActive = _activeTab == tab;
          return GestureDetector(
            onTap: () => setState(() => _activeTab = tab),
            child: Padding(
              padding: const EdgeInsets.only(right: 24),
              child: Text(
                tab.label,
                style: TextStyle(
                  color: isActive ? Colors.white : Colors.white38,
                  fontSize: 14,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildEditTabContent() {
    switch (_activeTab) {
      case _EditTab.adjust:
        return _buildAdjustTools();
      case _EditTab.crop:
        return _buildCropTools();
    }
  }

  // 调整工具：旋转/翻转/水平
  Widget _buildAdjustTools() {
    return SizedBox(
      height: 72,
      child: Row(
        children: [
          const SizedBox(width: 16),
          _EditToolBtn(
            icon: Icons.rotate_90_degrees_ccw_outlined,
            label: '旋转',
            onTap: _rotate90,
          ),
          const SizedBox(width: 24),
          _EditToolBtn(
            icon: Icons.flip_outlined,
            label: '翻转',
            onTap: _flipHorizontal,
          ),
          const SizedBox(width: 16),
          // 水平调整滑条
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    '水平调整',
                    style: TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                  const SizedBox(height: 4),
                  SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 2,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: Colors.white,
                      overlayColor: Colors.white24,
                    ),
                    child: Slider(
                      value: _skew,
                      min: -0.3,
                      max: 0.3,
                      onChanged: (v) => setState(() => _skew = v),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
    );
  }

  // 裁剪工具
  Widget _buildCropTools() {
    return SizedBox(
      height: 72,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _EditToolBtn(
            icon: _isCropMode ? Icons.check_circle_outline : Icons.crop_outlined,
            label: _isCropMode ? '确认裁剪' : '裁剪',
            isActive: _isCropMode,
            onTap: () => setState(() => _isCropMode = !_isCropMode),
          ),
          _EditToolBtn(
            icon: Icons.restart_alt_outlined,
            label: '重置',
            onTap: () => setState(() {
              _cropRect = const Rect.fromLTWH(0, 0, 1, 1);
              _isCropMode = false;
            }),
          ),
        ],
      ),
    );
  }

  // ── 底部相机配置入口 ──────────────────────────────────────────────────────
  Widget _buildBottomConfigEntry() {
    return Container(
      color: Colors.black,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(height: 1, color: Colors.white12),
          GestureDetector(
            onTap: () => showCameraConfigSheet(context),
            child: Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: const Row(
                children: [
                  Icon(Icons.camera_alt_outlined, color: Colors.white54, size: 20),
                  SizedBox(width: 10),
                  Text(
                    '相机 / 滤镜 / 水印 / 相框 / 比例',
                    style: TextStyle(color: Colors.white54, fontSize: 14),
                  ),
                  Spacer(),
                  Icon(Icons.keyboard_arrow_up, color: Colors.white38, size: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 相框预览 Overlay
// ─────────────────────────────────────────────────────────────────────────────

class _FramePreviewOverlay extends StatelessWidget {
  final FrameDefinition frame;
  final String ratioId;

  const _FramePreviewOverlay({required this.frame, required this.ratioId});

  @override
  Widget build(BuildContext context) {
    final asset = frame.assetForRatio(ratioId);
    if (asset == null || asset.isEmpty) return const SizedBox.shrink();
    return Positioned.fill(
      child: Image.asset(
        asset,
        fit: BoxFit.fill,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 水印预览 Overlay（与 camera_screen.dart 的实现一致）
// ─────────────────────────────────────────────────────────────────────────────

class _WatermarkPreviewOverlay extends StatelessWidget {
  final WatermarkPreset watermark;
  final String? colorOverride;
  final String? positionOverride;
  final String? sizeOverride;
  final String? directionOverride;

  const _WatermarkPreviewOverlay({
    required this.watermark,
    this.colorOverride,
    this.positionOverride,
    this.sizeOverride,
    this.directionOverride,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: CustomPaint(
        painter: _WatermarkPainter(
          watermark: watermark,
          colorOverride: colorOverride,
          positionOverride: positionOverride,
          sizeOverride: sizeOverride,
          directionOverride: directionOverride,
        ),
      ),
    );
  }
}

class _WatermarkPainter extends CustomPainter {
  final WatermarkPreset watermark;
  final String? colorOverride;
  final String? positionOverride;
  final String? sizeOverride;
  final String? directionOverride;

  _WatermarkPainter({
    required this.watermark,
    this.colorOverride,
    this.positionOverride,
    this.sizeOverride,
    this.directionOverride,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final now = DateTime.now();
    final datePart =
        "${now.year.toString().substring(2)}.${now.month.toString().padLeft(2, '0')}.${now.day.toString().padLeft(2, '0')}";
    final timePart =
        "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
    final text = watermark.id.contains('datetime') ? "$datePart $timePart" : datePart;

    Color textColor = const Color(0xFFFF8C00);
    final colorSrc = colorOverride ?? watermark.color;
    if (colorSrc != null && colorSrc.isNotEmpty) {
      try {
        final hex = colorSrc.replaceAll('#', '');
        textColor = Color(int.parse('FF$hex', radix: 16));
      } catch (_) {}
    }

    double baseFontSize;
      switch (sizeOverride) {
      case 'small':  baseFontSize = size.width * 0.028; break;
      case 'large':  baseFontSize = size.width * 0.055; break;
      default:       baseFontSize = size.width * 0.038; break;
    }

    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: textColor,
          fontSize: baseFontSize,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();

    final pos = positionOverride ?? watermark.position ?? 'bottom_right';
    const margin = 16.0;
    double dx, dy;
    switch (pos) {
      case 'bottom_left':   dx = margin; dy = size.height - textPainter.height - margin; break;
      case 'top_right':     dx = size.width - textPainter.width - margin; dy = margin; break;
      case 'top_left':      dx = margin; dy = margin; break;
      case 'bottom_center': dx = (size.width - textPainter.width) / 2; dy = size.height - textPainter.height - margin; break;
      case 'top_center':    dx = (size.width - textPainter.width) / 2; dy = margin; break;
      default:              dx = size.width - textPainter.width - margin; dy = size.height - textPainter.height - margin; break;
    }

    final dir = directionOverride ?? 'horizontal';
    if (dir == 'vertical') {
      canvas.save();
      canvas.translate(dx + textPainter.height / 2, dy + textPainter.width / 2);
      canvas.rotate(-math.pi / 2);
      textPainter.paint(canvas, Offset(-textPainter.width / 2, -textPainter.height / 2));
      canvas.restore();
    } else {
      textPainter.paint(canvas, Offset(dx, dy));
    }
  }

  @override
  bool shouldRepaint(_WatermarkPainter old) =>
      old.watermark != watermark ||
      old.colorOverride != colorOverride ||
      old.positionOverride != positionOverride ||
      old.sizeOverride != sizeOverride ||
      old.directionOverride != directionOverride;
}

// ─────────────────────────────────────────────────────────────────────────────
// 裁剪 Overlay
// ─────────────────────────────────────────────────────────────────────────────

class _CropOverlay extends StatefulWidget {
  final Rect cropRect;
  final ValueChanged<Rect> onCropChanged;

  const _CropOverlay({required this.cropRect, required this.onCropChanged});

  @override
  State<_CropOverlay> createState() => _CropOverlayState();
}

class _CropOverlayState extends State<_CropOverlay> {
  late Rect _rect;
  _CropHandle? _activeHandle;
  Offset? _dragStart;
  Rect? _rectAtDragStart;

  @override
  void initState() {
    super.initState();
    _rect = widget.cropRect;
  }

  @override
  void didUpdateWidget(_CropOverlay old) {
    super.didUpdateWidget(old);
    if (old.cropRect != widget.cropRect) _rect = widget.cropRect;
  }

  _CropHandle? _hitTest(Offset pos, Size size) {
    final r = Rect.fromLTWH(
      _rect.left * size.width,
      _rect.top * size.height,
      _rect.width * size.width,
      _rect.height * size.height,
    );
    const handleSize = 28.0;
    final corners = {
      _CropHandle.topLeft: r.topLeft,
      _CropHandle.topRight: r.topRight,
      _CropHandle.bottomLeft: r.bottomLeft,
      _CropHandle.bottomRight: r.bottomRight,
    };
    for (final entry in corners.entries) {
      if ((pos - entry.value).distance < handleSize) return entry.key;
    }
    if (r.contains(pos)) return _CropHandle.move;
    return null;
  }

  void _onPanStart(DragStartDetails d, Size size) {
    _activeHandle = _hitTest(d.localPosition, size);
    _dragStart = d.localPosition;
    _rectAtDragStart = _rect;
  }

  void _onPanUpdate(DragUpdateDetails d, Size size) {
    if (_activeHandle == null || _dragStart == null || _rectAtDragStart == null) return;
    final delta = d.localPosition - _dragStart!;
    final dx = delta.dx / size.width;
    final dy = delta.dy / size.height;
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
    setState(() => _rect = newRect);
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
            painter: _CropPainter(rect: _rect),
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

    // 暗色遮罩（裁剪框外）
    final dimPaint = Paint()..color = Colors.black.withAlpha(130);
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRect(r)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, dimPaint);

    // 裁剪框边线
    canvas.drawRect(
      r,
      Paint()
        ..color = Colors.white
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );

    // 三等分网格线
    final gridPaint = Paint()
      ..color = Colors.white38
      ..strokeWidth = 0.5;
    for (int i = 1; i < 3; i++) {
      final x = r.left + r.width * i / 3;
      final y = r.top + r.height * i / 3;
      canvas.drawLine(Offset(x, r.top), Offset(x, r.bottom), gridPaint);
      canvas.drawLine(Offset(r.left, y), Offset(r.right, y), gridPaint);
    }

    // 四角把手
    final hp = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    const hl = 16.0;
    // 左上
    canvas.drawLine(r.topLeft, r.topLeft + const Offset(hl, 0), hp);
    canvas.drawLine(r.topLeft, r.topLeft + const Offset(0, hl), hp);
    // 右上
    canvas.drawLine(r.topRight, r.topRight + const Offset(-hl, 0), hp);
    canvas.drawLine(r.topRight, r.topRight + const Offset(0, hl), hp);
    // 左下
    canvas.drawLine(r.bottomLeft, r.bottomLeft + const Offset(hl, 0), hp);
    canvas.drawLine(r.bottomLeft, r.bottomLeft + const Offset(0, -hl), hp);
    // 右下
    canvas.drawLine(r.bottomRight, r.bottomRight + const Offset(-hl, 0), hp);
    canvas.drawLine(r.bottomRight, r.bottomRight + const Offset(0, -hl), hp);
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.rect != rect;
}

// ─────────────────────────────────────────────────────────────────────────────
// 辅助类型
// ─────────────────────────────────────────────────────────────────────────────

enum _EditTab {
  adjust('调整'),
  crop('裁剪');

  final String label;
  const _EditTab(this.label);
}

enum _CropHandle { topLeft, topRight, bottomLeft, bottomRight, move }

// ─────────────────────────────────────────────────────────────────────────────
// 编辑工具按钮
// ─────────────────────────────────────────────────────────────────────────────

class _EditToolBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isActive;

  const _EditToolBtn({
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
          Icon(icon, color: isActive ? Colors.white : Colors.white70, size: 24),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: isActive ? Colors.white : Colors.white54,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
