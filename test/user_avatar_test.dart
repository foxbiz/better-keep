import 'dart:io';

import 'package:better_keep/components/user_avatar.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as path;

import 'support/offline_firebase.dart';
import 'support/avatar_http.dart';

final class _DirectoryListings extends IOOverrides {
  final counts = <String, int>{};
  @override
  Directory createDirectory(String path) =>
      _CountedDirectory(super.createDirectory(path), counts);
}

class _CountedDirectory extends Fake implements Directory {
  _CountedDirectory(this.directory, this.counts);
  final Directory directory;
  final Map<String, int> counts;
  @override
  String get path => directory.path;
  @override
  Future<bool> exists() => directory.exists();
  @override
  Future<Directory> create({bool recursive = false}) =>
      directory.create(recursive: recursive);
  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) {
    counts.update(path, (count) => count + 1, ifAbsent: () => 1);
    return directory.list(recursive: recursive, followLinks: followLinks);
  }
}

final class _PartialAvatarWrite extends IOOverrides {
  String? failedPath;
  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path.contains(RegExp(r'[\\/]profile_'))
        ? _PartialAvatarFile(file, this)
        : file;
  }
}

class _PartialAvatarFile extends Fake implements File {
  _PartialAvatarFile(this.file, this.owner);
  final File file;
  final _PartialAvatarWrite owner;
  @override
  Directory get parent => file.parent;
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    owner.failedPath = file.path;
    await file.writeAsBytes(bytes.take(4).toList(), mode: mode, flush: flush);
    throw const FileSystemException('fixture partial avatar write');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late OfflineFirebase backend;
  late AvatarHttp http;
  late HttpOverrides? previous;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bkn-avatar-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
    SharedPreferences.setMockInitialValues({});
    await AppState.init();
    backend = OfflineFirebase()..configure();
    (backend.auth.currentUser! as OfflineUser).photoURL =
        'https://example.invalid/${directory.path.hashCode}.png';
    UserAvatar.invalidateCache();
    previous = HttpOverrides.current;
    http = AvatarHttp();
    HttpOverrides.global = http;
  });
  tearDown(() async {
    HttpOverrides.global = previous;
    UserAvatar.invalidateCache();
    await backend.auth.changes.close();
    backend.firebaseSync.dispose();
    FirebaseBackend.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await directory.delete(recursive: true);
  });

  test(
    'startup and widget share one optional download and close its client',
    () async {
      final startup = AuthService.ensureProfileImageCached();
      final avatar = UserAvatar.preloadAvatar();
      await pumpEventQueue();
      expect(http.clients, hasLength(1));
      http.clients.single.response.complete(AvatarResponse());
      await Future.wait([startup, avatar]);
      expect(http.clients.single.requests, 1);
      expect(http.clients.single.closed, isTrue);
      expect(await File(AuthService.localPhotoPath!).readAsBytes(), avatarPng);
      final prefs = await AppState.prefs;
      expect(prefs.containsKey('user_local_photo'), isFalse);
      expect(prefs.containsKey('user_photoURL_downloaded'), isFalse);
      await AuthService.ensureProfileImageCached();
      expect(
        http.clients,
        hasLength(1),
        reason: 'A valid disk cache requires no HTTP client',
      );
      backend.auth.currentUser = OfflineUser('no-photo-account');
      expect(
        AuthService.localPhotoPath,
        isNull,
        reason: 'A new account cannot reuse another account photo',
      );
    },
  );

  test(
    'avatar URL changes prune only obsolete files for the same account',
    () async {
      final listings = _DirectoryListings();
      Future<String> cachePhoto() => IOOverrides.runWithIOOverrides(() async {
        final load = AuthService.ensureProfileImageCached();
        await pumpEventQueue();
        http.clients.last.response.complete(AvatarResponse());
        await load;
        return AuthService.localPhotoPath!;
      }, listings);

      final firstUser = backend.auth.currentUser! as OfflineUser;
      final oldPath = await cachePhoto();
      expect(
        File(oldPath).parent.path,
        path.join(directory.path, 'profile_cache'),
      );
      final legacy = File('${directory.path}/profile_${firstUser.uid}.jpg');
      await legacy.writeAsBytes(avatarPng);
      backend.auth.currentUser = OfflineUser('account-b')
        ..photoURL = 'https://example.invalid/b.png';
      final otherPath = await cachePhoto();
      final unrelated = File(
        '${File(oldPath).parent.path}/profile_unowned.jpg',
      );
      await unrelated.writeAsString('unrelated file');

      backend.auth.currentUser = firstUser;
      firstUser.photoURL = 'https://example.invalid/replacement.png';
      final replacement = await cachePhoto();
      expect(replacement, isNot(oldPath));
      expect(await File(oldPath).exists(), isFalse);
      expect(listings.counts.keys, [
        path.join(directory.path, 'profile_cache'),
      ], reason: 'Pruning must never enumerate the note/attachment root');
      expect(listings.counts.values.single, greaterThan(0));
      expect(await File(replacement).readAsBytes(), avatarPng);
      expect(await File(otherPath).readAsBytes(), avatarPng);
      expect(await unrelated.readAsString(), 'unrelated file');
      expect(await directory.exists(), isTrue);
      expect(
        await legacy.readAsBytes(),
        avatarPng,
        reason: 'URL pruning must preserve old-style root avatars',
      );

      // A failed replacement must retain the last usable photo on disk.
      firstUser.photoURL = 'https://example.invalid/unavailable.png';
      final failed = AuthService.ensureProfileImageCached();
      await pumpEventQueue();
      http.clients.last.response.complete(AvatarResponse(statusCode: 503));
      await failed;
      expect(await File(replacement).exists(), isTrue);
      expect(AuthService.localPhotoPath, replacement);

      firstUser.photoURL = 'https://example.invalid/replacement.png';
      await AuthService.ensureProfileImageCached();
      expect(
        http.clients,
        hasLength(4),
        reason: 'Reuse the surviving disk cache',
      );
    },
  );

  test(
    'a failed avatar write cannot poison the next disk cache lookup',
    () async {
      final partial = _PartialAvatarWrite();
      await IOOverrides.runWithIOOverrides(() async {
        final load = AuthService.ensureProfileImageCached();
        await pumpEventQueue();
        http.clients.single.response.complete(AvatarResponse());
        await load;
      }, partial);
      expect(partial.failedPath, isNotNull);
      expect(await File(partial.failedPath!).exists(), isFalse);

      final retry = AuthService.ensureProfileImageCached();
      await pumpEventQueue();
      expect(
        http.clients,
        hasLength(2),
        reason: 'Retry must fetch a complete image',
      );
      http.clients.last.response.complete(AvatarResponse());
      await retry;
      expect(await File(AuthService.localPhotoPath!).readAsBytes(), avatarPng);
    },
  );

  test('stalled optional photo times out and releases its client', () async {
    final load = AuthService.ensureProfileImageCached();
    await pumpEventQueue();
    expect(http.clients, hasLength(1));
    await load.timeout(const Duration(seconds: 7));
    expect(http.clients.single.closed, isTrue);
    http.clients.single.response.complete(AvatarResponse());
    await pumpEventQueue();
    expect(
      await directory
          .list(recursive: true)
          .where((file) => file is File && file.path.endsWith('.jpg'))
          .toList(),
      isEmpty,
    );
  });

  testWidgets(
    'an old account download cannot replace the next account avatar',
    (tester) async {
      await tester.runAsync(() async {
        final first = UserAvatar.preloadAvatar();
        await pumpEventQueue();
        final old = http.clients.single;
        backend.auth.currentUser = OfflineUser('account-b')
          ..photoURL = 'https://example.invalid/b.png';
        UserAvatar.invalidateCache();
        final second = UserAvatar.preloadAvatar();
        await pumpEventQueue();
        expect(http.clients, hasLength(2));
        http.clients.last.response.complete(AvatarResponse());
        await second;
        final path = AuthService.localPhotoPath;
        old.response.complete(AvatarResponse());
        await first;
        expect(AuthService.localPhotoPath, path);
        expect(path, contains(RegExp(r'[\\/]profile_')));
        expect(path, endsWith('.jpg'));
        expect(http.clients.every((client) => client.closed), isTrue);
      });
      await tester.pumpWidget(const MaterialApp(home: UserAvatar()));
      expect(
        tester.widget<CircleAvatar>(find.byType(CircleAvatar)).backgroundImage,
        isA<MemoryImage>(),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
