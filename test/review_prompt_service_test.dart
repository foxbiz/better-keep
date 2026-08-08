import 'dart:async';

import 'package:better_keep/services/review_prompt_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'requests once after age, note, active-day, and platform gates pass',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final platform = _FakeReviewPlatform();

      await _recordActiveDay(preferences, platform, DateTime(2026, 1, 1));
      await _recordActiveDay(preferences, platform, DateTime(2026, 1, 2));
      await _recordActiveDay(preferences, platform, DateTime(2026, 1, 3));

      final service = ReviewPromptService(
        platform: platform,
        now: () => DateTime(2026, 1, 8),
        versionLoader: () async => '1.0.0',
        noteCountLoader: () async => 5,
      );
      await service.initialize(preferences: preferences);

      expect(
        await service.recordPositiveMilestone(
          ReviewMilestone.reminderScheduled,
        ),
        isTrue,
      );
      expect(platform.requestCount, 1);

      expect(
        await service.recordPositiveMilestone(ReviewMilestone.dataExport),
        isFalse,
      );
      expect(platform.requestCount, 1);
    },
  );

  test('requires three active days and five notes', () async {
    final preferences = await SharedPreferences.getInstance();
    final platform = _FakeReviewPlatform();
    await _recordActiveDay(preferences, platform, DateTime(2026, 1, 1));

    final insufficientDays = ReviewPromptService(
      platform: platform,
      now: () => DateTime(2026, 1, 10),
      versionLoader: () async => '1.0.0',
      noteCountLoader: () async => 20,
    );
    await insufficientDays.initialize(preferences: preferences);
    expect(await insufficientDays.isEligible(), isFalse);

    await _recordActiveDay(preferences, platform, DateTime(2026, 1, 11));
    final insufficientNotes = ReviewPromptService(
      platform: platform,
      now: () => DateTime(2026, 1, 12),
      versionLoader: () async => '1.0.0',
      noteCountLoader: () async => 4,
    );
    await insufficientNotes.initialize(preferences: preferences);
    expect(await insufficientNotes.isEligible(), isFalse);
  });

  test('enforces the 120-day cooldown even after an app update', () async {
    final preferences = await SharedPreferences.getInstance();
    final platform = _FakeReviewPlatform();
    await _recordActiveDay(preferences, platform, DateTime(2026, 1, 1));
    await _recordActiveDay(preferences, platform, DateTime(2026, 1, 2));
    await _recordActiveDay(preferences, platform, DateTime(2026, 1, 3));

    final first = ReviewPromptService(
      platform: platform,
      now: () => DateTime(2026, 1, 8),
      versionLoader: () async => '1.0.0',
      noteCountLoader: () async => 5,
    );
    await first.initialize(preferences: preferences);
    expect(
      await first.recordPositiveMilestone(ReviewMilestone.reminderScheduled),
      isTrue,
    );

    final tooSoon = ReviewPromptService(
      platform: platform,
      now: () => DateTime(2026, 4, 1),
      versionLoader: () async => '1.1.0',
      noteCountLoader: () async => 5,
    );
    await tooSoon.initialize(preferences: preferences);
    expect(await tooSoon.isEligible(), isFalse);

    final afterCooldown = ReviewPromptService(
      platform: platform,
      now: () => DateTime(2026, 5, 9),
      versionLoader: () async => '1.1.0',
      noteCountLoader: () async => 5,
    );
    await afterCooldown.initialize(preferences: preferences);
    expect(await afterCooldown.isEligible(), isTrue);
  });

  test('does not request when the native prompt is unavailable', () async {
    final preferences = await SharedPreferences.getInstance();
    final platform = _FakeReviewPlatform(available: false);
    await _recordActiveDay(preferences, platform, DateTime(2026, 1, 1));
    await _recordActiveDay(preferences, platform, DateTime(2026, 1, 2));
    await _recordActiveDay(preferences, platform, DateTime(2026, 1, 3));
    final service = ReviewPromptService(
      platform: platform,
      now: () => DateTime(2026, 1, 8),
      versionLoader: () async => '1.0.0',
      noteCountLoader: () async => 5,
    );
    await service.initialize(preferences: preferences);

    expect(
      await service.recordPositiveMilestone(ReviewMilestone.googleKeepImport),
      isFalse,
    );
    expect(platform.requestCount, 0);
  });

  test('a failed native request does not consume cooldown state', () async {
    final preferences = await SharedPreferences.getInstance();
    final platform = _FakeReviewPlatform(requestFailuresRemaining: 1);
    await _recordActiveDay(preferences, platform, DateTime(2026, 1, 1));
    await _recordActiveDay(preferences, platform, DateTime(2026, 1, 2));
    await _recordActiveDay(preferences, platform, DateTime(2026, 1, 3));
    final service = ReviewPromptService(
      platform: platform,
      now: () => DateTime(2026, 1, 8),
      versionLoader: () async => '1.0.0',
      noteCountLoader: () async => 5,
    );
    await service.initialize(preferences: preferences);

    expect(
      await service.recordPositiveMilestone(ReviewMilestone.googleKeepImport),
      isFalse,
    );
    expect(platform.requestCount, 1);
    expect(
      await service.recordPositiveMilestone(ReviewMilestone.googleKeepImport),
      isTrue,
    );
    expect(platform.requestCount, 2);
  });

  test('concurrent milestones share one successful review request', () async {
    final preferences = await SharedPreferences.getInstance();
    final requestStarted = Completer<void>();
    final requestBarrier = Completer<void>();
    final platform = _FakeReviewPlatform(
      requestStarted: requestStarted,
      requestBarrier: requestBarrier,
    );
    await _recordActiveDay(preferences, platform, DateTime(2026, 1, 1));
    await _recordActiveDay(preferences, platform, DateTime(2026, 1, 2));
    await _recordActiveDay(preferences, platform, DateTime(2026, 1, 3));
    final service = ReviewPromptService(
      platform: platform,
      now: () => DateTime(2026, 1, 8),
      versionLoader: () async => '1.0.0',
      noteCountLoader: () async => 5,
    );
    await service.initialize(preferences: preferences);

    final first = service.recordPositiveMilestone(ReviewMilestone.dataExport);
    await requestStarted.future;
    final second = service.recordPositiveMilestone(
      ReviewMilestone.reminderScheduled,
    );
    requestBarrier.complete();

    expect(await first, isTrue);
    expect(await second, isFalse);
    expect(platform.requestCount, 1);
  });
}

Future<void> _recordActiveDay(
  SharedPreferences preferences,
  ReviewPromptPlatform platform,
  DateTime day,
) async {
  final service = ReviewPromptService(
    platform: platform,
    now: () => day,
    versionLoader: () async => 'setup',
    noteCountLoader: () async => 0,
  );
  await service.initialize(preferences: preferences);
}

class _FakeReviewPlatform implements ReviewPromptPlatform {
  final bool available;
  final Completer<void>? requestStarted;
  final Completer<void>? requestBarrier;
  int requestFailuresRemaining;
  int requestCount = 0;
  int listingCount = 0;

  _FakeReviewPlatform({
    this.available = true,
    this.requestStarted,
    this.requestBarrier,
    this.requestFailuresRemaining = 0,
  });

  @override
  bool get supportsPrompt => true;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<void> openStoreListing() async {
    listingCount++;
  }

  @override
  Future<void> requestReview() async {
    requestCount++;
    if (requestFailuresRemaining > 0) {
      requestFailuresRemaining--;
      throw StateError('Review prompt failed');
    }
    requestStarted?.complete();
    await requestBarrier?.future;
  }
}
