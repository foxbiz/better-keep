import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/state.dart';

enum AssistantNoteCaptureStatus { saved, cancelled, unavailable, failed }

class AssistantNoteCaptureRequest {
  final String requestId;
  final String source;
  final String? title;
  final String? text;

  const AssistantNoteCaptureRequest({
    required this.requestId,
    required this.source,
    this.title,
    this.text,
  });

  factory AssistantNoteCaptureRequest.fromMap(Map<Object?, Object?> value) {
    return AssistantNoteCaptureRequest(
      requestId: value['requestId']?.toString() ?? '',
      source: value['source']?.toString() ?? '',
      title: value['title']?.toString(),
      text: value['text']?.toString(),
    );
  }

  String? get normalizedTitle {
    final value = title?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  String? get normalizedText {
    final value = text?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  bool get isValid =>
      requestId.trim().isNotEmpty &&
      source.trim().isNotEmpty &&
      (normalizedTitle != null || normalizedText != null);
}

class AssistantNoteCaptureResult {
  final AssistantNoteCaptureStatus status;
  final int? noteId;

  const AssistantNoteCaptureResult(this.status, {this.noteId});

  const AssistantNoteCaptureResult.saved(int noteId)
    : this(AssistantNoteCaptureStatus.saved, noteId: noteId);

  const AssistantNoteCaptureResult.cancelled()
    : this(AssistantNoteCaptureStatus.cancelled);

  const AssistantNoteCaptureResult.unavailable()
    : this(AssistantNoteCaptureStatus.unavailable);

  const AssistantNoteCaptureResult.failed()
    : this(AssistantNoteCaptureStatus.failed);

  Map<String, Object> toMap() => {
    'status': status.name,
    'noteId': ?noteId,
  };
}

typedef AssistantNoteSave =
    Future<int> Function(AssistantNoteCaptureRequest request);
typedef PlainTextNoteCreate =
    Future<int> Function({
      String? title,
      String? text,
      required String labelName,
    });

/// Canonical writer for notes created from plain text outside the editor.
class PlainTextNoteWriter {
  const PlainTextNoteWriter._();

  static String buildContent(String? text) {
    final value = text?.trim();
    final operations = <Map<String, String>>[];
    if (value != null && value.isNotEmpty) {
      operations.add({'insert': value});
    }
    operations.add({'insert': '\n'});
    return jsonEncode(operations);
  }

  static Future<int> create({
    String? title,
    String? text,
    required String labelName,
  }) async {
    final normalizedTitle = title?.trim();
    final normalizedText = text?.trim();
    final label = await Label.getOrCreateSystemLabel(labelName);
    final note = Note(
      title: normalizedTitle == null || normalizedTitle.isEmpty
          ? null
          : normalizedTitle,
      content: buildContent(normalizedText),
      plainText: normalizedText ?? '',
      labels: label.name,
    );
    return note.save();
  }
}

/// Validates, serializes, and deduplicates assistant-driven note creation.
class AssistantNoteCaptureService {
  AssistantNoteCaptureService({
    bool Function()? availabilityCheck,
    AssistantNoteSave? save,
    PlainTextNoteCreate? writer,
    this.labelName = Label.voiceNotesLabelName,
    this.completedRequestLimit = 100,
  }) : _availabilityCheck = availabilityCheck ?? _defaultAvailabilityCheck,
       _save =
           save ??
           ((request) => (writer ?? PlainTextNoteWriter.create)(
             title: request.normalizedTitle,
             text: request.normalizedText,
             labelName: labelName,
           ));

  static final AssistantNoteCaptureService instance =
      AssistantNoteCaptureService();

  final bool Function() _availabilityCheck;
  final AssistantNoteSave _save;
  final String labelName;
  final int completedRequestLimit;
  final Map<String, Future<AssistantNoteCaptureResult>> _inFlight = {};
  final LinkedHashMap<String, AssistantNoteCaptureResult> _completed =
      LinkedHashMap();
  Future<void> _serializationTail = Future.value();

  bool get isAvailable {
    try {
      return _availabilityCheck();
    } catch (_) {
      return false;
    }
  }

  Future<AssistantNoteCaptureResult> capture(
    AssistantNoteCaptureRequest request,
  ) {
    if (!request.isValid) {
      return Future.value(const AssistantNoteCaptureResult.failed());
    }

    final completed = _completed[request.requestId];
    if (completed != null) {
      return Future.value(completed);
    }

    final existing = _inFlight[request.requestId];
    if (existing != null) return existing;

    final completer = Completer<AssistantNoteCaptureResult>();
    _inFlight[request.requestId] = completer.future;

    final operation = _serializationTail.then((_) => _captureOnce(request));
    _serializationTail = operation.then<void>((_) {}, onError: (_) {});
    operation.then(
      (result) {
        _remember(request.requestId, result);
        _inFlight.remove(request.requestId);
        completer.complete(result);
      },
      onError: (_) {
        const result = AssistantNoteCaptureResult.failed();
        _remember(request.requestId, result);
        _inFlight.remove(request.requestId);
        completer.complete(result);
      },
    );

    return completer.future;
  }

  Future<AssistantNoteCaptureResult> _captureOnce(
    AssistantNoteCaptureRequest request,
  ) async {
    try {
      if (!isAvailable) {
        return const AssistantNoteCaptureResult.unavailable();
      }
      final noteId = await _save(request);
      if (noteId < 0) return const AssistantNoteCaptureResult.failed();
      return AssistantNoteCaptureResult.saved(noteId);
    } catch (_) {
      return const AssistantNoteCaptureResult.failed();
    }
  }

  void _remember(String requestId, AssistantNoteCaptureResult result) {
    _completed[requestId] = result;
    while (_completed.length > completedRequestLimit) {
      _completed.remove(_completed.keys.first);
    }
  }

  static bool _defaultAvailabilityCheck() {
    if (AuthService.currentUser == null) return false;
    if (!E2EEService.instance.isReady || !E2EEService.instance.isAvailable) {
      return false;
    }
    try {
      return AppState.db.isOpen;
    } catch (_) {
      return false;
    }
  }
}
