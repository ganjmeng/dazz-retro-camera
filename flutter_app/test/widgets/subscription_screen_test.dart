import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:retro_cam/features/subscription/subscription_screen.dart';
import 'package:retro_cam/services/subscription_service.dart';

/// Mock SubscriptionService that returns a fixed isPro value without async init
class MockSubscriptionService extends SubscriptionService {
  MockSubscriptionService(bool isPro) : super.mock(isPro);
}

void main() {
  testWidgets('SubscriptionScreen shows pro status when user is pro',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          subscriptionServiceProvider
              .overrideWith((ref) => MockSubscriptionService(true)),
        ],
        child: const MaterialApp(
          home: SubscriptionScreen(),
        ),
      ),
    );
    // Use pump instead of pumpAndSettle to avoid timeout from async operations
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('您已是 Pro 会员'), findsOneWidget);
    expect(find.text('解锁 10+ 款复古相机'), findsNothing);
  });

  testWidgets('SubscriptionScreen shows features when user is free',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          subscriptionServiceProvider
              .overrideWith((ref) => MockSubscriptionService(false)),
        ],
        child: const MaterialApp(
          home: SubscriptionScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('解锁全部相机与功能'), findsOneWidget);
    expect(find.text('解锁 10+ 款复古相机'), findsOneWidget);
    expect(find.text('恢复购买'), findsOneWidget);
  });
}
