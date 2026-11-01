import Cocoa
import FlutterMacOS
import GoogleSignIn

class MainFlutterWindow: NSWindow {
  private static let motionPreferenceChannelName = "com.betterkeep/motion_preferences"
  private var storageChannel: FlutterMethodChannel?
  private var motionPreferenceChannel: FlutterMethodChannel?
  private var motionPreferenceObserver: NSObjectProtocol?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    configureMotionPreferenceChannel(flutterViewController)
    let channel = FlutterMethodChannel(
      name: "com.betterkeep/storage", binaryMessenger: flutterViewController.engine.binaryMessenger)
    storageChannel = channel
    channel.setMethodCallHandler { call, result in
      guard call.method == "getAvailableBytes" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let path = call.arguments as? String else {
        result(FlutterError(code: "storage_unavailable", message: "Missing data path", details: nil))
        return
      }
      do {
        let values = try URL(fileURLWithPath: path).resourceValues(
          forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        result(values.volumeAvailableCapacityForImportantUsage)
      } catch {
        result(FlutterError(code: "storage_unavailable", message: "Storage information is unavailable", details: nil))
      }
    }
    let googleStorageChannel = FlutterMethodChannel(name: "com.betterkeep/storage_google", binaryMessenger: flutterViewController.engine.binaryMessenger)
    googleStorageChannel.setMethodCallHandler { call, result in
      let signIn = GIDSignIn.sharedInstance
      if call.method == "clientId" {
        result(signIn.configuration?.clientID)
        return
      }
      guard call.method == "grant" else { result(FlutterMethodNotImplemented); return }
      guard let user = signIn.currentUser else {
        result(FlutterError(code: "consent_required", message: "Authorize Google Drive again", details: nil)); return
      }
      user.refreshTokensIfNeeded { refreshed, error in
        guard error == nil, let refreshed = refreshed,
          let expiry = refreshed.accessToken.expirationDate else {
          result(FlutterError(code: "consent_required", message: "Authorize Google Drive again", details: nil)); return
        }
        result([
          "clientId": refreshed.configuration.clientID,
          "accessToken": refreshed.accessToken.tokenString,
          "refreshToken": refreshed.refreshToken.tokenString,
          "expiresAt": Int64(expiry.timeIntervalSince1970 * 1000)
        ])
      }
    }


    super.awakeFromNib()
  }

  deinit {
    if let observer = motionPreferenceObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    storageChannel?.setMethodCallHandler(nil)
    motionPreferenceChannel?.setMethodCallHandler(nil)
  }

  private func configureMotionPreferenceChannel(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: Self.motionPreferenceChannelName,
      binaryMessenger: controller.engine.binaryMessenger
    )
    motionPreferenceChannel = channel

    channel.setMethodCallHandler { call, result in
      guard call.method == "getReduceMotionEnabled" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    motionPreferenceObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.motionPreferenceChannel?.invokeMethod(
        "reduceMotionChanged",
        arguments: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      )
    }
  }
}
