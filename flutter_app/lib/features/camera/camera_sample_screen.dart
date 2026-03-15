// camera_sample_screen.dart
// 相机样片页面：展示指定相机的样张图片，支持左右滑动切换
// 设计风格：纯黑背景，全屏大图，底部相机信息 + 规格标签，顶部导航

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/camera_registry.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 颜色常量（与 camera_manager_screen 保持一致）
// ─────────────────────────────────────────────────────────────────────────────
const _kBg = Color(0xFF000000);
const _kWhite = Colors.white;
const _kGold = Color(0xFFFFCC00);
const _kCardBg = Color(0xFF1C1C1E);
const _kTagBg = Color(0xFF2C2C2E);

// ─────────────────────────────────────────────────────────────────────────────
// CameraSampleScreen
// ─────────────────────────────────────────────────────────────────────────────
class CameraSampleScreen extends StatefulWidget {
  final String cameraId;

  const CameraSampleScreen({super.key, required this.cameraId});

  @override
  State<CameraSampleScreen> createState() => _CameraSampleScreenState();
}

class _CameraSampleScreenState extends State<CameraSampleScreen>
    with TickerProviderStateMixin {
  late final PageController _pageController;
  late final CameraEntry _entry;
  int _currentIndex = 0;
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _entry = kAllCameras.firstWhere(
      (e) => e.id == widget.cameraId,
      orElse: () => kAllCameras.first,
    );
    _pageController = PageController();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    );
    _fadeController.forward();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    HapticFeedback.selectionClick();
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final samples = _entry.samplePhotos;
    final hasPhotos = samples.isNotEmpty;

    return Scaffold(
      backgroundColor: _kBg,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            Navigator.of(context).pop();
          },
          child: Container(
            margin: const EdgeInsets.only(left: 12),
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(120),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.arrow_back_ios_new_rounded,
              color: _kWhite,
              size: 18,
            ),
          ),
        ),
        title: Text(
          '${_entry.name} 样片',
          style: const TextStyle(
            color: _kWhite,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
        centerTitle: true,
        actions: [
          // 相机图标
          if (_entry.iconPath != null)
            Container(
              margin: const EdgeInsets.only(right: 12),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(120),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Image.asset(
                _entry.iconPath!,
                width: 24,
                height: 24,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.camera_alt,
                  color: _kWhite,
                  size: 20,
                ),
              ),
            ),
        ],
      ),
      body: hasPhotos
          ? FadeTransition(
              opacity: _fadeAnimation,
              child: Column(
                children: [
                  // ── 大图滑动区域 ──────────────────────────────────────────
                  Expanded(
                    child: Stack(
                      children: [
                        // 主图 PageView
                        PageView.builder(
                          controller: _pageController,
                          onPageChanged: _onPageChanged,
                          itemCount: samples.length,
                          itemBuilder: (context, index) {
                            return _SamplePhotoPage(
                              assetPath: samples[index],
                              isActive: index == _currentIndex,
                            );
                          },
                        ),

                        // 左右翻页箭头（仅在多张时显示）
                        if (samples.length > 1) ...[
                          // 左箭头
                          if (_currentIndex > 0)
                            Positioned(
                              left: 12,
                              top: 0,
                              bottom: 0,
                              child: Center(
                                child: GestureDetector(
                                  onTap: () {
                                    _pageController.previousPage(
                                      duration:
                                          const Duration(milliseconds: 300),
                                      curve: Curves.easeInOut,
                                    );
                                  },
                                  child: Container(
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      color: Colors.black.withAlpha(100),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.chevron_left_rounded,
                                      color: _kWhite,
                                      size: 24,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          // 右箭头
                          if (_currentIndex < samples.length - 1)
                            Positioned(
                              right: 12,
                              top: 0,
                              bottom: 0,
                              child: Center(
                                child: GestureDetector(
                                  onTap: () {
                                    _pageController.nextPage(
                                      duration:
                                          const Duration(milliseconds: 300),
                                      curve: Curves.easeInOut,
                                    );
                                  },
                                  child: Container(
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      color: Colors.black.withAlpha(100),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.chevron_right_rounded,
                                      color: _kWhite,
                                      size: 24,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],

                        // 页码指示器（底部居中）
                        if (samples.length > 1)
                          Positioned(
                            bottom: 16,
                            left: 0,
                            right: 0,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: List.generate(
                                samples.length,
                                (i) => AnimatedContainer(
                                  duration: const Duration(milliseconds: 250),
                                  margin:
                                      const EdgeInsets.symmetric(horizontal: 3),
                                  width: i == _currentIndex ? 20 : 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: i == _currentIndex
                                        ? _kWhite
                                        : Colors.white.withAlpha(80),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),

                  // ── 缩略图列表 ────────────────────────────────────────────
                  if (samples.length > 1)
                    Container(
                      height: 64,
                      color: _kBg,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: samples.length,
                        itemBuilder: (context, index) {
                          final isSelected = index == _currentIndex;
                          return GestureDetector(
                            onTap: () {
                              _pageController.animateToPage(
                                index,
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeInOut,
                              );
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              margin: const EdgeInsets.only(right: 8),
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isSelected
                                      ? _kWhite
                                      : Colors.transparent,
                                  width: 2,
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Image.asset(
                                  samples[index],
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Container(
                                    color: _kCardBg,
                                    child: const Icon(Icons.image_outlined,
                                        color: Colors.white38, size: 20),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),

                  // ── 相机信息面板 ──────────────────────────────────────────
                  _CameraInfoPanel(entry: _entry),
                ],
              ),
            )
          : _EmptyState(entry: _entry),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _SamplePhotoPage：单张样片展示（带缩放手势）
// ─────────────────────────────────────────────────────────────────────────────
class _SamplePhotoPage extends StatelessWidget {
  final String assetPath;
  final bool isActive;

  const _SamplePhotoPage({
    required this.assetPath,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      minScale: 1.0,
      maxScale: 4.0,
      child: Container(
        color: _kBg,
        child: Center(
          child: Image.asset(
            assetPath,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => Container(
              color: _kCardBg,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.broken_image_outlined,
                      color: Colors.white38, size: 48),
                  const SizedBox(height: 12),
                  Text(
                    '图片加载失败',
                    style: TextStyle(
                        color: Colors.white.withAlpha(100), fontSize: 14),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _CameraInfoPanel：底部相机信息面板
// ─────────────────────────────────────────────────────────────────────────────
class _CameraInfoPanel extends StatelessWidget {
  final CameraEntry entry;

  const _CameraInfoPanel({required this.entry});

  String _categoryLabel(String category) {
    switch (category) {
      case 'ccd':
        return 'CCD';
      case 'film':
        return '胶片';
      case 'digital':
        return '数码';
      case 'instant':
        return '拍立得';
      case 'creative':
        return '创意';
      default:
        return category.toUpperCase();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _kBg,
      padding: EdgeInsets.fromLTRB(
          20, 16, 20, MediaQuery.of(context).padding.bottom + 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 相机名称行
          Row(
            children: [
              // 相机图标
              if (entry.iconPath != null)
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: _kCardBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.all(6),
                  child: Image.asset(
                    entry.iconPath!,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.camera_alt,
                      color: _kWhite,
                      size: 22,
                    ),
                  ),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
                      style: const TextStyle(
                        color: _kWhite,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.description.isNotEmpty
                          ? entry.description
                          : '${_categoryLabel(entry.category)} 相机模拟',
                      style: TextStyle(
                        color: Colors.white.withAlpha(160),
                        fontSize: 12,
                        height: 1.4,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              // 规格标签（焦距 + 类别）
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (entry.focalLengthLabel != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: _kGold.withAlpha(30),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                            color: _kGold.withAlpha(80), width: 0.5),
                      ),
                      child: Text(
                        entry.focalLengthLabel!,
                        style: const TextStyle(
                          color: _kGold,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  const SizedBox(height: 4),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: _kTagBg,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _categoryLabel(entry.category),
                      style: TextStyle(
                        color: Colors.white.withAlpha(180),
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),

          // 风格标签行
          if (entry.tags.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: entry.tags
                  .map((tag) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: _kTagBg,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '# $tag',
                          style: TextStyle(
                            color: Colors.white.withAlpha(180),
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ],

          // 样片数量提示
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.photo_library_outlined,
                  color: Colors.white.withAlpha(80), size: 14),
              const SizedBox(width: 4),
              Text(
                '${entry.samplePhotos.length} 张样片',
                style: TextStyle(
                  color: Colors.white.withAlpha(80),
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              Text(
                '左右滑动查看更多',
                style: TextStyle(
                  color: Colors.white.withAlpha(60),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _EmptyState：无样片时的占位
// ─────────────────────────────────────────────────────────────────────────────
class _EmptyState extends StatelessWidget {
  final CameraEntry entry;

  const _EmptyState({required this.entry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.photo_camera_outlined,
              color: Colors.white.withAlpha(80), size: 64),
          const SizedBox(height: 16),
          Text(
            '${entry.name} 暂无样片',
            style: const TextStyle(
              color: _kWhite,
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '使用此相机拍摄后，样片将在此展示',
            style: TextStyle(
              color: Colors.white.withAlpha(120),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}
