import 'package:flutter/material.dart';
import '../../models/preset.dart';

class CameraOptionsWidget extends StatelessWidget {
  final Preset preset;

  const CameraOptionsWidget({super.key, required this.preset});

  @override
  Widget build(BuildContext context) {
    final ui = preset.uiCapabilities;
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (ui.showFilmSelector) _buildOptionButton(Icons.movie_filter, '胶卷'),
        if (ui.showLensSelector) _buildOptionButton(Icons.camera, '镜头'),
        if (ui.showPaperSelector) _buildOptionButton(Icons.crop_portrait, '相纸'),
        if (ui.showRatioSelector) _buildOptionButton(Icons.aspect_ratio, '比例'),
        if (ui.showWatermarkSelector) _buildOptionButton(Icons.branding_watermark, '水印'),
      ],
    );
  }

  Widget _buildOptionButton(IconData icon, String label) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 10)),
        ],
      ),
    );
  }
}
