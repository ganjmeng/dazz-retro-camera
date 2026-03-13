# DAZZ Retro Camera - Store Listing Configuration (Phase 3)

## 1. App Store (iOS) Configuration

### 1.1 App Information
- **Name:** DAZZ Retro Camera - CCD Simulator
- **Subtitle:** Vintage Film & Video Camera
- **Category:** Photo & Video
- **Secondary Category:** Entertainment

### 1.2 Info.plist Updates
Ensure the following keys are present with descriptive reasons for App Store review:
```xml
<key>NSCameraUsageDescription</key>
<string>DAZZ requires camera access to capture vintage-style photos and videos.</string>
<key>NSMicrophoneUsageDescription</key>
<string>DAZZ requires microphone access to record audio along with your retro videos.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>DAZZ requires access to your photo library to save your captured retro photos and videos.</string>
<key>NSPhotoLibraryAddUsageDescription</key>
<string>DAZZ requires permission to save photos and videos directly to your camera roll.</string>
```

### 1.3 In-App Purchases (RevenueCat)
- Create auto-renewable subscriptions in App Store Connect:
  - `dazz_pro_monthly`
  - `dazz_pro_yearly`
- Create non-consumable for lifetime:
  - `dazz_pro_lifetime`
- Generate App-Specific Shared Secret and configure in RevenueCat dashboard.

## 2. Google Play (Android) Configuration

### 2.1 App Information
- **Title:** DAZZ Retro Camera - CCD & Film
- **Short Description:** Vintage camera simulator with authentic CCD, film, and VHS effects.
- **Category:** Photography

### 2.2 AndroidManifest.xml Updates
Ensure permissions are declared:
```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="28" />
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />
<uses-permission android:name="com.android.vending.BILLING" /> <!-- Required for IAP -->
```

### 2.3 In-App Purchases (RevenueCat)
- Create subscription products in Google Play Console.
- Configure Google Cloud Pub/Sub for real-time developer notifications.
- Link Google Play Service Account credentials to RevenueCat.

## 3. Privacy Policy
A privacy policy URL is required for both stores, especially since the app requests Camera and Photo Library permissions.
- **Key clauses needed:**
  - We do not upload your photos to our servers; all processing is done locally on your device.
  - Camera and Microphone access are strictly used for capturing media within the app.
  - Analytics (if any) are anonymized.
