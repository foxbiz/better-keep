import 'dart:convert';

/// Creates Delta JSON for a new audio note with title, audio link, and transcription
/// Used by home.dart FAB when creating new audio notes
///
/// Format matches note_editor._appendTranscriptToNote:
/// - Title with header formatting
/// - Audio tag (#Title) with bold and link (audio://index)
/// - Transcription in blockquote
/// - Empty line for separation
String createAudioNoteContentJson({
  required String title,
  String? transcription,
  String? audioTitle,
  int recordingIndex = 0,
}) {
  final List<Map<String, dynamic>> delta = [
    {'insert': title},
    {
      'insert': '\n',
      'attributes': {'header': 1},
    },
  ];

  if (transcription != null && transcription.isNotEmpty) {
    delta.addAll(
      createAudioTranscriptDelta(
        transcription: transcription,
        audioTitle: audioTitle,
        recordingIndex: recordingIndex,
      ),
    );
  }

  delta.add({'insert': '\n'});
  return json.encode(delta);
}

/// Creates Delta operations for audio tag + transcription block
/// Used for both new notes and appending to existing notes
///
/// Returns operations for:
/// - Audio tag with link and bold formatting
/// - Transcription text in blockquote
/// - Empty line for separation between multiple recordings
List<Map<String, dynamic>> createAudioTranscriptDelta({
  required String transcription,
  String? audioTitle,
  required int recordingIndex,
}) {
  final audioTagText = '#${audioTitle ?? 'Audio Recording'}';

  return [
    // Audio tag with link and bold
    {
      'insert': audioTagText,
      'attributes': {'bold': true, 'link': 'audio://$recordingIndex'},
    },
    {
      'insert': '\n',
      'attributes': {'blockquote': true},
    },
    // Transcription text
    {'insert': transcription},
    {
      'insert': '\n',
      'attributes': {'blockquote': true},
    },
    // Empty line for separation between multiple recordings
    {'insert': '\n'},
  ];
}
