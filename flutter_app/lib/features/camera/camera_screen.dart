import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../models/camera_definition.dart';
import '../../providers/camera_state_provider.dart';
import '../../services/camera_service.dart';
import '../../services/image_processor.dart';
import '../../router/app_router.dart';

// ─── 相机主屏幕 ───────────────────────────────────────────────────────────────
class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});
  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen>
    with TickerProviderStateMixin {
  // ── 图库缩略图 ──
  Uint8List? _latestThumb;

  // ── 拍照动画 ──
  bool _showCaptureFlash = false;
  bool _showCameraSelector = false;

  // ── 计时器倒计时 ──
  int _countdown = 0;
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(cameraStateProvider.notifier).loadCameras();
      await ref.read(cameraServiceProvider.notifier).initCamera();
      await _loadLatestDazzPhoto();
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadLatestDazzPhoto() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.isAuth) return;
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      filterOption: FilterOptionGroup(
        orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
      ),
    );
    AssetPathEntity? dazzPath;
    for (final p in paths) {
      if (p.name.toUpperCase().contains('DAZZ')) {
        dazzPath = p;
        break;
      }
    }
    final targetPath = dazzPath ?? (paths.isNotEmpty ? paths.first : null);
    if (targetPath == null) return;
    final assets = await targetPath.getAssetListPaged(page: 0, size: 1);
    if (assets.isNotEmpty && mounted) {
      final thumb = await assets.first.thumbnailDataWithSize(
        const ThumbnailSize(120, 120),
      );
      setState(() {
        _latestThumb = thumb;
      });
    }
  }

  Future<void> _handleShutter() async {
    final camState = ref.read(cameraStateProvider);
    if (camState.isTakingPhoto) return;

    final timer = camState.timerSeconds;
    if (timer > 0) {
      await _startCountdown(timer);
    }

    HapticFeedback.mediumImpact();
    ref.read(cameraStateProvider.notifier).closePanel();

    final path = await ref.read(cameraStateProvider.notifier).takePhoto();
    if (path != null && mounted) {
      setState(() => _showCaptureFlash = true);
      await Future.delayed(const Duration(milliseconds: 120));
      if (mounted) setState(() => _showCaptureFlash = false);
      HapticFeedback.lightImpact();
      await _loadLatestDazzPhoto();
    }
  }

  Future<void> _startCountdown(int seconds) async {
    setState(() => _countdown = seconds);
    final completer = Completer<void>();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        completer.complete();
        return;
      }
      setState(() => _countdown--);
      if (_countdown <= 0) {
        t.cancel();
        completer.complete();
      }
    });
    await completer.future;
  }

  @override
  Widget build(BuildContext context) {
    final camState = ref.watch(cameraStateProvider);
    final cameraService = ref.watch(cameraServiceProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          _buildCameraPreview(camState, cameraService),
          if (camState.gridEnabled) _buildGrid(),
          Positioned(top: 0, left: 0, right: 0, child: _buildTopBar(camState)),
          Positioned(bottom: 0, left: 0, right: 0, child: _buildBottomArea(camState)),
          if (_showCameraSelector) _buildCameraSelectorOverlay(camState),
          if (_showCaptureFlash)
            Positioned.fill(child: Container(color: Colors.white.withOpacity(0.7))),
          if (_countdown > 0)
            Positioned.fill(
              child: Center(
                child: Text(
                  '$_countdown',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 120,
                    fontWeight: FontWeight.w100,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ─── 相机预览 ─────────────────────────────────────────────────────────────
  Widget _buildCameraPreview(CameraAppState camState, CameraState cameraService) {
    final ratio = camState.aspectRatio;
    final size = MediaQuery.of(context).size;

    double previewW, previewH;
    if (size.width / size.height < ratio) {
      previewW = size.width;
      previewH = size.width / ratio;
    } else {
      previewH = size.height;
      previewW = size.height * ratio;
    }

    Widget preview;
    if (cameraService.textureId != null) {
      preview = Texture(textureId: cameraService.textureId!);
    } else {
      preview = Container(
        color: const Color(0xFF0A0A0A),
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white30, strokeWidth: 1),
        ),
      );
    }

    // 预览颜色滤镜
    final film = camState.selectedFilm;
    final bm = camState.activeCamera?.baseModel;
    if (film != null && bm != null) {
      final filter = ImageProcessor.buildPreviewColorFilter(
        contrast: bm.color.contrast,
        saturation: bm.color.saturation,
        brightness: bm.color.brightness,
        temperatureShift: bm.color.temperature + film.rendering.temperatureShift,
        vignetteAmount: film.rendering.vignetteAmount,
        fadeAmount: film.rendering.fadeAmount,
      );
      preview = ColorFiltered(colorFilter: filter, child: preview);
    }

    // 暗角
    final vigAmt = (film?.rendering.vignetteAmount ?? 0.0) +
        (camState.selectedLens?.rendering.vignette ?? 0.0);
    if (vigAmt > 0.01) {
      preview = Stack(children: [
        preview,
        Positioned.fill(child: _VignetteOverlay(intensity: vigAmt.clamp(0.0, 1.0))),
      ]);
    }

    return Positioned.fill(
      child: Center(
        child: SizedBox(
          width: previewW,
          height: previewH,
          child: ClipRect(child: preview),
        ),
      ),
    );
  }

  Widget _buildGrid() {
    return Positioned.fill(
      child: IgnorePointer(child: CustomPaint(painter: _GridPainter())),
    );
  }

  // ─── 顶部工具栏 ───────────────────────────────────────────────────────────
  Widget _buildTopBar(CameraAppState camState) {
    final caps = camState.activeCamera?.uiCapabilities;
    return SafeArea(
      child: Container(
        height: 50,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            if (caps?.showGridButton ?? true)
              _TopBtn(
                icon: Icons.grid_on_outlined,
                active: camState.gridEnabled,
                onTap: () => ref.read(cameraStateProvider.notifier).toggleGrid(),
              ),
            const SizedBox(width: 4),
            if (caps?.showFlashButton ?? true)
              _TopBtn(
                icon: _flashIcon(camState.flashMode),
                active: camState.flashMode != 'off',
                onTap: () => ref.read(cameraStateProvider.notifier).cycleFlash(),
              ),
            const SizedBox(width: 4),
            if (caps?.showTimerButton ?? true)
              _TopBtn(
                icon: Icons.timer_outlined,
                active: camState.timerSeconds > 0,
                label: camState.timerSeconds > 0 ? '${camState.timerSeconds}s' : null,
                onTap: () => ref.read(cameraStateProvider.notifier).cycleTimer(),
              ),
            const Spacer(),
            _ExposureSlider(
              value: camState.exposureValue,
              onChanged: (v) => ref.read(cameraStateProvider.notifier).setExposure(v),
            ),
            const SizedBox(width: 8),
            _TopBtn(
              icon: Icons.settings_outlined,
              onTap: () => context.push(AppRoutes.settings),
            ),
          ],
        ),
      ),
    );
  }

  IconData _flashIcon(String mode) {
    switch (mode) {
      case 'on': return Icons.flash_on;
      case 'auto': return Icons.flash_auto;
      default: return Icons.flash_off;
    }
  }

  // ─── 底部区域 ─────────────────────────────────────────────────────────────
  Widget _buildBottomArea(CameraAppState camState) {
    return Container(
      color: Colors.black,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (camState.activePanel != null) _buildOptionPanel(camState),
            _buildFilmRow(camState),
            _buildQuickActions(camState),
            _buildShutterRow(camState),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ─── 选项面板 ─────────────────────────────────────────────────────────────
  Widget _buildOptionPanel(CameraAppState camState) {
    final panel = camState.activePanel;
    final sel = camState.selection;
    if (sel == null || panel == null) return const SizedBox.shrink();

    Widget content;
    switch (panel) {
      case 'film': content = _buildFilmPanel(sel); break;
      case 'lens': content = _buildLensPanel(sel); break;
      case 'paper': content = _buildPaperPanel(sel); break;
      case 'ratio': content = _buildRatioPanel(sel); break;
      case 'watermark': content = _buildWatermarkPanel(sel); break;
      default: return const SizedBox.shrink();
    }

    return Container(
      height: 90,
      color: const Color(0xFF111111),
      child: content,
    );
  }

  Widget _buildFilmPanel(CameraSelectionState sel) {
    final items = sel.camera.optionGroups.films;
    return _OptionList(
      count: items.length,
      builder: (i) {
        final item = items[i];
        final active = sel.selectedFilm?.id == item.id;
        return _OptionChip(
              icon: Icons.filter_vintage,
              label: item.name,
              active: active,
              onTap: () => ref.read(cameraStateProvider.notifier).selectFilm(item),
        );
      },
    );
  }

  Widget _buildLensPanel(CameraSelectionState sel) {
    final items = sel.camera.optionGroups.lenses;
    return _OptionList(
      count: items.length,
      builder: (i) {
        final item = items[i];
        final active = sel.selectedLens?.id == item.id;
        return _OptionChip(
          icon: Icons.lens_outlined,
          label: item.name,
          active: active,
          onTap: () => ref.read(cameraStateProvider.notifier).selectLens(item),
        );
      },
    );
  }

  Widget _buildPaperPanel(CameraSelectionState sel) {
    final items = sel.camera.optionGroups.papers;
    return _OptionList(
      count: items.length,
      builder: (i) {
        final item = items[i];
        final active = sel.selectedPaper?.id == item.id;
        return _OptionChip(
          icon: Icons.crop_portrait,
          label: item.name,
          active: active,
          onTap: () => ref.read(cameraStateProvider.notifier).selectPaper(item),
        );
      },
    );
  }

  Widget _buildRatioPanel(CameraSelectionState sel) {
    final items = sel.camera.optionGroups.ratios;
    return _OptionList(
      count: items.length,
      builder: (i) {
        final item = items[i];
        final active = sel.selectedRatio?.id == item.id;
        return GestureDetector(
          onTap: () => ref.read(cameraStateProvider.notifier).selectRatio(item),
          child: Container(
            margin: const EdgeInsets.only(right: 10),
            width: 64,
            decoration: BoxDecoration(
              color: active ? const Color(0xFFFF8A3D) : const Color(0xFF222222),
              borderRadius: BorderRadius.circular(8),
              border: active ? null : Border.all(color: Colors.white24, width: 0.5),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _RatioIcon(ratio: item.value, color: active ? Colors.black : Colors.white70),
                const SizedBox(height: 4),
                Text(
                  item.name,
                  style: TextStyle(
                    color: active ? Colors.black : Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildWatermarkPanel(CameraSelectionState sel) {
    final items = sel.camera.optionGroups.watermarks;
    return _OptionList(
      count: items.length,
      builder: (i) {
        final item = items[i];
        final active = sel.selectedWatermark?.id == item.id;
        return _OptionChip(
          icon: item.isNone ? Icons.block : Icons.text_fields,
          label: item.name,
          active: active,
          onTap: () => ref.read(cameraStateProvider.notifier).selectWatermark(item),
        );
      },
    );
  }

  // ─── 胶卷/相机名称行 ──────────────────────────────────────────────────────
  Widget _buildFilmRow(CameraAppState camState) {
    final camera = camState.activeCamera;
    final film = camState.selectedFilm;
    if (camera == null) return const SizedBox(height: 32);
    return Container(
      height: 32,
      color: Colors.black,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(camera.name,
              style: const TextStyle(color: Colors.white54, fontSize: 11, letterSpacing: 1.2)),
          if (film != null) ...[
            const Text('  ·  ', style: TextStyle(color: Colors.white30, fontSize: 11)),
            Text(film.name, style: const TextStyle(color: Colors.white38, fontSize: 11)),
          ],
        ],
      ),
    );
  }

  // ─── 快捷操作栏 ───────────────────────────────────────────────────────────
  Widget _buildQuickActions(CameraAppState camState) {
    final caps = camState.activeCamera?.uiCapabilities;
    final sel = camState.selection;

    final buttons = <Widget>[];

    if (caps?.showWatermarkSelector ?? true) {
      buttons.add(_QuickBtn(
        label: '水印',
        icon: Icons.text_fields,
        active: camState.activePanel == 'watermark',
        badge: sel?.selectedWatermark?.isNone == false ? sel?.selectedWatermark?.name : null,
        onTap: () => ref.read(cameraStateProvider.notifier).togglePanel('watermark'),
      ));
    }
    if (caps?.showPaperSelector ?? false) {
      buttons.add(_QuickBtn(
        label: '相纸',
        icon: Icons.crop_portrait,
        active: camState.activePanel == 'paper',
        badge: sel?.selectedPaper?.name,
        onTap: () => ref.read(cameraStateProvider.notifier).togglePanel('paper'),
      ));
    }
    if (caps?.showFilmSelector ?? false) {
      buttons.add(_QuickBtn(
        label: '交卷',
        icon: Icons.filter_vintage,
        active: camState.activePanel == 'film',
        badge: sel?.selectedFilm?.name,
        onTap: () => ref.read(cameraStateProvider.notifier).togglePanel('film'),
      ));
    }
    if (caps?.showRatioSelector ?? true) {
      buttons.add(_QuickBtn(
        label: camState.ratioValue,
        icon: Icons.crop,
        active: camState.activePanel == 'ratio',
        onTap: () => ref.read(cameraStateProvider.notifier).togglePanel('ratio'),
      ));
    }
    if (caps?.showLensSelector ?? false) {
      buttons.add(_QuickBtn(
        label: '镜头',
        icon: Icons.lens_outlined,
        active: camState.activePanel == 'lens',
        badge: sel?.selectedLens?.name,
        onTap: () => ref.read(cameraStateProvider.notifier).togglePanel('lens'),
      ));
    }

    if (buttons.isEmpty) return const SizedBox(height: 52);

    return Container(
      height: 52,
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: buttons,
      ),
    );
  }

  // ─── 快门行 ───────────────────────────────────────────────────────────────
  Widget _buildShutterRow(CameraAppState camState) {
    return Container(
      height: 90,
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 图库缩略图
          GestureDetector(
            onTap: () => context.push(AppRoutes.gallery),
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white30, width: 1),
                color: Colors.white10,
              ),
              child: _latestThumb != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(7),
                      child: Image.memory(_latestThumb!, fit: BoxFit.cover),
                    )
                  : const Icon(Icons.photo_library_outlined, color: Colors.white38, size: 24),
            ),
          ),

          // 快门
          GestureDetector(
            onTap: _handleShutter,
            child: _ShutterButton(isTaking: camState.isTakingPhoto),
          ),

          // 切换前后摄
          GestureDetector(
            onTap: () => ref.read(cameraStateProvider.notifier).switchLens(),
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white12,
                border: Border.all(color: Colors.white24, width: 0.5),
              ),
              child: Icon(
                camState.isFrontCamera ? Icons.camera_front : Icons.camera_rear,
                color: Colors.white,
                size: 26,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── 相机选择器全屏覆盖 ───────────────────────────────────────────────────
  Widget _buildCameraSelectorOverlay(CameraAppState camState) {
    return Positioned.fill(
      child: GestureDetector(
        onTap: () => setState(() => _showCameraSelector = false),
        child: Container(
          color: Colors.black87,
          child: SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const SizedBox(width: 48),
                    const Text('SELECT CAMERA',
                        style: TextStyle(color: Colors.white54, fontSize: 11, letterSpacing: 2)),
                    GestureDetector(
                      onTap: () => setState(() => _showCameraSelector = false),
                      child: const Padding(
                        padding: EdgeInsets.all(12),
                        child: Icon(Icons.close, color: Colors.white54, size: 20),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      childAspectRatio: 0.85,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                    ),
                    itemCount: camState.cameras.length,
                    itemBuilder: (_, i) {
                      final cam = camState.cameras[i];
                      final isActive = camState.activeCamera?.id == cam.id;
                      return GestureDetector(
                        onTap: () {
                          ref.read(cameraStateProvider.notifier).selectCamera(cam);
                          setState(() => _showCameraSelector = false);
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: isActive ? const Color(0xFFFF8A3D) : const Color(0xFF1A1A1A),
                            borderRadius: BorderRadius.circular(12),
                            border: isActive ? null : Border.all(color: Colors.white12, width: 0.5),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                _categoryIcon(cam.category),
                                color: isActive ? Colors.black : Colors.white60,
                                size: 32,
                              ),
                            const SizedBox(height: 8),
                            Text(
                              cam.name,
                                style: TextStyle(
                                  color: isActive ? Colors.black : Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                                textAlign: TextAlign.center,
                                maxLines: 2,
                              ),
                              if (cam.isPremium)
                                Container(
                                  margin: const EdgeInsets.only(top: 4),
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: Colors.amber,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text('PRO',
                                      style: TextStyle(
                                          color: Colors.black, fontSize: 8, fontWeight: FontWeight.w700)),
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
          ),
        ),
      ),
    );
  }

  IconData _categoryIcon(String category) {
    switch (category) {
      case 'film': return Icons.filter_vintage;
      case 'instant': return Icons.crop_portrait;
      case 'video': return Icons.videocam_outlined;
      case 'disposable': return Icons.camera_alt_outlined;
      default: return Icons.camera;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 子组件
// ─────────────────────────────────────────────────────────────────────────────

class _OptionList extends StatelessWidget {
  final int count;
  final Widget Function(int) builder;
  const _OptionList({required this.count, required this.builder});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      itemCount: count,
      itemBuilder: (_, i) => builder(i),
    );
  }
}

class _OptionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _OptionChip({required this.icon, required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 10),
        width: 64,
        decoration: BoxDecoration(
          color: active ? const Color(0xFFFF8A3D) : const Color(0xFF222222),
          borderRadius: BorderRadius.circular(8),
          border: active ? null : Border.all(color: Colors.white24, width: 0.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: active ? Colors.black : Colors.white70, size: 20),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: active ? Colors.black : Colors.white70,
                fontSize: 10,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBtn extends StatelessWidget {
  final IconData icon;
  final bool active;
  final String? label;
  final VoidCallback onTap;
  const _TopBtn({required this.icon, this.active = false, this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: active ? Colors.white.withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: label != null
            ? Center(
                child: Text(label!,
                    style: TextStyle(
                        color: active ? Colors.white : Colors.white60,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)))
            : Icon(icon, color: active ? Colors.white : Colors.white60, size: 20),
      ),
    );
  }
}

class _ExposureSlider extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;
  const _ExposureSlider({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 100,
      child: Row(
        children: [
          const Icon(Icons.wb_sunny_outlined, color: Colors.white38, size: 14),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 1.5,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: SliderComponentShape.noOverlay,
                activeTrackColor: Colors.white70,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
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

class _QuickBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final String? badge;
  final VoidCallback onTap;
  const _QuickBtn({required this.label, required this.icon, this.active = false, this.badge, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 40,
            height: 32,
            decoration: BoxDecoration(
              color: active ? const Color(0xFFFF8A3D).withOpacity(0.15) : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon, color: active ? const Color(0xFFFF8A3D) : Colors.white54, size: 18),
          ),
          Text(
            badge ?? label,
            style: TextStyle(
              color: active ? const Color(0xFFFF8A3D) : Colors.white38,
              fontSize: 9,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  final bool isTaking;
  const _ShutterButton({this.isTaking = false});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 100),
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isTaking ? Colors.white60 : Colors.white,
        boxShadow: [BoxShadow(color: Colors.white.withOpacity(0.3), blurRadius: 12, spreadRadius: 2)],
      ),
      child: Center(
        child: Container(
          width: 62,
          height: 62,
          decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.black),
          child: Center(
            child: Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isTaking ? Colors.white60 : Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RatioIcon extends StatelessWidget {
  final String ratio;
  final Color color;
  const _RatioIcon({required this.ratio, required this.color});

  @override
  Widget build(BuildContext context) {
    double w = 20, h = 15;
    switch (ratio) {
      case '1:1': w = 18; h = 18; break;
      case '16:9': w = 24; h = 13.5; break;
      case '3:2': w = 21; h = 14; break;
      default: w = 20; h = 15;
    }
    return Container(
      width: w, height: h,
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 1.5),
        borderRadius: BorderRadius.circular(1.5),
      ),
    );
  }
}

class _VignetteOverlay extends StatelessWidget {
  final double intensity;
  const _VignetteOverlay({required this.intensity});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _VignettePainter(intensity: intensity));
  }
}

class _VignettePainter extends CustomPainter {
  final double intensity;
  const _VignettePainter({required this.intensity});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final gradient = RadialGradient(
      center: Alignment.center,
      radius: 0.85,
      colors: [Colors.transparent, Colors.black.withOpacity(intensity * 0.7)],
      stops: const [0.5, 1.0],
    );
    canvas.drawRect(rect, Paint()..shader = gradient.createShader(rect));
  }

  @override
  bool shouldRepaint(_VignettePainter old) => old.intensity != intensity;
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withOpacity(0.25)..strokeWidth = 0.5;
    canvas.drawLine(Offset(size.width / 3, 0), Offset(size.width / 3, size.height), paint);
    canvas.drawLine(Offset(size.width * 2 / 3, 0), Offset(size.width * 2 / 3, size.height), paint);
    canvas.drawLine(Offset(0, size.height / 3), Offset(size.width, size.height / 3), paint);
    canvas.drawLine(Offset(0, size.height * 2 / 3), Offset(size.width, size.height * 2 / 3), paint);
  }

  @override
  bool shouldRepaint(_GridPainter _) => false;
}
