import 'dart:convert';

import 'package:better_keep/models/note_attachment.dart';

class RemoteAttachmentPayloadException implements Exception {
  const RemoteAttachmentPayloadException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'RemoteAttachmentPayloadException($code): $message';
}

/// Validates the attachment collection before any local note is mutated.
List<Map<String, dynamic>> parseRemoteAttachmentPayload(Object? value) {
  Object? decoded = value;
  if (decoded == null) return const [];

  if (decoded is String) {
    try {
      decoded = jsonDecode(decoded);
    } on FormatException {
      throw const RemoteAttachmentPayloadException(
        'malformed-attachments-json',
        'Attachments must contain a valid JSON list',
      );
    }
  }

  if (decoded is! List) {
    throw const RemoteAttachmentPayloadException(
      'invalid-attachments-type',
      'Attachments must be a list',
    );
  }

  final attachments = <Map<String, dynamic>>[];
  for (final entry in decoded) {
    if (entry is! Map) {
      throw const RemoteAttachmentPayloadException(
        'invalid-attachment-entry',
        'Every attachment must be an object',
      );
    }
    attachments.add(Map<String, dynamic>.from(entry));
  }
  return attachments;
}

/// Parses every attachment before any download or local mutation begins.
///
/// This second phase catches structurally valid maps with invalid attachment
/// fields (unknown types, missing data, or incompatible value types).
List<NoteAttachment> parseRemoteNoteAttachments(Object? value) {
  final payload = parseRemoteAttachmentPayload(value);
  try {
    return payload.map(NoteAttachment.fromJson).toList(growable: false);
  } catch (_) {
    throw const RemoteAttachmentPayloadException(
      'invalid-attachment-entry',
      'An attachment contains invalid fields',
    );
  }
}
