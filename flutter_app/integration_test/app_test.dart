import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:retro_cam/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('end-to-end test', () {
    testWidgets('tap on settings, navigate back, and verify camera UI',
        (tester) async {
      app.main();
      await tester.pumpAndSettle();

      // Verify camera screen is shown
      expect(find.byIcon(Icons.settings), findsOneWidget);

      // Tap settings icon
      await tester.tap(find.byIcon(Icons.settings));
      await tester.pumpAndSettle();

      // Verify settings screen is shown
      expect(find.text('设置'), findsWidgets);
      expect(find.text('隐私政策'), findsOneWidget);

      // Navigate back
      await tester.tap(find.byIcon(Icons.arrow_back).or(find.byType(BackButton)));
      await tester.pumpAndSettle();

      // Verify back on camera screen
      expect(find.byIcon(Icons.camera_alt), findsWidgets);
    });
  });
}
