import 'dart:async';
import 'dart:js_interop';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart' show Color, ThemeData;
import 'package:web/web.dart' as web;

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
  bool get shouldShowInstallButton {
    if (!kIsWeb) return false;
    if (pwaInstalled) return false;
    // Show for: platforms with native apps, iOS (coming soon), or PWA installable
    // Also show for macOS/Linux where PWA is the best option
    return canInstallPWA ||
        hasNativeApp ||
        isIOS ||
        isMacOS ||
        platform == 'linux';
  }

  /// Whether we should show the first-time install prompt
  bool get shouldShowInstallPrompt {
    if (!kIsWeb) return false;
    if (promptShown || promptDismissed) return false;
    if (pwaInstalled) return false;
    return true;
  }

  /// Get the appropriate action label
  String get installButtonLabel {
    if (isIOS) return 'Install App';
    if (hasNativeApp) return 'Get App';
    if (canInstallPWA) return 'Install App';
    return 'Install App';
  }

  /// Get the prompt message based on platform
  String get promptMessage {
    if (isIOS) {
      return 'iOS app coming soon! Install as a web app for the best experience.';
    }
    if (isAndroid) {
      return 'Get Better Keep from Google Play for the best experience!';
    }
    if (isWindows) {
      return 'Get Better Keep from Microsoft Store for the best experience!';
    }
    if (canInstallPWA) {
      return 'Install Better Keep for quick access and offline support!';
    }
    return 'Install Better Keep for the best experience!';
  }
}

@JS('BetterKeepInstall')
external _BetterKeepInstallJS? get _betterKeepInstall;

@JS()
@staticInterop
class _BetterKeepInstallJS {}

extension _BetterKeepInstallJSExtension on _BetterKeepInstallJS {
  external bool isPWAInstalled();
  external void markPromptShown();
  external void markPromptDismissed();
  external void tryOpenNativeApp();
  external String? getStoreUrl();
  external JSPromise<JSObject> triggerPWAInstall();
  external void showIOSInstallInstructions();
  external _InstallInfoJS getInstallInfo();
  external void updateThemeColor(String color);
  external void updateBackgroundColor(String color);
}

@JS()
@staticInterop
class _InstallInfoJS {}

extension _InstallInfoJSExtension on _InstallInfoJS {
  external String get platform;
  external bool get pwaInstalled;
  external bool get canInstallPWA;
  external String? get storeUrl;
  external bool get promptShown;
  external bool get promptDismissed;
  external bool get isIOS;
  external bool get isAndroid;
  external bool get isWindows;
  external bool get isMacOS;
  external bool get hasNativeApp;
  external bool get iosAppComingSoon;
}

/// Service to handle app installation prompts and actions
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

  /// Initialize the service and set up event listeners
  void init() {
    if (!kIsWeb) return;

    // Check if JS is available, if not wait for it
    _waitForJSReady();

    web.window.addEventListener(
      'bk-pwa-installable',
      (web.Event e) {
        _installableController.add(null);
      }.toJS,
    );

    web.window.addEventListener(
      'bk-pwa-installed',
      (web.Event e) {
        _installedController.add(null);
      }.toJS,
    );
  }

  /// Wait for JS to be ready (in case script loads after Flutter)
  void _waitForJSReady() {
    if (_betterKeepInstall != null) return;

    // Retry a few times with delay
    int retries = 0;
    void check() {
      if (_betterKeepInstall != null) {
        debugPrint('BetterKeepInstall JS ready after $retries retries');
        return;
      }
      if (retries >= 10) {
        debugPrint('BetterKeepInstall JS not available after 10 retries');
        return;
      }
      retries++;
      Future.delayed(const Duration(milliseconds: 100), check);
    }

    check();
  }

  /// Get current installation info
  AppInstallInfo? getInstallInfo() {
    if (!kIsWeb) return null;
    final js = _betterKeepInstall;
    if (js == null) return null;

    final info = js.getInstallInfo();
    return AppInstallInfo(
      platform: info.platform,
      pwaInstalled: info.pwaInstalled,
      canInstallPWA: info.canInstallPWA,
      storeUrl: info.storeUrl,
      promptShown: info.promptShown,
      promptDismissed: info.promptDismissed,
      isIOS: info.isIOS,
      isAndroid: info.isAndroid,
      isWindows: info.isWindows,
      isMacOS: info.isMacOS,
      hasNativeApp: info.hasNativeApp,
      iosAppComingSoon: info.iosAppComingSoon,
    );
  }

  /// Check if PWA is installed
  bool isPWAInstalled() {
    if (!kIsWeb) return false;
    return _betterKeepInstall?.isPWAInstalled() ?? false;
  }

  /// Mark the install prompt as shown
  void markPromptShown() {
    if (!kIsWeb) return;
    _betterKeepInstall?.markPromptShown();
  }

  /// Mark the install prompt as dismissed
  void markPromptDismissed() {
    if (!kIsWeb) return;
    _betterKeepInstall?.markPromptDismissed();
  }

  /// Try to open the native app
  void tryOpenNativeApp() {
    if (!kIsWeb) return;
    _betterKeepInstall?.tryOpenNativeApp();
  }

  /// Get the store URL for current platform
  String? getStoreUrl() {
    if (!kIsWeb) return null;
    return _betterKeepInstall?.getStoreUrl();
  }

  /// Trigger PWA installation
  Future<bool> triggerPWAInstall() async {
    if (!kIsWeb) return false;
    final js = _betterKeepInstall;
    if (js == null) return false;

    try {
      final result = await js.triggerPWAInstall().toDart;
      // Access 'success' property from JSObject
      final success = (result as dynamic)['success'] as bool?;
      return success ?? false;
    } catch (e) {
      debugPrint('PWA install error: $e');
      return false;
    }
  }

  /// Handle install action based on platform
  Future<void> handleInstallAction() async {
    final info = getInstallInfo();
    if (info == null) return;

    if (info.isIOS) {
      // Show iOS PWA install instructions
      _betterKeepInstall?.showIOSInstallInstructions();
    } else if (info.hasNativeApp && info.storeUrl != null) {
      // Open store URL
      web.window.open(info.storeUrl!, '_blank');
    } else if (info.canInstallPWA) {
      // Trigger PWA install
      await triggerPWAInstall();
    }
  }

  /// Update the browser's theme color (affects status bar on mobile browsers)
  /// Call this when the app theme changes
  void updateThemeColor(Color color) {
    if (!kIsWeb) return;
    final hexColor = '#${color.toARGB32().toRadixString(16).substring(2)}';
    _betterKeepInstall?.updateThemeColor(hexColor);
  }

  /// Update the background color (affects the visible background during loading)
  void updateBackgroundColor(Color color) {
    if (!kIsWeb) return;
    final hexColor = '#${color.toARGB32().toRadixString(16).substring(2)}';
    _betterKeepInstall?.updateBackgroundColor(hexColor);
  }

  /// Update both theme and background colors from a ThemeData
  void updateColorsFromTheme(ThemeData theme) {
    if (!kIsWeb) return;
    // Use scaffold background for both - this is the main app background
    final bgColor = theme.scaffoldBackgroundColor;
    updateThemeColor(bgColor);
    updateBackgroundColor(bgColor);
  }

  /// Dispose resources
  void dispose() {
    _installableController.close();
    _installedController.close();
  }
}
