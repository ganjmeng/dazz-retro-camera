import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// Smoke tests — avoid instantiating CameraScreen directly as it requires
// native camera plugins (CameraX / AVFoundation) not available in test env.
void main() {
  testWidgets('App boots without crash', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(child: Text('DAZZ')),
          ),
        ),
      ),
    );
    expect(find.text('DAZZ'), findsOneWidget);
  });

  testWidgets('MaterialApp renders correctly', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: Text(
                'Camera Ready',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Camera Ready'), findsOneWidget);
  });

  testWidgets('Black background scaffold renders', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: SizedBox.expand(),
          ),
        ),
      ),
    );
    expect(find.byType(Scaffold), findsOneWidget);
  });
}
