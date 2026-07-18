import 'dart:async';
import 'dart:ui' as ui;

import 'package:better_keep/utils/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Centralizes the app's opt-in handling of platform motion preferences.
///
/// Flutter exposes different accessibility flags on different platforms. This
/// controller normalizes them and supplements Flutter with a small native
/// bridge on desktop platforms where the engine does not expose the setting.
class MotionPreferences extends ChangeNotifier {
  MotionPreferences({
    MethodChannel? channel,
    TargetPlatform? targetPlatform,
    bool? isWeb,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _targetPlatform = targetPlatform ?? defaultTargetPlatform,
       _isWeb = isWeb ?? kIsWeb;

  static const String channelName = 'com.betterkeep/motion_preferences';
  static const String getReduceMotionMethod = 'getReduceMotionEnabled';
  static const String reduceMotionChangedMethod = 'reduceMotionChanged';

  static final MotionPreferences instance = MotionPreferences();

  final MethodChannel _channel;
  final TargetPlatform _targetPlatform;
  final bool _isWeb;

  bool _followSystem = false;
  bool _nativeReduceMotion = false;
  bool _initialized = false;

  bool get followSystem => _followSystem;
  bool get nativeReduceMotion => _nativeReduceMotion;

  bool get reduceAnimations => effectiveFor(
    WidgetsBinding.instance.platformDispatcher.accessibilityFeatures,
  );

  /// Whether this platform needs the app's native desktop fallback.
  bool get _usesDesktopChannel =>
      !_isWeb &&
      (_targetPlatform == TargetPlatform.macOS ||
          _targetPlatform == TargetPlatform.windows ||
          _targetPlatform == TargetPlatform.linux);

  /// Computes the effective app-wide reduced-animation state.
  bool effectiveFor(ui.AccessibilityFeatures features) {
    return shouldReduceAnimations(
      followSystem: _followSystem,
      disableAnimations: features.disableAnimations,
      reduceMotion: features.reduceMotion,
      nativeReduceMotion: _nativeReduceMotion,
    );
  }

  /// Pure policy function kept separate for comprehensive unit testing.
  static bool shouldReduceAnimations({
    required bool followSystem,
    required bool disableAnimations,
    required bool reduceMotion,
    required bool nativeReduceMotion,
  }) {
    return followSystem &&
        (disableAnimations || reduceMotion || nativeReduceMotion);
  }

  void setFollowSystem(bool value) {
    if (_followSystem == value) return;
    _followSystem = value;
    notifyListeners();
  }

  /// Notifies dependents after Flutter receives new accessibility flags.
  void handlePlatformAccessibilityFeaturesChanged() {
    notifyListeners();
  }

  /// Initializes the live native fallback used by desktop runners.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    if (!_usesDesktopChannel) return;

    _channel.setMethodCallHandler(_handleNativeMethodCall);
    try {
      final value = await _channel.invokeMethod<bool>(getReduceMotionMethod);
      _setNativeReduceMotion(value ?? false);
    } catch (error, stackTrace) {
      // The preference is best-effort. A missing or unavailable bridge must
      // never delay startup or disable animations unexpectedly.
      unawaited(
        AppLogger.error(
          'MotionPreferences: Native preference query failed',
          error,
          stackTrace,
        ),
      );
      _setNativeReduceMotion(false);
    }
  }

  Future<void> _handleNativeMethodCall(MethodCall call) async {
    if (call.method != reduceMotionChangedMethod) return;

    final value = call.arguments;
    if (value is bool) {
      _setNativeReduceMotion(value);
      return;
    }

    unawaited(
      AppLogger.error(
        'MotionPreferences: Ignoring invalid native preference value',
        value,
      ),
    );
  }

  void _setNativeReduceMotion(bool value) {
    if (_nativeReduceMotion == value) return;
    _nativeReduceMotion = value;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_usesDesktopChannel && _initialized) {
      _channel.setMethodCallHandler(null);
    }
    super.dispose();
  }
}

/// Applies the effective preference to MediaQuery-based animation consumers.
class MotionMediaQuery extends StatelessWidget {
  const MotionMediaQuery({super.key, required this.child, this.preferences});

  final Widget child;
  final MotionPreferences? preferences;

  @override
  Widget build(BuildContext context) {
    final controller = preferences ?? MotionPreferences.instance;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final mediaQuery = MediaQuery.of(
          context,
        ).copyWith(disableAnimations: controller.reduceAnimations);
        return MediaQuery(data: mediaQuery, child: child);
      },
    );
  }
}

/// Production binding that applies Better Keep's motion preference globally.
///
/// [AnimationController] reads [SemanticsBinding.disableAnimations] directly,
/// so a MediaQuery override alone would miss implicit animations, routes, and
/// Material widgets. Overriding the binding keeps all of those paths aligned.
class BetterKeepWidgetsBinding extends WidgetsFlutterBinding {
  static BetterKeepWidgetsBinding? _instance;

  static BetterKeepWidgetsBinding get instance =>
      BindingBase.checkInstance(_instance);

  static BetterKeepWidgetsBinding ensureInitialized() {
    _instance ??= BetterKeepWidgetsBinding();
    return instance;
  }

  @override
  void initInstances() {
    super.initInstances();
    _instance = this;
  }

  @override
  bool get disableAnimations =>
      MotionPreferences.instance.effectiveFor(accessibilityFeatures);

  @override
  void handleAccessibilityFeaturesChanged() {
    super.handleAccessibilityFeaturesChanged();
    MotionPreferences.instance.handlePlatformAccessibilityFeaturesChanged();
  }
}
