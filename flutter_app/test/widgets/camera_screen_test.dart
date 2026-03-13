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
    await tester.pump();

    // Verify key widget types are present
    expect(find.byType(CameraControlsWidget), findsOneWidget);
    expect(find.byType(PresetSelectorWidget), findsOneWidget);

    // Verify icons that are actually used in camera_controls_widget.dart
    expect(find.byIcon(Icons.flip_camera_ios_outlined), findsOneWidget);
    expect(find.byIcon(Icons.flash_off_outlined), findsOneWidget);
    expect(find.byIcon(Icons.camera_alt_outlined), findsOneWidget);
  });
}
