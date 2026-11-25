// Native share-sheet acceptance fixture. Build only on disposable simulators.
// Uses the production intent handler, image preparation, encrypted file storage,
// and SQLite persistence. Only the unrelated cloud-sync trigger is disabled.
import 'dart:async';

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:better_keep/components/image_share_progress.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/l10n/app_localization_config.dart';
import 'package:better_keep/services/database.dart';
import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/intent_handler_service.dart';
import 'package:better_keep/services/local_data_encryption.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/file_utils.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!LocalDataEncryption.isAvailable) {
    throw StateError(
      'Build this simulator fixture with a test-only LOCAL_DATA_KEY',
    );
  }
  await AppState.init();
  await LocalDataEncryption.instance.setFilesEnabled(true);
  await initDatabase();
  Note.syncTriggerOverride = () {};
  runApp(const _ShareAcceptanceApp());
}

class _ShareAcceptanceApp extends StatefulWidget {
  const _ShareAcceptanceApp();

  @override
  State<_ShareAcceptanceApp> createState() => _ShareAcceptanceState();
}

class _ShareAcceptanceState extends State<_ShareAcceptanceApp>
    with WidgetsBindingObserver {
  List<Note> notes = [];
  bool loaded = false;
  Future<void> refresh = Future.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Note.on('created', _changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
      IntentHandlerService.instance.init();
    });
  }

  void _changed(NoteEvent event) => _refresh();

  void _refresh() {
    refresh = refresh.then((_) async {
      final current = await Note.get(NoteType.all);
      final report = <Map<String, dynamic>>[];
      for (final note in current) {
        final images = <Map<String, dynamic>>[];
        for (final image in note.images) {
          final resolvedPath = await FileUtils.fixPath(image.src);
          final bytes = await readEncryptedBytes(resolvedPath);
          final codec = await ui.instantiateImageCodec(bytes);
          final frame = await codec.getNextFrame();
          final encrypted = await isFileEncrypted(resolvedPath);
          if (!encrypted) {
            throw StateError('Shared attachment was not encrypted');
          }
          images.add({
            'path': resolvedPath,
            'index': image.index,
            'width': frame.image.width,
            'height': frame.image.height,
            'size': bytes.length,
            'jpeg': bytes[0] == 0xff && bytes[1] == 0xd8,
            'encrypted': encrypted,
          });
          frame.image.dispose();
          codec.dispose();
        }
        report.add({'id': note.id, 'syncId': note.syncId, 'images': images});
      }
      final directory = await (await fileSystem()).documentDir;
      await File('$directory/image-share-verification.json')
          .writeAsString(jsonEncode(report));
      debugPrint('IMAGE_SHARE_VERIFIED: ${jsonEncode(report)}');
      if (mounted) {
        setState(() {
          notes = current;
          loaded = true;
        });
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(
        IntentHandlerService.instance.checkPendingIntents().then(
          (_) => _refresh(),
        ),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Note.off('created', _changed);
    IntentHandlerService.instance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    builder: (context, child) => ImageShareProgress(
      busy: IntentHandlerService.instance.importingImages,
      child: child!,
    ),
    navigatorKey: AppState.navigatorKey,
    localizationsDelegates: betterKeepLocalizationDelegates,
    supportedLocales: betterKeepSupportedLocales,
    scaffoldMessengerKey: AppState.scaffoldMessengerKey,
    home: Scaffold(
      appBar: AppBar(
        title: Text(
          loaded
              ? 'Verified image notes: ${notes.length}'
              : 'Verifying image notes…',
        ),
      ),
      body: ListView(
        children: [
          for (final note in notes)
            Card(
              child: Column(
                children: [
                  Text('Note ${note.id}: ${note.images.length} image(s)'),
                  for (final image in note.images)
                    FutureBuilder(
                      future: FileUtils.fixPath(image.src)
                          .then(readEncryptedBytes),
                      builder: (context, snapshot) => snapshot.hasData
                          ? Image.memory(snapshot.data!, height: 180)
                          : const SizedBox(height: 180),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
