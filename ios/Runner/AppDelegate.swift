import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Add this to get Documents directory path
    if let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path {
        UserDefaults.standard.set(documentsPath, forKey: "download_path")
    }

    // iOS 27 requires the UIScene lifecycle (Info.plist UIApplicationSceneManifest).
    // The window and FlutterViewController now come from the scene, after this
    // method returns, so plugins register through pluginRegistrant instead.
    pluginRegistrant = PluginRegistrant()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

class PluginRegistrant: NSObject, FlutterPluginRegistrant {
  func register(with registry: FlutterPluginRegistry) {
    GeneratedPluginRegistrant.register(with: registry)
  }
}
