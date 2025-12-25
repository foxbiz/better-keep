class NoteImage {
  int size;
  int index;
  String src;
  String aspectRatio;
  String lastModified;

  NoteImage({
    required this.src,
    required this.size,
    required this.index,
    required this.aspectRatio,
    required this.lastModified,
  });

  factory NoteImage.fromJson(Map<String, dynamic> json) {
    return NoteImage(
      src: json['src'] as String,
      aspectRatio: json['aspectRatio'] as String,
      size: json['size'] as int,
      lastModified: json['lastModified'] as String,
      index: json['index'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'src': src,
      'size': size,
      'index': index,
      'aspectRatio': aspectRatio,
      'lastModified': lastModified,
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
