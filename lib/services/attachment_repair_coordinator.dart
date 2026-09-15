import 'dart:async';

import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/services/async_keyed_serializer.dart';
import 'package:better_keep/services/cloud_operation.dart';
import 'package:sqflite/sqflite.dart';

class AttachmentRepairNotification {
  const AttachmentRepairNotification(this.scope, this.noteId);

  final AttachmentRepairScope scope;
  final int noteId;
}

/// Session-only aliases let already loaded notes adopt committed repairs without
/// replacing their edited attachment lists. SQLite remains the restart source.
class AttachmentRepairCoordinator {
  static final instance = AttachmentRepairCoordinator();

  final _notifications =
      StreamController<AttachmentRepairNotification>.broadcast(sync: true);
  AttachmentRepairScope? _scope;

  Stream<AttachmentRepairNotification> get repairs => _notifications.stream;

  AttachmentRepairScope capture(Database database) {
    if (!identical(_scope?.database, database)) reset();
    return _scope ??= AttachmentRepairScope._(database, _notifications.add);
  }

  void reset() {
    _scope?._active = false;
    _scope?._replacements.clear();
    _scope = null;
  }
}

class AttachmentRepairScope {
  AttachmentRepairScope._(this.database, this._publish);

  final Database database;
  final void Function(AttachmentRepairNotification) _publish;
  final _mutations = AsyncKeyedSerializer<int>();
  final _replacements = <int, Map<String, String>>{};
  bool _active = true;

  bool get isCurrent => _active;

  Future<T> run<T>(int noteId, Future<T> Function() action) {
    final current = captureCloudOperation();
    return _mutations.run(
      noteId,
      () => runCloudOperation(() => _active && current(), action),
    );
  }

  /// Call only after the guarded note/reference transaction has committed and
  /// before releasing the mutation queue to a waiting editor save.
  void committed(int noteId, Map<String, String> replacements) {
    requireCloudOperation();
    if (!_active) return;
    (_replacements[noteId] ??= {}).addAll(replacements);
    _publish(AttachmentRepairNotification(this, noteId));
  }

  bool reconcile(int noteId, List<NoteAttachment> attachments) {
    if (!_active) return false;
    final replacements = _replacements[noteId];
    if (replacements == null) return false;
    return replaceAttachmentPaths(attachments, replacements);
  }
}

/// Changes references only: removals, order, source edits and PIN metadata stay
/// owned by the model being reconciled. Resolve chains from repeated repairs.
bool replaceAttachmentPaths(
  List<NoteAttachment> attachments,
  Map<String, String> replacements,
) {
  var changed = false;
  String? replace(String? value) {
    final seen = <String>{};
    var resolved = value;
    while (resolved != null && seen.add(resolved)) {
      final next = replacements[resolved];
      if (next == null) break;
      resolved = next;
    }
    changed |= resolved != value;
    return resolved;
  }

  for (final attachment in attachments) {
    switch (attachment.type) {
      case AttachmentType.image:
        attachment.image!.src = replace(attachment.image!.src)!;
      case AttachmentType.audio:
        attachment.recording!.src = replace(attachment.recording!.src)!;
      case AttachmentType.sketch:
        final sketch = attachment.sketch!;
        sketch.strokesFilePath = replace(sketch.strokesFilePath);
        sketch.backgroundImage = replace(sketch.backgroundImage);
        sketch.previewImage = replace(sketch.previewImage);
    }
  }
  return changed;
}
