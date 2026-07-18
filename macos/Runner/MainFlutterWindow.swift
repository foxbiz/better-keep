import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private static let motionPreferenceChannelName = "com.betterkeep/motion_preferences"
  private var motionPreferenceChannel: FlutterMethodChannel?
  private var motionPreferenceObserver: NSObjectProtocol?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    configureMotionPreferenceChannel(flutterViewController)

    super.awakeFromNib()
  }

  deinit {
    if let observer = motionPreferenceObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
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
