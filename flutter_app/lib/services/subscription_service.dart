import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

// RevenueCat API Keys
const String _revenueCatAppleApiKey = 'appl_YOUR_APPLE_API_KEY';
const String _revenueCatGoogleApiKey = 'goog_YOUR_GOOGLE_API_KEY';

final subscriptionServiceProvider = StateNotifierProvider<SubscriptionService, bool>((ref) {
  return SubscriptionService();
});

class SubscriptionService extends StateNotifier<bool> {
  SubscriptionService() : super(false) {
    _initPlatformState();
  }

  /// Mock constructor for testing
  SubscriptionService.mock(bool isPro) : super(isPro);

  Future<void> _initPlatformState() async {
    await Purchases.setLogLevel(LogLevel.debug);

    PurchasesConfiguration configuration;
    if (Platform.isAndroid) {
      configuration = PurchasesConfiguration(_revenueCatGoogleApiKey);
    } else if (Platform.isIOS) {
      configuration = PurchasesConfiguration(_revenueCatAppleApiKey);
    } else {
      return;
    }
    
    await Purchases.configure(configuration);
    
    Purchases.addCustomerInfoUpdateListener((customerInfo) {
      _updateSubscriptionStatus(customerInfo);
    });

    try {
      CustomerInfo customerInfo = await Purchases.getCustomerInfo();
      _updateSubscriptionStatus(customerInfo);
    } on PlatformException catch (e) {
      print('Error fetching customer info: ${e.message}');
    }
  }

  void _updateSubscriptionStatus(CustomerInfo customerInfo) {
    // 假设在 RevenueCat 中配置的 Entitlement Identifier 为 "pro"
    final isPro = customerInfo.entitlements.all["pro"]?.isActive ?? false;
    state = isPro;
  }

  Future<List<Package>> getOfferings() async {
    try {
      Offerings offerings = await Purchases.getOfferings();
      if (offerings.current != null) {
        return offerings.current!.availablePackages;
      }
    } on PlatformException catch (e) {
      print('Error fetching offerings: ${e.message}');
    }
    return [];
  }

  Future<bool> purchasePackage(Package package) async {
    try {
      // purchases_flutter 9.x: use purchase(PurchaseParams) instead of purchasePackage()
      final result = await Purchases.purchase(PurchaseParams.package(package));
      _updateSubscriptionStatus(result.customerInfo);
      return state;
    } on PlatformException catch (e) {
      var errorCode = PurchasesErrorHelper.getErrorCode(e);
      if (errorCode != PurchasesErrorCode.purchaseCancelledError) {
        print('Error purchasing package: ${e.message}');
      }
      return false;
    }
  }

  Future<bool> restorePurchases() async {
    try {
      CustomerInfo customerInfo = await Purchases.restorePurchases();
      _updateSubscriptionStatus(customerInfo);
      return state;
    } on PlatformException catch (e) {
      print('Error restoring purchases: ${e.message}');
      return false;
    }
  }
}
