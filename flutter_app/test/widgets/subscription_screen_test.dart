import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:retro_cam/features/subscription/subscription_screen.dart';
import 'package:retro_cam/services/subscription_service.dart';

void main() {
  testWidgets('SubscriptionScreen shows pro status when user is pro', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          subscriptionServiceProvider.overrideWith((ref) => true), // Mock Pro status
        ],
        child: const MaterialApp(
          home: SubscriptionScreen(),
        ),
      ),
    );

    // Initial loading state
    await tester.pumpAndSettle();

    // Verify Pro text
    expect(find.text('您已是 Pro 会员'), findsOneWidget);
    
    // Verify feature list is hidden for Pro users
    expect(find.text('解锁 10+ 款复古相机'), findsNothing);
  });

  testWidgets('SubscriptionScreen shows features when user is free', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          subscriptionServiceProvider.overrideWith((ref) => false), // Mock Free status
        ],
        child: const MaterialApp(
          home: SubscriptionScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify Free text
    expect(find.text('解锁全部相机与功能'), findsOneWidget);
    
    // Verify feature list is visible
    expect(find.text('解锁 10+ 款复古相机'), findsOneWidget);
    expect(find.text('恢复购买'), findsOneWidget);
  });
}
