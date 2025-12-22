/// Model representing an audio recording attached to a note.
class NoteRecording {
  /// Duration of the recording in seconds
  int length;

  /// Path to the audio file (local path or remote URL)
  String src;

  /// Optional title for the recording
  String? title;

  /// Optional transcript of the recording
  String? transcript;

  NoteRecording({
    required this.src,
    this.length = 0,
    this.title,
    this.transcript,
  });

  factory NoteRecording.fromJson(Map<String, dynamic> json) {
    // Support old format where data was just a path string
    if (json case {'path': String path}) {
      return NoteRecording(
        src: path,
        title: json['title'] as String?,
        length: json['length'] as int? ?? 0,
        transcript: json['transcript'] as String?,
      );
    }
    return NoteRecording(
      src: json['src'] as String,
      length: json['length'] as int? ?? 0,
      title: json['title'] as String?,
      transcript: json['transcript'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'src': src,
      'length': length,
      if (title != null) 'title': title,
      if (transcript != null) 'transcript': transcript,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is NoteRecording && other.src == src;
  }

  @override
  int get hashCode => src.hashCode;
}
