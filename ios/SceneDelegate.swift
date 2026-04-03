import Flutter
import UIKit
import StoreKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)

    // Set up method channel for subscription management
    if let windowScene = scene as? UIWindowScene,
       let controller = windowScene.windows.first?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: "com.betterkeep/subscriptions", binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { (call, result) in
        if call.method == "showManageSubscriptions" {
          if #available(iOS 15.0, *) {
            Task {
              do {
                try await AppStore.showManageSubscriptions(in: windowScene)
                result(true)
              } catch {
                result(FlutterError(code: "MANAGE_SUBS_ERROR", message: error.localizedDescription, details: nil))
              }
            }
          } else {
            result(FlutterError(code: "UNSUPPORTED", message: "iOS 15+ required", details: nil))
          }
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  override func sceneDidEnterBackground(_ scene: UIScene) {
    super.sceneDidEnterBackground(scene)
    if #available(iOS 13.0, *) {
      (UIApplication.shared.delegate as? AppDelegate)?.scheduleBackgroundSync()
    }
  }
}
