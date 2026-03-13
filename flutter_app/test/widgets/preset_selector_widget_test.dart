import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:retro_cam/features/camera/preset_selector_widget.dart';
import 'package:retro_cam/models/preset.dart';
import 'package:retro_cam/services/preset_repository.dart';

void main() {
  testWidgets('PresetSelectorWidget shows list of presets', (WidgetTester tester) async {
    final mockPresets = [
      Preset.fromJson({
        'id': 'cam_1',
        'name': 'Camera 1',
        'category': 'ccd',
        'outputType': 'photo',
        'isPremium': false,
        'baseModel': {}
      }),
      Preset.fromJson({
        'id': 'cam_2',
        'name': 'Camera 2 Premium',
        'category': 'film',
        'outputType': 'photo',
        'isPremium': true,
        'baseModel': {}
      }),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          presetListProvider.overrideWith((ref) => Future.value(mockPresets)),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 100,
              child: PresetSelectorWidget(),
            ),
          ),
        ),
      ),
    );

    // Initial loading state
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Wait for future to complete
    await tester.pumpAndSettle();

    // Verify list items
    expect(find.text('Camera 1'), findsOneWidget);
    expect(find.text('Camera 2 Premium'), findsOneWidget);
    
    // Verify premium lock icon exists
    expect(find.byIcon(Icons.lock), findsOneWidget);
  });
}
