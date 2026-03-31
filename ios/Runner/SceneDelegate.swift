import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func sceneDidEnterBackground(_ scene: UIScene) {
    super.sceneDidEnterBackground(scene)
    if #available(iOS 13.0, *) {
      (UIApplication.shared.delegate as? AppDelegate)?.scheduleBackgroundSync()
    }
  }
}
