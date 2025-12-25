import Flutter
import UIKit
import BackgroundTasks
import UserNotifications
import alarm

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    
    // Set up notification center delegate for alarm notifications
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
    }
    
    // Register background tasks for alarm plugin
    SwiftAlarmPlugin.registerBackgroundTasks()
    
    // Register background task for sync
    if #available(iOS 13.0, *) {
      BGTaskScheduler.shared.register(forTaskWithIdentifier: Bundle.main.bundleIdentifier! + ".sync", using: nil) { task in
        self.handleBackgroundSync(task: task as! BGProcessingTask)
      }
    }
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  
  // Schedule background sync when app enters background
  override func applicationDidEnterBackground(_ application: UIApplication) {
    if #available(iOS 13.0, *) {
      scheduleBackgroundSync()
    }
  }
  
  @available(iOS 13.0, *)
  func scheduleBackgroundSync() {
    let request = BGProcessingTaskRequest(identifier: Bundle.main.bundleIdentifier! + ".sync")
    request.requiresNetworkConnectivity = true
    request.requiresExternalPower = false
    
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      print("Could not schedule background sync: \(error)")
    }
  }
  
  @available(iOS 13.0, *)
  func handleBackgroundSync(task: BGProcessingTask) {
    // Schedule the next background sync
    scheduleBackgroundSync()
    
    // Create a background task assertion to keep the app running
    var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    backgroundTaskID = UIApplication.shared.beginBackgroundTask {
      UIApplication.shared.endBackgroundTask(backgroundTaskID)
    }
    
    task.expirationHandler = {
      UIApplication.shared.endBackgroundTask(backgroundTaskID)
    }
    
    // Mark task as complete after a reasonable time
    // The actual sync is handled by Flutter/Dart code
    DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
      task.setTaskCompleted(success: true)
      UIApplication.shared.endBackgroundTask(backgroundTaskID)
    }
  }
  
  // Forward notification presentation to alarm plugin for proper handling
  override func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    // Show notification even when app is in foreground
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .sound, .badge])
    } else {
      completionHandler([.alert, .sound, .badge])
    }
  }
  
  // Forward notification response (including action button taps) to alarm plugin
  override func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    // Let the parent class (and alarm plugin) handle all notification responses
    // The alarm plugin handles the stop button action internally
    // For dismiss and default actions, the alarm will continue ringing until user interacts with the app
    super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
  }
}
