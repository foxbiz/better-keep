import 'package:better_keep/models/note.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ReviewMilestone { reminderScheduled, googleKeepImport, dataExport }

abstract interface class ReviewPromptPlatform {
  bool get supportsPrompt;

  Future<bool> isAvailable();

  Future<void> requestReview();

  Future<void> openStoreListing();
}

class NativeReviewPromptPlatform implements ReviewPromptPlatform {
  final InAppReview review;

  NativeReviewPromptPlatform({InAppReview? review})
    : review = review ?? InAppReview.instance;

  @override
  bool get supportsPrompt =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  Future<bool> isAvailable() =>
      supportsPrompt ? review.isAvailable() : Future.value(false);

  @override
  Future<void> requestReview() => review.requestReview();

  @override
  Future<void> openStoreListing() {
    if (kIsWeb) return Future.value();
    return review.openStoreListing(
      appStoreId: '6759548198',
      microsoftStoreId: '9PHT5C6WK6Q1',
    );
  }
}

class ReviewPromptService {
  static const _firstLaunchKey = 'review_first_launch_v1';
  static const _activeDaysKey = 'review_active_days_v1';
  static const _lastRequestKey = 'review_last_request_v1';
  static const _lastVersionKey = 'review_last_version_v1';
  static const minimumAge = Duration(days: 7);
  static const cooldown = Duration(days: 120);
  static const minimumNotes = 5;
  static const minimumActiveDays = 3;

  static final ReviewPromptService instance = ReviewPromptService();

  final ReviewPromptPlatform platform;
  final DateTime Function() now;
  final Future<String> Function() versionLoader;
  final Future<int> Function() noteCountLoader;
  SharedPreferences? _preferences;
  bool _initialized = false;
  bool _requestInProgress = false;
  bool _requestedThisSession = false;

  ReviewPromptService({
    ReviewPromptPlatform? platform,
    DateTime Function()? now,
    Future<String> Function()? versionLoader,
    Future<int> Function()? noteCountLoader,
  }) : platform = platform ?? NativeReviewPromptPlatform(),
       now = now ?? DateTime.now,
       versionLoader =
           versionLoader ??
           (() async => (await PackageInfo.fromPlatform()).version),
       noteCountLoader = noteCountLoader ?? (() => Note.count(NoteType.all));

  Future<void> initialize({SharedPreferences? preferences}) async {
    if (_initialized) return;
    _preferences ??= preferences ?? await AppState.prefs;
    final prefs = _preferences!;
    final current = now();
    if (!prefs.containsKey(_firstLaunchKey)) {
      await prefs.setString(_firstLaunchKey, current.toIso8601String());
    }

    final today = _dateKey(current);
    final activeDays = prefs.getStringList(_activeDaysKey) ?? <String>[];
    if (!activeDays.contains(today)) {
      activeDays.add(today);
      activeDays.sort();
      final bounded = activeDays.length > 30
          ? activeDays.sublist(activeDays.length - 30)
          : activeDays;
      await prefs.setStringList(_activeDaysKey, bounded);
    }
    _initialized = true;
  }

  Future<bool> recordPositiveMilestone(ReviewMilestone milestone) async {
    if (_requestInProgress || _requestedThisSession) return false;
    _requestInProgress = true;
    try {
      await initialize();
      if (!platform.supportsPrompt) return false;
      if (!await isEligible()) return false;
      if (!await platform.isAvailable()) return false;
      final current = now();
      final version = await versionLoader();
      await platform.requestReview();
      _requestedThisSession = true;
      await _persistSuccessfulRequest(current: current, version: version);
      return true;
    } catch (error, stackTrace) {
      await AppLogger.error(
        'Review prompt failed for ${milestone.name}',
        error,
        stackTrace,
      );
      return false;
    } finally {
      _requestInProgress = false;
    }
  }

  Future<void> _persistSuccessfulRequest({
    required DateTime current,
    required String version,
  }) async {
    try {
      final prefs = _preferences!;
      final results = await Future.wait([
        prefs.setString(_lastRequestKey, current.toIso8601String()),
        prefs.setString(_lastVersionKey, version),
      ]);
      if (results.any((saved) => !saved)) {
        await AppLogger.error('Review prompt cooldown could not be saved');
      }
    } catch (error, stackTrace) {
      await AppLogger.error(
        'Review prompt cooldown could not be saved',
        error,
        stackTrace,
      );
    }
  }

  @visibleForTesting
  Future<bool> isEligible() async {
    await initialize();
    final prefs = _preferences!;
    final current = now();
    final firstLaunch = DateTime.tryParse(
      prefs.getString(_firstLaunchKey) ?? '',
    );
    if (firstLaunch == null || current.difference(firstLaunch) < minimumAge) {
      return false;
    }
    final activeDays = prefs.getStringList(_activeDaysKey) ?? const [];
    if (activeDays.toSet().length < minimumActiveDays) return false;
    if (await noteCountLoader() < minimumNotes) return false;

    final version = await versionLoader();
    if (prefs.getString(_lastVersionKey) == version) return false;
    final lastRequest = DateTime.tryParse(
      prefs.getString(_lastRequestKey) ?? '',
    );
    if (lastRequest != null && current.difference(lastRequest) < cooldown) {
      return false;
    }
    return true;
  }

  Future<void> openStoreListing() => platform.openStoreListing();

  String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
