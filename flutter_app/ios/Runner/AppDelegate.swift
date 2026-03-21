import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    // 手动注册相机插件（MethodChannel: com.retrocam.app/camera_control）
    RetroCamPlugin.register(with: self.registrar(forPlugin: "RetroCamPlugin")!)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
