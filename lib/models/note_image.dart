class NoteImage {
  int size;
  int index;
  String src;
  String aspectRatio;
  String lastModified;

  /// Base64-encoded tiny thumbnail for locked note previews.
  /// Very low resolution (~24px) to ensure privacy while showing visual hint.
  /// Should be under 1KB.
  String? blurredThumbnail;

  NoteImage({
    required this.src,
    required this.size,
    required this.index,
    required this.aspectRatio,
    required this.lastModified,
    this.blurredThumbnail,
  });

  factory NoteImage.fromJson(Map<String, dynamic> json) {
    return NoteImage(
      src: json['src'] as String,
      aspectRatio: json['aspectRatio'] as String,
      size: json['size'] as int,
      lastModified: json['lastModified'] as String,
      index: json['index'] as int,
      blurredThumbnail: json['blurredThumbnail'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'src': src,
      'size': size,
      'index': index,
      'aspectRatio': aspectRatio,
      'lastModified': lastModified,
      if (blurredThumbnail != null) 'blurredThumbnail': blurredThumbnail,
    };
  }

  double get ratio {
    final parts = aspectRatio.split(':');
    if (parts.length == 2) {
      final w = double.tryParse(parts[0]) ?? 1;
      final h = double.tryParse(parts[1]) ?? 1;
      return w / h;
    }
    return 1.0;
  }
}
