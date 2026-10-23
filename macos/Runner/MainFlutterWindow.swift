import Cocoa
import FlutterMacOS

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
