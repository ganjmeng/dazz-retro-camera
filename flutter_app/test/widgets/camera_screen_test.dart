import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:retro_cam/features/camera/camera_screen.dart';

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

    // CameraScreen should render without throwing
    expect(find.byType(CameraScreen), findsOneWidget);

    // Verify the scaffold is present
    expect(find.byType(Scaffold), findsOneWidget);

    // Verify camera icon is present (shutter button area)
    expect(find.byIcon(Icons.camera_alt_outlined), findsWidgets);
  });
}
