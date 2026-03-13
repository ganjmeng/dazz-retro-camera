import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:retro_cam/features/camera/camera_screen.dart';

void main() {
  testWidgets('CameraScreen renders without error', (WidgetTester tester) async {
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
  });
}
