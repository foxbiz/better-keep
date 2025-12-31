import 'dart:convert';

import 'package:better_keep/models/attachments/attachment_body.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/utils.dart';

/// Model representing an audio recording attached to a note.
class RecordingAttachment implements AttachmentBody {
  String id;

  /// Duration of the recording in seconds
  int length;

  /// Optional title for the recording
  String? title;

  /// Optional transcript of the recording
  String? transcript;

  @override
  bool get dirty => false;
  @override
  String get path => "${AppState.documentDir}/attachments/recordings/$id.m4a";
  @override
  String get previewPath => "";
  @override
  String get thumbnailPath => "";
  @override
  double get aspectRatio => 1.0;

  RecordingAttachment({
    String? id,
    this.length = 0,
    this.title,
    this.transcript,
  }) : id = id ?? uuid();

  factory RecordingAttachment.fromJson(Map<String, dynamic> json) {
    return RecordingAttachment(
      id: json['src'] as String,
      length: json['length'] as int? ?? 0,
      title: json['title'] as String?,
      transcript: json['transcript'] as String?,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'length': length,
      if (title != null) 'title': title,
      if (transcript != null) 'transcript': transcript,
    };
  }

  @override
  String toRawJson() {
    final data = toJson();
    return jsonEncode(data);
  }

  @override
  Future<void> save({bool force = false, String? password}) async {}

  @override
  Future<void> delete() async {}

  @override
  Future<void> lock(String password) async {}

  @override
  Future<void> unlock(String password) async {}

  @override
  Future<void> load([String? password]) async {}

  @override
  void dispose() {}
}
