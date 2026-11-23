import 'dart:convert';

import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_table.dart';
import 'package:better_keep/l10n/app_localization_config.dart';
import 'package:better_keep/pages/note_editor/embeds/note_embed_builders.dart';
import 'package:better_keep/utils/quill_config.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/utils/encryption.dart' as pin;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final body in [
    '',
    '[]',
    '[{"insert":"Older note without final newline"}]',
    '[{"insert":"Title"},{"insert":"\\n","attributes":{"header":1}},{"insert":"Body\\n"}]',
    '[{"insert":"Title"},{"insert":"\\\\n","attributes":{"header":1}},{"insert":"Body"}]',
    '[{"insert":"Task"},{"insert":"\\n","attributes":{"list":"unchecked"}}]',
    '[{"insert":{"image":"attachment://legacy-image"}},{"insert":"\\n"}]',
  ]) {
    test('strict recovery keeps legacy body unchanged: $body', () async {
      final note = await Note.fromJsonAsync({'content': body}, strict: true);
      expect(note.content, body);
    });
  }

  test('legacy inline sketches, file sketches and both audio formats survive strict decoding', () async {
    final attachments = [
      {
        'type': 'sketch',
        'data': {
          'strokes': ['pen:4278190080:2.0:0,0;1,1'],
          'bgColor': 4294967295,
        },
      },
      {
        'type': 'sketch',
        'data': {
          'strokesFilePath': '/legacy/sketch.json',
          'previewImage': '/legacy/preview.png',
        },
      },
      {'type': 'audio', 'data': '/legacy/audio.mp3'},
      {
        'type': 'audio',
        'data': {'path': '/legacy/other.mp3', 'title': 'Recording'},
      },
    ];
    final note = await Note.fromJsonAsync({
      'attachments': jsonEncode(attachments),
    }, strict: true);
    expect(note.attachments, hasLength(4));
    expect(note.attachments[0].sketch!.strokes, hasLength(1));
    expect(note.attachments[1].sketch!.strokesFilePath, '/legacy/sketch.json');
    expect(note.attachments[1].sketch!.previewImage, '/legacy/preview.png');
    expect(note.attachments[2].recording!.src, '/legacy/audio.mp3');
    expect(note.attachments[3].recording!.title, 'Recording');
  });

  test('strict recovery leaves PIN content and legacy protected sketch sources opaque', () async {
    final note = await Note.fromJsonAsync({
      'locked': 1,
      'content': 'legacy-PIN-ciphertext',
      'attachments': jsonEncode([
        {
          'type': 'sketch',
          'data': {'encryptedStrokes': 'legacy-strokes'},
        },
        {
          'type': 'sketch',
          'data': {'encrypted_metadata': 'ENC:legacy-metadata'},
        },
      ]),
    }, strict: true);
    expect(note.content, 'legacy-PIN-ciphertext');
    expect(note.unlocked, isFalse);
    expect(note.attachments[0].sketch!.encryptedStrokes, 'legacy-strokes');
    expect(
      note.attachments[1].sketch!.encryptedMetadata,
      'ENC:legacy-metadata',
    );
  });

  for (final body in ['{broken-json', '[{"insert":"Legacy body"}]']) {
    test(
      'recovery validates PIN plaintext without rewriting it: $body',
      () async {
        Note.unlockPostAuthenticationOverride = (_, _) async {};
        addTearDown(() => Note.unlockPostAuthenticationOverride = null);
        final ciphertext = await pin.encrypt(body, '1234');
        final note = await Note.fromJsonAsync({
          'locked': 1,
          'content': ciphertext,
        }, strict: true);
        expect(note.content, ciphertext);
        await note.unlock('1234');
        expect(note.locked, isTrue);
        expect(note.unlocked, isTrue);
        if (body.startsWith('{')) {
          expect(note.validateReadableContent, throwsFormatException);
          await expectLater(
            note.decryptFields(strict: true),
            throwsFormatException,
          );
        } else {
          note.validateReadableContent();
          await note.decryptFields(strict: true);
        }
        expect(note.content, body);
      },
    );
  }

  for (final embed in [
    <String, dynamic>{},
    {'image': 'legacy', 'other': 'extra'},
  ]) {
    test('strict recovery rejects invalid embed cardinality: $embed', () async {
      final body = jsonEncode([
        {'insert': embed},
        {'insert': '\n'},
      ]);
      await expectLater(
        Note.fromJsonAsync({'content': body}, strict: true),
        throwsFormatException,
      );
      // Existing readers remain compatible; recovery never rewrites the source.
      expect((await Note.fromJsonAsync({'content': body})).content, body);
    });
  }

  final invalidEmbeds = <String, Map<String, dynamic>>{
    'attachment payload': {'note-attachment': 'not-a-map'},
    'attachment source': {
      'note-attachment': {'id': 'qa', 'src': 42},
    },
    'attachment editing identity': {
      'note-attachment': {'src': 'attachment://qa'},
    },
    'table dimensions': {
      'note-table': {'id': 'qa', 'rows': 0, 'columns': 1},
    },
    'table cell shape': {
      'note-table': {
        ..._table(),
        'cells': {'0:0': 'not-a-list'},
      },
    },
    'nested attachment source': {
      'note-table': _table(
        cells: {
          '0:0': [
            {
              'insert': {
                'note-attachment': {'id': 'qa', 'src': 42},
              },
            },
          ],
        },
      ),
    },
    'nested table coordinates': {
      'note-table': _table(
        cells: {
          '0:0': [
            {
              'insert': {
                'note-table': _table(
                  cells: {
                    'bad': [
                      {'insert': 'text'},
                    ],
                  },
                ),
              },
            },
          ],
        },
      ),
    },
    'cell Delta': {
      'note-table': _table(
        cells: {
          '0:0': [
            {'retain': 1},
          ],
        },
      ),
    },
    'image source': {'image': 42},
    'video source': {'video': null},
    'unsupported type': {'unregistered-embed': 'payload'},
  };
  for (final entry in invalidEmbeds.entries) {
    test(
      'strict recovery rejects ${entry.key} without rewriting source',
      () async {
        final body = jsonEncode([
          {'insert': entry.value},
          {'insert': '\n'},
        ]);
        await expectLater(
          Note.fromJsonAsync({'content': body}, strict: true),
          throwsFormatException,
        );
        expect((await Note.fromJsonAsync({'content': body})).content, body);
      },
    );
  }

  test(
    'strict recovery preserves legacy video and optional table sizing',
    () async {
      final body = jsonEncode([
        {
          'insert': {'video': 'https://example.invalid/legacy.mp4'},
        },
        {
          'insert': {
            'note-table': {
              ..._table(),
              'widths': {'0': 48},
              'heights': {'0': 32},
            },
          },
        },
      ]);
      expect(
        (await Note.fromJsonAsync({'content': body}, strict: true)).content,
        body,
      );
    },
  );

  final validEmbeds = {
    'missing attachment placeholder': {
      'note-attachment': {'id': 'qa', 'src': 'attachment://missing'},
    },
    'empty legacy table': {'note-table': _table()},
    'nested legacy table and attachment': {
      'note-table': _table(
        cells: {
          '0:0': [
            {
              'insert': {
                'note-table': _table(
                  cells: {
                    '0:0': [
                      {
                        'insert': 'Legacy cell without final newline',
                        'attributes': {'bold': true},
                      },
                      {
                        'insert': {
                          'note-attachment': {
                            'id': 'qa-cell',
                            'src': 'attachment://missing',
                          },
                        },
                      },
                    ],
                  },
                ),
              },
            },
          ],
        },
      ),
    },
  };
  for (final entry in validEmbeds.entries) {
    testWidgets('strict recovery preserves and renders ${entry.key}', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await AppState.init(prefs: await SharedPreferences.getInstance());
      final ops = [
        {'insert': entry.value},
        {'insert': '\n'},
      ];
      final body = jsonEncode(ops);
      final note = await Note.fromJsonAsync({'content': body}, strict: true);
      expect(note.content, body);
      final controller = QuillController(
        document: documentFromJsonSafe(ops),
        selection: const TextSelection.collapsed(offset: 0),
        readOnly: true,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: betterKeepLocalizationDelegates,
          supportedLocales: betterKeepSupportedLocales,
          home: Scaffold(
            body: QuillEditor.basic(
              controller: controller,
              config: QuillEditorConfig(
                embedBuilders: noteEmbedBuilders(note: note),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(note.content, body);
    });
  }

  test('strict sketch parsing rejects malformed data while default reader stays compatible', () {
    final malformed = {
      'strokesFilePath': '/legacy/keep.json',
      'aspectRatio': 'bad',
    };
    expect(
      () => SketchData.fromJson(malformed, strict: true),
      throwsFormatException,
    );
    expect(SketchData.fromJson(malformed).strokesFilePath, isNull);
  });
}

Map<String, dynamic> _table({Map<String, List<dynamic>> cells = const {}}) =>
    NoteTableData(id: 'qa-table', rows: 1, columns: 1, cells: cells).toJson();
