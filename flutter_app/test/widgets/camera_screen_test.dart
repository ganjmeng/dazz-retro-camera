import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:retro_cam/features/camera/camera_screen.dart';
import 'package:retro_cam/features/camera/camera_controls_widget.dart';
import 'package:retro_cam/features/camera/preset_selector_widget.dart';

void main() {
  testWidgets('CameraScreen displays main components', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: CameraScreen(),
        ),
      ),
    );

    // Verify app bar elements
    expect(find.byIcon(Icons.settings), findsOneWidget);
    expect(find.byIcon(Icons.flip_camera_ios), findsOneWidget);
    expect(find.byIcon(Icons.flash_off), findsOneWidget);

    // Verify bottom controls
    expect(find.byType(CameraControlsWidget), findsOneWidget);
    expect(find.byType(PresetSelectorWidget), findsOneWidget);
  });
}
