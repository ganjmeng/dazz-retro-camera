# DAZZ Retro Camera - Monetization Strategy (Phase 3)

## 1. Freemium Model Overview
The application will use a Freemium model, offering a set of basic cameras for free while locking premium cameras, advanced features, and removing watermarks behind a subscription or one-time purchase.

### 1.1 Free Tier (Basic)
- Access to 3 basic cameras (e.g., standard CCD, basic instant, basic film).
- Standard photo resolution.
- Watermark applied to exported photos.
- Basic sharing options.

### 1.2 Premium Tier (Pro)
- Access to all 10+ premium cameras (VHS, advanced film emulations, etc.).
- High-resolution photo and video export.
- Remove watermark option.
- Ad-free experience.
- Priority customer support.

## 2. Subscription SKUs (In-App Purchases)

We will use a third-party service like RevenueCat to manage subscriptions across iOS and Android.

| SKU ID | Type | Duration | Price (USD) | Trial Period |
|---|---|---|---|---|
| `dazz_pro_monthly` | Auto-renewable | 1 Month | $3.99 | 3 days |
| `dazz_pro_yearly` | Auto-renewable | 1 Year | $19.99 | 7 days |
| `dazz_pro_lifetime` | Non-consumable | Lifetime | $39.99 | None |

## 3. Paywall Trigger Points
The paywall will be displayed to users at the following interaction points:
1. **Onboarding:** After the initial tutorial, offering a 7-day free trial.
2. **Camera Selection:** When tapping on a premium camera in the `PresetSelectorWidget`.
3. **Settings:** A dedicated "Upgrade to Pro" banner in the settings menu.
4. **Export:** When attempting to disable the watermark or export in high resolution.

## 4. Technical Implementation (Flutter)
- Integrate `purchases_flutter` (RevenueCat) for cross-platform IAP management.
- Create a `SubscriptionService` to manage user entitlement state.
- Update `PresetSelectorWidget` to show a lock icon on premium presets and trigger the paywall when tapped.
- Build a high-conversion `SubscriptionScreen` highlighting Pro benefits.
