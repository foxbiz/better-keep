import 'dart:async';

import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/services/attachment_repair_coordinator.dart';
import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test(
    'reset cancels queued repairs and drops aliases across account/database scopes',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final otherDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(db.close);
      addTearDown(otherDb.close);
      final coordinator = AttachmentRepairCoordinator();
      final old = coordinator.capture(db);
      old.committed(1, {'old': 'fixed'});
      final entered = Completer<void>(), release = Completer<void>();
      final running = old.run(1, () async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final queued = old.run(
        1,
        () async => old.committed(1, {'fixed': 'late'}),
      );
      final cancelled = expectLater(
        queued,
        throwsA(isA<CloudOperationCancelled>()),
      );
      coordinator.reset();
      release.complete();
      await running;
      await cancelled;
      final attachments = [
        NoteAttachment.sketch(SketchData(backgroundImage: 'old')),
      ];
      expect(coordinator.capture(db).reconcile(1, attachments), isFalse);
      coordinator.capture(db).committed(1, {'old': 'new-session'});
      expect(coordinator.capture(otherDb).reconcile(1, attachments), isFalse);
      expect(attachments.single.sketch!.backgroundImage, 'old');
    },
  );

  test(
    'normalized and chained paths reconcile without replacing sketch metadata',
    () {
      final sketch = SketchData(
        strokesFilePath: 'old-strokes',
        backgroundImage: 'normalized-bg',
        encryptedStrokes: 'PIN-protected strokes',
      );
      final attachments = [NoteAttachment.sketch(sketch)];
      expect(
        replaceAttachmentPaths(attachments, {
          'old-strokes': 'first',
          'first': 'latest',
          'normalized-bg': 'new-bg',
          'removed-image': 'new-image',
        }),
        isTrue,
      );
      expect(attachments, hasLength(1));
      expect(identical(attachments.single.sketch, sketch), isTrue);
      expect(sketch.strokesFilePath, 'latest');
      expect(sketch.backgroundImage, 'new-bg');
      expect(sketch.encryptedStrokes, 'PIN-protected strokes');
    },
  );
}
