// Platform-selecting entry point for file system access.
//
// This exposes a single factory [fileSystem] that yields a [FileSystem]
// backed by a web implementation (OPFS with IndexedDB fallback) on web and a
// dart:io-backed implementation on other platforms. Unsupported platforms throw
// [UnsupportedError].

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueNotifier, debugPrint, kIsWeb;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'file_system_base.dart';
import 'file_system_stub.dart'
    if (dart.library.html) 'web_file_system.dart'
    if (dart.library.io) 'file_system_io.dart'
    as impl;
import 'firebase_backend.dart';
import 'scoped_file_system.dart';
import 'firebase_scoped_preferences.dart';

export 'file_system_base.dart';

SharedPreferences? _preferences;
final localLibraryUnavailable = ValueNotifier<bool>(false);

// Foreground startup and background reminder isolates both initialize AppState.
void initializeAccountFileStorage(SharedPreferences preferences) {
  _preferences = preferences;
}

FirebaseLocalDataScope get _scope {
  final prefs = _preferences;
  if (prefs != null) {
    return FirebaseScopedPreferences.scopeForPreferences(prefs);
  }
  return FirebaseBackend.isConfigured
      ? FirebaseBackend.localDataScope
      : FirebaseLocalDataScope.live;
}

Future<FileSystem> _environmentFiles(FirebaseLocalDataScope scope) async {
  final base = await impl.createFileSystem();
  return scope.isEmulator
      ? ScopedFileSystem(base, directoryName: scope.fileDirectoryName)
      : base;
}

/// Existing installations keep their original paths until the first sign-out.
Future<FileSystem> fileSystem() async {
  final prefs = _preferences;
  if (prefs == null) {
    // Background entry points can open an existing absolute file without
    // initializing UI services. Resolve ownership before supplying any root.
    return ScopedFileSystem.resolving(await impl.createFileSystem(), () async {
      final stored = _preferences ??= await SharedPreferences.getInstance();
      final scope = FirebaseScopedPreferences.scopeForPreferences(stored);
      return p.join(
        scope.fileDirectoryName,
        _cleanup(scope).directoryName(stored),
      );
    });
  }
  final scope = _scope;
  try {
    return _cleanup(scope).activeFiles(prefs, await _environmentFiles(scope));
  } on LocalLibraryUnavailable {
    localLibraryUnavailable.value = true;
    rethrow;
  }
}

final _cleaners = <FirebaseLocalDataScope, AccountFileCleanup>{};
AccountFileCleanup _cleanup(FirebaseLocalDataScope scope) =>
    _cleaners.putIfAbsent(
      scope,
      () => AccountFileCleanup(scope.name, () => _environmentFiles(scope)),
    );

void verifyAccountFileDirectory(SharedPreferences prefs) {
  _cleanup(_scope).directoryName(prefs);
  localLibraryUnavailable.value = false;
}

class LocalLibraryUnavailable implements Exception {
  const LocalLibraryUnavailable();
  @override
  String toString() => 'Could not identify the active local library';
}

String? currentAccountFileGeneration(SharedPreferences prefs) =>
    _cleanup(FirebaseScopedPreferences.scopeForPreferences(prefs))
        ._knownGeneration(prefs);

bool canResumeFileRotation(SharedPreferences prefs, String id) =>
    _cleanup(FirebaseScopedPreferences.scopeForPreferences(prefs))
        .canRotateTo(prefs, id);

Future<void> retireAccountFiles(SharedPreferences prefs, String next) async {
  await _cleanup(_scope).retire(prefs, next);
  localLibraryUnavailable.value = false;
}

Future<void> resumeAccountFileCleanup(SharedPreferences prefs) =>
    _cleanup(_scope).resume(prefs);

const _legacy = 'legacy';
final _legacyGalleryPng = RegExp(r'^sketch_(?:null|[0-9]+)_-?[0-9]+\.png$');
final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
String _directory(String id) {
  if (!_uuid.hasMatch(id)) throw StateError('Invalid local file generation');
  return 'bk-library-$id';
}

class AccountFileCleanup {
  AccountFileCleanup(String namespace, this._files)
    : _activeKey = 'account_files.$namespace.active',
      _prefix = 'account_files.$namespace.retired.';
  final String _activeKey, _prefix;
  final Future<FileSystem> Function() _files;
  Future<void>? _worker;
  Timer? _retry;
  int _retryMinutes = 1;

  SharedPreferences? _verifiedLegacyPrefs;
  int? _verifiedLegacyRevision;

  // Null means ownership is ambiguous. Only a pristine namespace uses legacy.
  String? _knownGeneration(
    SharedPreferences prefs, {
    bool reuseLegacy = false,
  }) {
    final primary = prefs.get(_activeKey);
    final backup = prefs.get('$_activeKey.backup');
    String? usable(Object? id) =>
        id is String && _uuid.hasMatch(id) && !prefs.containsKey('$_prefix$id')
        ? id
        : null;
    final current = usable(primary);
    final fallback = usable(backup);
    if (primary == null &&
        backup == null &&
        !prefs.containsKey('$_activeKey.rotated') &&
        !prefs.containsKey('$_prefix$_legacy')) {
      final revision = FirebaseScopedPreferences.cacheRevision;
      if (reuseLegacy &&
          revision != null &&
          identical(_verifiedLegacyPrefs, prefs) &&
          _verifiedLegacyRevision == revision) {
        return _legacy;
      }
      if (!prefs.getKeys().any((key) => key.startsWith(_prefix))) {
        _verifiedLegacyPrefs = prefs;
        _verifiedLegacyRevision = revision;
        return _legacy;
      }
    }
    _verifiedLegacyPrefs = null;
    if (current != null && fallback != null && current != fallback) return null;
    return current ?? fallback;
  }

  String directoryName(SharedPreferences prefs, {bool reuseLegacy = false}) {
    final id = _knownGeneration(prefs, reuseLegacy: reuseLegacy);
    if (id == null) throw const LocalLibraryUnavailable();
    return id == _legacy ? '' : _directory(id);
  }

  FileSystem activeFiles(SharedPreferences prefs, FileSystem base) {
    final name = directoryName(prefs, reuseLegacy: true);
    return name.isEmpty ? base : ScopedFileSystem(base, directoryName: name);
  }

  bool canRotateTo(SharedPreferences prefs, Object? id) =>
      id is String && _uuid.hasMatch(id) && !prefs.containsKey('$_prefix$id');

  /// Persist retirement before switching the pointer. An interrupted sign-out
  /// replays the same next ID. This path never opens the attachment store.
  Future<void> retire(SharedPreferences prefs, String next) async {
    _directory(next);
    if (prefs.containsKey('$_prefix$next')) {
      throw StateError('Sign-out generation has already retired');
    }
    // Only a confirmed sign-out may abandon ambiguous metadata. Leave
    // unidentified files in place; never use unknown paths as deletion jobs.
    final old = _knownGeneration(prefs);
    _verifiedLegacyPrefs = null;
    if (old == null) {
      debugPrint(
        'Local file ownership is unknown. Unidentified directories were retained.',
      );
    }
    if (old != null &&
        old != next &&
        !await prefs.setBool('$_prefix$old', true)) {
      throw StateError('Could not record retired files');
    }
    if (!await prefs.setBool('$_activeKey.rotated', true) ||
        !await prefs.setString('$_activeKey.backup', next) ||
        !await prefs.setString(_activeKey, next)) {
      throw StateError('Could not isolate account files');
    }
  }

  /// Only retired roots can be removed. An interrupted batch is safe to replay.
  Future<void> resume(SharedPreferences prefs) {
    bool pending(String key) =>
        key.startsWith(_prefix) && prefs.get(key) == true;
    if (!prefs.getKeys().any(pending)) {
      _retry?.cancel();
      _retry = null;
      _retryMinutes = 1;
      return Future.value();
    }
    return _worker ??= Future<void>(() async {
      final attempted = <String>{};
      Object? failure;
      try {
        FileSystem? files;
        while (true) {
          // A retirement can be durable before its replacement is published.
          // Startup or the completing sign-out wakes the worker after handoff.
          final active = _knownGeneration(prefs);
          if (active == null) break;
          final jobs = prefs
              .getKeys()
              .where((key) => pending(key) && key != '$_prefix$active')
              .where(attempted.add)
              .toList();
          if (jobs.isEmpty) break;
          for (final job in jobs) {
            try {
              files ??= await _files();
              await _remove(files, job.substring(_prefix.length));
              // Preserve retirement evidence if a stale pointer still names
              // this folder. Otherwise deleting the job would revive it.
              final id = job.substring(_prefix.length);
              final referenced =
                  prefs.get(_activeKey) == id ||
                  prefs.get('$_activeKey.backup') == id;
              final acknowledged = referenced
                  ? await prefs.setBool(job, false)
                  : await prefs.remove(job);
              if (!acknowledged) {
                throw StateError('Could not acknowledge file cleanup');
              }
            } catch (error) {
              // One unavailable root must not hold up later sign-outs.
              failure = error;
            }
          }
        }
      } catch (error) {
        failure = error;
      } finally {
        _worker = null;
        if (failure != null) {
          if (_retry == null) {
            debugPrint(
              'Retired account file cleanup deferred (${failure.runtimeType})',
            );
          }
          _retry?.cancel();
          _retry = Timer(
            Duration(minutes: _retryMinutes),
            () => unawaited(resume(prefs)),
          );
          _retryMinutes = math.min(_retryMinutes * 2, 60);
        } else {
          _retryMinutes = 1;
          _retry?.cancel();
          _retry = null;
        }
      }
    });
  }

  Future<void> _remove(FileSystem files, String generation) async {
    if (generation == _legacy) {
      await _clearLegacyFiles(files);
      return;
    }
    final child = _directory(generation);
    final roots = {await files.documentDir, await files.cacheDir};
    await files.deleteTrees([for (final root in roots) p.join(root, child)]);
  }
}

/// The legacy roots are shared with plugins, preferences and SQLite. Remove
/// only names produced by Better Keep. New generations own entire subtrees.
Future<void> _clearLegacyFiles(FileSystem fs) async {
  const folders = {
    'external_sync',
    'external_sync_media',
    'audio',
    'audio_playback',
    'remote_sync_cache',
    'share_attachments',
  };
  final documents = await fs.documentDir;
  final cache = await fs.cacheDir;
  for (final root in {documents, cache}) {
    final paths = <String>[];
    for (final entry in await fs.list(root)) {
      final child = p.normalize(
        p.isAbsolute(entry) ? entry : p.join(root, entry),
      );
      if (p.dirname(child) != p.normalize(root)) continue;
      final name = p.basename(child);
      if (folders.contains(name) ||
          _uuid.hasMatch(name.split('.').first) ||
          (name.startsWith('profile_') && name.endsWith('.jpg')) ||
          (name.startsWith('better_keep_export_') && name.endsWith('.zip')) ||
          (root == cache &&
              ({'.txt', '.md', '.html'}.contains(p.extension(name)) ||
                  (!kIsWeb && _legacyGalleryPng.hasMatch(name))) &&
              await fs.isFile(child))) {
        paths.add(child);
      }
    }
    for (var i = 0; i < paths.length; i += 16) {
      await fs.deleteTrees(paths.sublist(i, math.min(i + 16, paths.length)));
    }
  }
}
