import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/preset.dart';
import '../../services/camera_service.dart';
import '../../services/preset_repository.dart';
import '../../services/subscription_service.dart';
import 'package:go_router/go_router.dart';
import '../../router/app_router.dart';

/// 底部横向滚动的相机 Preset 选择器
class PresetSelectorWidget extends ConsumerWidget {
  const PresetSelectorWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presetsAsync = ref.watch(presetListProvider);
    final currentPreset = ref.watch(cameraServiceProvider).currentPreset;

    return presetsAsync.when(
      data: (presets) => _buildList(context, ref, presets, currentPreset),
      loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (e, _) => const SizedBox.shrink(),
    );
  }

  Widget _buildList(
    BuildContext context,
    WidgetRef ref,
    List<Preset> presets,
    Preset? currentPreset,
  ) {
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: presets.length,
      itemBuilder: (context, index) {
        final preset = presets[index];
        final isSelected = currentPreset?.id == preset.id;

        return GestureDetector(
          onTap: () {
            if (preset.isPremium) {
              final isPro = ref.read(subscriptionServiceProvider);
              if (!isPro) {
                context.push(AppRoutes.subscription);
                return;
              }
            }
            ref.read(cameraServiceProvider.notifier).setPreset(preset);
          },
          child: _PresetItem(preset: preset, isSelected: isSelected),
        );
      },
    );
  }
}

class _PresetItem extends StatelessWidget {
  final Preset preset;
  final bool isSelected;

  const _PresetItem({required this.preset, required this.isSelected});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 70,
      margin: const EdgeInsets.only(right: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 相机图标容器
          Stack(
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: isSelected
                      ? Border.all(color: Colors.white, width: 2)
                      : Border.all(color: Colors.grey[700]!, width: 1),
                  color: Colors.grey[850],
                ),
                child: const Icon(Icons.camera_alt, color: Colors.white, size: 28),
              ),
              // Premium 锁标志
              if (preset.isPremium)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      color: Colors.amber,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.lock, size: 10, color: Colors.black),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            preset.name,
            style: TextStyle(
              color: isSelected ? Colors.white : Colors.grey,
              fontSize: 11,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            ),
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
