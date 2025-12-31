import 'dart:async';
import 'package:flutter/material.dart' show Color, ThemeData;

/// App installation information
class AppInstallInfo {
  final String platform;
  final bool pwaInstalled;
  final bool canInstallPWA;
  final String? storeUrl;
  final bool promptShown;
  final bool promptDismissed;
  final bool isIOS;
  final bool isAndroid;
  final bool isWindows;
  final bool isMacOS;
  final bool hasNativeApp;
  final bool iosAppComingSoon;

  AppInstallInfo({
    required this.platform,
    required this.pwaInstalled,
    required this.canInstallPWA,
    this.storeUrl,
    required this.promptShown,
    required this.promptDismissed,
    required this.isIOS,
    required this.isAndroid,
    required this.isWindows,
    required this.isMacOS,
    required this.hasNativeApp,
    required this.iosAppComingSoon,
  });

  /// Whether we should show the install button in sidebar
  bool get shouldShowInstallButton => false;

  /// Whether we should show the first-time install prompt
  bool get shouldShowInstallPrompt => false;

  /// Get the appropriate action label
  String get installButtonLabel => 'Install App';

  /// Get the prompt message based on platform
  String get promptMessage => 'Install Better Keep for the best experience!';
}

/// Stub implementation for non-web platforms
class AppInstallService {
  static AppInstallService? _instance;
  static AppInstallService get instance => _instance ??= AppInstallService._();

  AppInstallService._();

  final _installableController = StreamController<void>.broadcast();
  final _installedController = StreamController<void>.broadcast();

  /// Stream that emits when PWA becomes installable
  Stream<void> get onInstallable => _installableController.stream;

  /// Stream that emits when PWA is installed
  Stream<void> get onInstalled => _installedController.stream;

  /// Initialize the service - no-op on non-web platforms
  void init() {}

  /// Get current installation info - always null on non-web platforms
  AppInstallInfo? getInstallInfo() => null;

  /// Check if PWA is installed - always false on non-web platforms
  bool isPWAInstalled() => false;

  /// Mark the install prompt as shown - no-op on non-web platforms
  void markPromptShown() {}

  /// Mark the install prompt as dismissed - no-op on non-web platforms
  void markPromptDismissed() {}

  /// Try to open the native app - no-op on non-web platforms
  void tryOpenNativeApp() {}

  /// Get the store URL for current platform - always null on non-web platforms
  String? getStoreUrl() => null;

  /// Trigger PWA installation - always returns false on non-web platforms
  Future<bool> triggerPWAInstall() async => false;

  /// Handle install action based on platform - no-op on non-web platforms
  Future<void> handleInstallAction() async {}

  /// Update the browser's theme color - no-op on non-web platforms
  void updateThemeColor(Color color) {}

  /// Update the background color - no-op on non-web platforms
  void updateBackgroundColor(Color color) {}

  /// Update both theme and background colors from a ThemeData - no-op on non-web platforms
  void updateColorsFromTheme(ThemeData theme) {}

  /// Dispose resources
  void dispose() {
    _installableController.close();
    _installedController.close();
  }
}
