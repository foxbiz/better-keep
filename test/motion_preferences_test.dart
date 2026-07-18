import 'package:better_keep/services/motion_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  group('MotionPreferences policy', () {
    test('setting off always preserves animations', () {
      for (final disableAnimations in [false, true]) {
        for (final reduceMotion in [false, true]) {
          for (final nativeReduceMotion in [false, true]) {
            expect(
              MotionPreferences.shouldReduceAnimations(
                followSystem: false,
                disableAnimations: disableAnimations,
                reduceMotion: reduceMotion,
                nativeReduceMotion: nativeReduceMotion,
              ),
              isFalse,
            );
          }
        }
      }
    });

    test('setting on responds to every supported system signal', () {
      expect(
        MotionPreferences.shouldReduceAnimations(
          followSystem: true,
          disableAnimations: false,
          reduceMotion: false,
          nativeReduceMotion: false,
        ),
        isFalse,
      );

      for (final signals in const [
        (disable: true, reduce: false, native: false),
        (disable: false, reduce: true, native: false),
        (disable: false, reduce: false, native: true),
      ]) {
        expect(
          MotionPreferences.shouldReduceAnimations(
            followSystem: true,
            disableAnimations: signals.disable,
            reduceMotion: signals.reduce,
            nativeReduceMotion: signals.native,
          ),
          isTrue,
        );
      }
    });
  });

  testWidgets('MotionMediaQuery overrides and reacts to the preference', (
    tester,
  ) async {
    final preferences = MotionPreferences(
      targetPlatform: TargetPlatform.android,
      isWeb: false,
    );
    addTearDown(preferences.dispose);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MotionMediaQuery(
            preferences: preferences,
            child: Builder(
              builder: (context) =>
                  Text(MediaQuery.disableAnimationsOf(context).toString()),
            ),
          ),
        ),
      ),
    );

    // The app defaults to preserving motion, even if the inherited platform
    // MediaQuery requests reduced motion.
    expect(find.text('false'), findsOneWidget);

    preferences.setFollowSystem(true);
    await tester.pump();
    expect(find.text('true'), findsOneWidget);

    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures();
    preferences.handlePlatformAccessibilityFeaturesChanged();
    await tester.pump();
    expect(find.text('false'), findsOneWidget);

    preferences.setFollowSystem(false);
    await tester.pump();
    expect(find.text('false'), findsOneWidget);
  });

  group('desktop channel', () {
    late MethodChannel channel;
    late MotionPreferences preferences;
    late bool preferencesDisposed;

    setUp(() {
      channel = const MethodChannel('test.betterkeep/motion_preferences');
      preferences = MotionPreferences(
        channel: channel,
        targetPlatform: TargetPlatform.macOS,
        isWeb: false,
      );
      preferencesDisposed = false;
    });

    tearDown(() {
      if (!preferencesDisposed) preferences.dispose();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('loads the initial native value', () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, MotionPreferences.getReduceMotionMethod);
        return true;
      });

      await preferences.initialize();

      expect(preferences.nativeReduceMotion, isTrue);
    });

    test('applies live native callbacks and notifies listeners', () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => false,
      );
      await preferences.initialize();

      var notificationCount = 0;
      preferences.addListener(() => notificationCount++);

      await binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          const MethodCall(MotionPreferences.reduceMotionChangedMethod, true),
        ),
        null,
      );

      expect(preferences.nativeReduceMotion, isTrue);
      expect(notificationCount, 1);
    });

    test('falls back to normal motion when the native query fails', () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        _,
      ) async {
        throw PlatformException(code: 'unavailable');
      });

      await preferences.initialize();

      expect(preferences.nativeReduceMotion, isFalse);
    });

    test('removes the native callback when disposed', () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => false,
      );
      await preferences.initialize();
      preferences.dispose();
      preferencesDisposed = true;

      await binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          const MethodCall(MotionPreferences.reduceMotionChangedMethod, true),
        ),
        null,
      );

      expect(preferences.nativeReduceMotion, isFalse);
    });
  });
}
