import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/local_data_encryption.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/encryption.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database database;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppState.init(prefs: await SharedPreferences.getInstance());
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await Note.createTable(database);
    await NoteSyncTrack.createTable(database);
    AppState.db = database;
    Note.pinContentEncryptOverride = null;
    Note.pinContentDecryptOverride = null;
    Note.pinAttachmentDecryptOverride = null;
    Note.unlockPostAuthenticationOverride = null;
  });

  tearDown(() async {
    Note.pinContentEncryptOverride = null;
    Note.pinContentDecryptOverride = null;
    Note.pinAttachmentDecryptOverride = null;
    Note.unlockPostAuthenticationOverride = null;
    await database.close();
  });

  test('failed unlock leaves the protected session state untouched', () async {
    const password = '1234';
    final protectedContent = await encrypt(_content('secret'), password);
    final note = Note(locked: true, content: protectedContent);
    Note.pinContentDecryptOverride = (_, _) async {
      throw StateError('injected decryption failure');
    };

    await expectLater(
      note.unlock(password),
      throwsA(isA<NoteUnlockException>()),
    );

    expect(note.content, protectedContent);
    expect(note.locked, isTrue);
    expect(note.unlocked, isFalse);
    expect(note.password, isNull);
  });

  test('unlock does not overwrite protected state changed in flight', () async {
    const password = '1234';
    final protectedContent = await encrypt(_content('first'), password);
    final replacementContent = await encrypt(_content('second'), password);
    final note = Note(locked: true, content: protectedContent);
    final decryptionStarted = Completer<void>();
    final releaseDecryption = Completer<void>();
    Note.pinContentDecryptOverride = (content, pin) async {
      decryptionStarted.complete();
      await releaseDecryption.future;
      return decrypt(content, pin);
    };

    final unlocking = note.unlock(password);
    await decryptionStarted.future;
    note.content = replacementContent;
    releaseDecryption.complete();

    await expectLater(unlocking, throwsA(isA<NoteUnlockException>()));
    expect(note.content, replacementContent);
    expect(note.unlocked, isFalse);
    expect(note.password, isNull);
  });

  test('successful unlock keeps a consistent encrypted-save session', () async {
    const password = '1234';
    final plainContent = _content('secret');
    final protectedContent = await encrypt(plainContent, password);
    final note = Note(locked: true, content: protectedContent);
    await note.unlock(password);

    expect(note.content, plainContent);
    expect(note.locked, isTrue);
    expect(note.unlocked, isTrue);
    expect(note.password, password);

    final row = await note.toJsonAsync();
    final serializedContent = await LocalDataEncryption.instance.decryptString(
      row['content']! as String,
    );
    expect(serializedContent, isNot(plainContent));
    expect(await decrypt(serializedContent, password), plainContent);
  });

  test(
    'unexpected post-authentication errors do not undo the session',
    () async {
      const password = '1234';
      final plainContent = _content('secret');
      final note = Note(
        locked: true,
        content: await encrypt(plainContent, password),
      );
      Note.unlockPostAuthenticationOverride = (_, _) async {
        throw StateError('injected post-authentication failure');
      };

      await note.unlock(password);

      expect(note.content, plainContent);
      expect(note.unlocked, isTrue);
      expect(note.password, password);
    },
  );

  test('password clearing waits for an in-flight unlock', () async {
    const password = '1234';
    final plainContent = _content('secret');
    final protectedContent = await encrypt(plainContent, password);
    final note = Note(locked: true, content: protectedContent);
    final decryptionStarted = Completer<void>();
    final releaseDecryption = Completer<void>();
    var decryptionCalls = 0;
    Note.pinContentDecryptOverride = (content, pin) async {
      decryptionCalls++;
      if (decryptionCalls == 1) {
        decryptionStarted.complete();
        await releaseDecryption.future;
      }
      return decrypt(content, pin);
    };

    final unlocking = note.unlock(password);
    await decryptionStarted.future;
    final clearing = note.clearPassword();
    releaseDecryption.complete();
    await unlocking;
    await clearing;

    expect(note.locked, isTrue);
    expect(note.unlocked, isFalse);
    expect(note.password, isNull);
    expect(note.content, isNot(plainContent));
    Note.pinContentDecryptOverride = null;
    await note.unlock(password);
    expect(note.content, plainContent);
  });

  test(
    'unchanged note can reopen on the same instance after PIN is forgotten',
    () async {
      const password = '1234';
      final plainContent = _content('secret');
      final note = Note(
        locked: true,
        title: 'Locked',
        content: await encrypt(plainContent, password),
      );

      await note.unlock(password);
      expect(note.content, plainContent);
      expect(note.unlocked, isTrue);

      await note.clearPassword();

      expect(note.unlocked, isFalse);
      expect(note.password, isNull);
      expect(note.content, isNot(plainContent));

      await note.unlock(password);
      expect(note.unlocked, isTrue);
      expect(note.content, plainContent);
    },
  );

  test('forgetting the PIN scrubs plaintext body caches in memory', () async {
    const password = '1234';
    final plainContent = jsonEncode([
      {
        'insert': 'private task\n',
        'attributes': {'list': 'unchecked'},
      },
    ]);
    final note = Note(
      locked: true,
      content: await encrypt(plainContent, password),
    );
    await note.unlock(password);
    note.plainText = 'private task';
    expect(note.checkboxCount.total, 1);

    await note.clearPassword();

    expect(note.unlocked, isFalse);
    expect(note.password, isNull);
    expect(note.plainText, isEmpty);
    expect(note.checkboxCount, (total: 0, checked: 0));
    expect(note.content, isNot(plainContent));
    await note.unlock(password);
    expect(note.content, plainContent);
  });

  test(
    'locked serialization does not mutate the live unlocked state',
    () async {
      const password = '1234';
      final plainContent = _content('secret');
      final note = Note(
        locked: true,
        title: 'Locked',
        content: await encrypt(plainContent, password),
      );
      await note.unlock(password);

      final row = await note.toJsonAsync();
      final pinProtectedContent = await LocalDataEncryption.instance
          .decryptString(row['content']! as String);

      expect(await decrypt(pinProtectedContent, password), plainContent);
      expect(note.content, plainContent);
      expect(note.unlocked, isTrue);
      expect(note.password, password);
    },
  );

  test(
    'verification failure leaves decrypted state and PIN untouched',
    () async {
      const password = '1234';
      final plainContent = _content('secret');
      final note = Note(
        locked: true,
        content: await encrypt(plainContent, password),
      );
      await note.unlock(password);
      Note.pinContentDecryptOverride = (_, _) async => 'different content';

      await expectLater(
        note.clearPassword(),
        throwsA(isA<NoteRelockException>()),
      );

      expect(note.content, plainContent);
      expect(note.unlocked, isTrue);
      expect(note.password, password);
    },
  );

  test(
    'edited plaintext is the content protected before forgetting the PIN',
    () async {
      const password = '1234';
      final originalContent = _content('original');
      final editedContent = _content('edited');
      final note = Note(
        locked: true,
        content: await encrypt(originalContent, password),
      );
      await note.unlock(password);
      note.content = editedContent;

      await note.clearPassword();
      await note.unlock(password);

      expect(note.content, editedContent);
    },
  );

  test('one concurrent content change is retried before re-locking', () async {
    const password = '1234';
    final firstContent = _content('first');
    final secondContent = _content('second');
    final note = Note(
      locked: true,
      content: await encrypt(firstContent, password),
    );
    await note.unlock(password);
    var encryptionCalls = 0;
    Note.pinContentEncryptOverride = (content, pin) async {
      encryptionCalls++;
      final result = await encrypt(content, pin);
      if (encryptionCalls == 1) note.content = secondContent;
      return result;
    };

    await note.clearPassword();

    expect(encryptionCalls, 2);
    expect(note.unlocked, isFalse);
    await note.unlock(password);
    expect(note.content, secondContent);
  });

  test(
    'repeated concurrent changes fail without partially clearing state',
    () async {
      const password = '1234';
      final plainContent = _content('secret');
      final note = Note(
        locked: true,
        content: await encrypt(plainContent, password),
      );
      await note.unlock(password);
      var encryptionCalls = 0;
      Note.pinContentEncryptOverride = (content, pin) async {
        encryptionCalls++;
        final result = await encrypt(content, pin);
        note.content = _content('change $encryptionCalls');
        return result;
      };

      await expectLater(
        note.clearPassword(),
        throwsA(isA<NoteRelockException>()),
      );

      expect(encryptionCalls, 2);
      expect(note.unlocked, isTrue);
      expect(note.password, password);
      expect(note.content, _content('change 2'));
    },
  );

  test(
    'serialization failure restores timestamp and leaves database unchanged',
    () async {
      const password = '1234';
      final plainContent = _content('secret');
      final originalUpdatedAt = DateTime.utc(2026, 7, 19, 10);
      final note = Note(
        id: 1,
        locked: true,
        title: 'Locked',
        content: await encrypt(plainContent, password),
        updatedAt: originalUpdatedAt,
      );
      await database.insert('note', await note.toJsonAsync());
      note.id = null;
      await note.unlock(password);
      note.id = 1;
      final rowBefore = (await database.query('note')).single;
      Note.pinContentEncryptOverride = (_, _) async {
        throw StateError('injected encryption failure');
      };

      expect(await note.save(), -1);

      expect(note.updatedAt, originalUpdatedAt);
      expect(note.unlocked, isTrue);
      expect(note.password, password);
      expect((await database.query('note')).single, rowBefore);
      expect(await NoteSyncTrack.getByLocalId(1), isNull);
    },
  );

  test(
    'unauthenticated editor snapshot cannot create an unlocked session',
    () async {
      final originalContent = await encrypt(_content('original'), '1234');
      final note = Note(
        locked: true,
        title: 'Original title',
        content: originalContent,
      );

      await expectLater(
        note.saveEditorSnapshot(
          title: 'Injected title',
          content: _content('injected'),
          plainText: 'injected',
        ),
        throwsA(isA<NoteRelockException>()),
      );

      expect(note.unlocked, isFalse);
      expect(note.password, isNull);
      expect(note.title, 'Original title');
      expect(note.content, originalContent);
    },
  );

  test('authenticated attachment decoder is session-bound', () async {
    const password = '1234';
    final note = Note(
      locked: true,
      content: await encrypt(_content('secret'), password),
    );
    final plaintext = Uint8List.fromList([1, 2, 3, 4]);
    final protected = await encryptBytesWithPassword(plaintext, password);
    await note.unlock(password);

    expect(await note.decryptAttachmentForSession(protected), plaintext);

    await note.clearPassword();
    await expectLater(
      note.decryptAttachmentForSession(protected),
      throwsA(isA<NoteUnlockException>()),
    );
  });

  test('authenticated sketch writes remain inside the PIN boundary', () async {
    const password = '1234';
    final note = Note(
      locked: true,
      content: await encrypt(_content('secret'), password),
    );
    await note.unlock(password);
    final tempDirectory = await Directory.systemTemp.createTemp(
      'locked-sketch-write-',
    );
    final filePath = '${tempDirectory.path}/preview.jpg';
    final plaintext = Uint8List.fromList([9, 8, 7, 6]);

    try {
      await note.writeAttachmentForSession(filePath, plaintext);

      final stored = await readEncryptedBytes(filePath);
      expect(isBytesPasswordEncrypted(stored), isTrue);
      expect(await decryptBytesWithPassword(stored, password), plaintext);

      await note.clearPassword();
      await expectLater(
        note.writeAttachmentForSession(filePath, plaintext),
        throwsA(isA<NoteRelockException>()),
      );
    } finally {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('attachment decode is rejected if the session ends in flight', () async {
    const password = '1234';
    final note = Note(
      locked: true,
      content: await encrypt(_content('secret'), password),
    );
    final plaintext = Uint8List.fromList([1, 2, 3, 4]);
    final protected = await encryptBytesWithPassword(plaintext, password);
    await note.unlock(password);
    final decodeStarted = Completer<void>();
    final releaseDecode = Completer<void>();
    Note.pinAttachmentDecryptOverride = (bytes, pin) async {
      decodeStarted.complete();
      await releaseDecode.future;
      return plaintext;
    };

    final decoding = note.decryptAttachmentForSession(protected);
    await decodeStarted.future;
    await note.clearPassword();
    releaseDecode.complete();

    await expectLater(decoding, throwsA(isA<NoteUnlockException>()));
  });
}

String _content(String text) => jsonEncode([
  {'insert': '$text\n'},
]);
