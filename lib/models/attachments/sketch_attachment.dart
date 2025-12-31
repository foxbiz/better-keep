import 'dart:convert';
import 'dart:ui' as ui;
import 'package:better_keep/components/page_pattern_painter.dart';
import 'package:better_keep/models/attachments/attachment_body.dart';
import 'package:better_keep/pages/sketch_page.dart';
import 'package:better_keep/services/file_system/file_system.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/ui/custom_icons.dart';
import 'package:better_keep/utils/encryption.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:perfect_freehand/perfect_freehand.dart';

enum SketchTool { pen, eraser }

/// Page pattern types for sketch backgrounds
/// These are rendered dynamically and not saved as part of the sketch image
enum PagePattern {
  blank,
  singleLine,
  doubleLine,
  grid,
  dotGrid;

  String get displayName => switch (this) {
    PagePattern.blank => 'Blank',
    PagePattern.singleLine => 'Lined',
    PagePattern.doubleLine => 'Double Lined',
    PagePattern.grid => 'Grid',
    PagePattern.dotGrid => 'Dot Grid',
  };

  IconData get icon => switch (this) {
    PagePattern.blank => CustomIcons.emptyPage,
    PagePattern.singleLine => Icons.horizontal_rule,
    PagePattern.doubleLine => Icons.dehaze,
    PagePattern.grid => Icons.grid_4x4,
    PagePattern.dotGrid => CustomIcons.dotsPage,
  };
}

class SketchStroke {
  String points;
  final Color color;
  final double size;
  final SketchTool tool;

  SketchStroke({
    required this.points,
    required this.color,
    required this.size,
    this.tool = SketchTool.pen,
  });

  static List<PointVector> parsePoints(String pointsStr) {
    final List<PointVector> vectorPoints = [];
    if (pointsStr.isEmpty) return vectorPoints;

    // Use StringBuffer for better performance with large point sets
    final buffer = StringBuffer();
    final vector = <double>[0, 0, 0];
    int needle = 0;

    for (var i = 0; i < pointsStr.length; ++i) {
      final char = pointsStr[i];

      if (char == ';') {
        vector[needle] = double.parse(buffer.toString());
        vectorPoints.add(PointVector(vector[0], vector[1], vector[2]));
        needle = 0;
        buffer.clear();
        vector[0] = 0;
        vector[1] = 0;
        vector[2] = 0;
        continue;
      }

      if (char == ',') {
        vector[needle] = double.parse(buffer.toString());
        buffer.clear();
        ++needle;
        continue;
      }

      buffer.write(char);
    }
    return vectorPoints;
  }

  factory SketchStroke.parse(String data) {
    final List<String> meta = [
      '', // tool
      '', // color
      '', // size
    ];
    int i = 0;
    int needle = 0;

    for (; i < data.length; ++i) {
      var char = data[i];

      if (char == ':') {
        if (++needle == meta.length) {
          break;
        }
        continue;
      }

      meta[needle] += char;
    }
    return SketchStroke(
      points: data.substring(i + 1),
      tool: SketchTool.values.firstWhere(
        (e) => e.name == meta[0],
        orElse: () => SketchTool.pen,
      ),
      color: Color(int.parse(meta[1])),
      size: double.parse(meta[2]),
    );
  }

  @override
  String toString() {
    return '${tool.name}:${color.toARGB32()}:${size.toStringAsFixed(1)}:$points';
  }
}

class SketchAttachment implements AttachmentBody {
  String id;
  bool _dirty = false;
  Size pageDimension;
  Color _backgroundColor;
  String? _backgroundImage;
  PagePattern _pagePattern;
  List<SketchStroke> _strokes = [];

  /// TODO: Remove in future versions
  @Deprecated('Strokes are now saved in file instead of database')
  String? _encryptedStrokes;

  /// Encrypted metadata for local data encryption (files encryption toggle).
  /// TODO: Remove in future versions
  @Deprecated('No longer encrypting metadata separately')
  String? _encryptedMetadata;

  @override
  bool get dirty => _dirty;
  @override
  String get path => "${AppState.documentDir}/attachments/sketches/$id.sketch";
  @override
  String get thumbnailPath => "$path-thumb.jpg";
  @override
  String get previewPath => "$path-preview.jpg";
  @override
  double get aspectRatio => pageDimension.width / pageDimension.height;

  List<SketchStroke> get strokes => _strokes;
  set strokes(List<SketchStroke> value) {
    _strokes = value;
    _dirty = true;
  }

  Color get backgroundColor => _backgroundColor;
  set backgroundColor(Color value) {
    _backgroundColor = value;
    _dirty = true;
  }

  String? get backgroundImage => _backgroundImage;
  set backgroundImage(String? value) {
    _backgroundImage = value;
    _dirty = true;
  }

  PagePattern get pagePattern => _pagePattern;
  set pagePattern(PagePattern value) {
    _pagePattern = value;
    _dirty = true;
  }

  /// Returns true if this sketch has encrypted strokes (locked note)
  bool get hasEncryptedStrokes =>
      _encryptedStrokes != null && _encryptedStrokes!.isNotEmpty;

  /// Returns true if this sketch has encrypted metadata (local data encryption)
  bool get hasEncryptedMetadata =>
      _encryptedMetadata != null && _encryptedMetadata!.isNotEmpty;

  SketchAttachment({
    String? id,
    this.pageDimension = kA4Size,
    String? backgroundImage,
    PagePattern pagePattern = PagePattern.blank,
    Color backgroundColor = Colors.white,
  }) : _pagePattern = pagePattern,
       _backgroundImage = backgroundImage,
       _backgroundColor = backgroundColor,
       id = id ?? uuid();

  factory SketchAttachment.fromJson(Map<String, dynamic> json) {
    try {
      // Check if strokes are encrypted (from locked note)
      final encryptedStrokes = json['encryptedStrokes'] as String?;

      // Check if metadata is encrypted (from local data encryption - files toggle)
      final encryptedMetadata = json['encrypted_metadata'] as String?;

      // Parse strokes only if not encrypted
      List<SketchStroke> parsedStrokes = [];
      Color bgColor = const Color(0xFFFFFFFF);
      PagePattern pattern = PagePattern.blank;

      // If encrypted metadata, store it for later decryption
      // Otherwise, parse strokes and color normally
      if (encryptedMetadata == null &&
          encryptedStrokes == null &&
          json['strokes'] != null) {
        parsedStrokes = (json['strokes'] as List)
            .map((e) => SketchStroke.parse(e))
            .toList();
        bgColor = Color(json['bgColor'] as int? ?? 0xFFFFFFFF);
        pattern = PagePattern.values.firstWhere(
          (e) => e.name == json['pagePattern'],
          orElse: () => PagePattern.blank,
        );
      } else if (encryptedStrokes == null && json['bgColor'] != null) {
        // Fallback: if bgColor exists but no strokes, parse colors anyway
        bgColor = Color(json['bgColor'] as int? ?? 0xFFFFFFFF);
        pattern = PagePattern.values.firstWhere(
          (e) => e.name == json['pagePattern'],
          orElse: () => PagePattern.blank,
        );
      }

      final instance = SketchAttachment(
        id: json['id'] as String?,
        pagePattern: pattern,
        backgroundColor: bgColor,
        backgroundImage: json['backgroundImage'] as String?,
        pageDimension: json['pageSize'] != null
            ? Size(
                (json['pageSize']['width'] as num).toDouble(),
                (json['pageSize']['height'] as num).toDouble(),
              )
            : kA4Size,
      );

      instance.strokes = parsedStrokes;
      instance._encryptedStrokes = encryptedStrokes;
      instance._encryptedMetadata = encryptedMetadata;
      return instance;
    } catch (e) {
      AppLogger.error('Error parsing sketch data', e);
      return SketchAttachment();
    }
  }

  factory SketchAttachment.fromRawJson(String str) =>
      SketchAttachment.fromJson(json.decode(str));

  @override
  String toRawJson() => json.encode(toJson());

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'pageSize': {'width': pageDimension.width, 'height': pageDimension.height},
    'pagePattern': _pagePattern.name,
    'backgroundImage': _backgroundImage,
    'bgColor': _backgroundColor.toARGB32(),
  };

  @override
  Future<void> save({bool force = false, String? password}) async {
    final fs = await fileSystem();
    late Uint8List preview;
    late Uint8List thumbnail;
    ByteData? previewByteData = await _getPreview(1);
    ByteData? thumbnailByteData = await _getPreview(0.2);
    String strokesString = jsonEncode(
      strokes.map((s) => s.toString()).toList(),
    );

    if (previewByteData == null || thumbnailByteData == null) {
      throw Exception('Failed to generate sketch preview or thumbnail');
    }

    preview = previewByteData.buffer.asUint8List();
    thumbnail = thumbnailByteData.buffer.asUint8List();

    if (password != null && password.isNotEmpty) {
      strokesString = await encrypt(strokesString, password);
      preview = await encryptBytesWithPassword(preview, password);
      thumbnail = await encryptBytesWithPassword(thumbnail, password);
    }

    await fs.writeString(path, strokesString);
    await fs.writeBytes(previewPath, preview);
    await fs.writeBytes(thumbnailPath, thumbnail);
  }

  @override
  Future<void> lock(String password) async {}

  @override
  Future<void> unlock(String password) async {
    if (_encryptedStrokes != null) {
      final strokesStr = await decrypt(_encryptedStrokes!, password);
      strokes = (jsonDecode(strokesStr) as List)
          .map((stroke) => SketchStroke.parse(stroke))
          .toList();
      _encryptedStrokes = null;
    }

    if (_encryptedMetadata != null) {
      final metadataStr = await decrypt(_encryptedMetadata!, password);
      final metadata = jsonDecode(metadataStr) as Map<String, dynamic>;

      _backgroundColor = Color(metadata['bgColor'] as int? ?? 0xFFFFFFFF);
      _pagePattern = PagePattern.values.firstWhere(
        (e) => e.name == metadata['pagePattern'],
        orElse: () => PagePattern.blank,
      );

      _encryptedMetadata = null;
    }

    final fs = await fileSystem();
    if (await fs.exists(path)) {
      strokes = await load(password);
    }
  }

  @override
  Future<void> delete() async {
    final fs = await fileSystem();

    await fs.delete(path);
    await fs.delete(previewPath);
    await fs.delete(thumbnailPath);
  }

  @override
  Future<List<SketchStroke>> load([String? password]) async {
    final fs = await fileSystem();
    String strokesString = await fs.readString(path);

    if (password != null && strokesString.isNotEmpty) {
      strokesString = await decrypt(strokesString, password);
    }

    strokes = (jsonDecode(strokesString) as List)
        .map((stroke) => SketchStroke.parse(stroke))
        .toList();
    return strokes;
  }

  @override
  void dispose() {
    _strokes.clear();
  }

  Future<ByteData?> _getPreview([double quality = 1.0]) async {
    late final ui.Picture picture;
    late final ui.Image image;

    final painter = SketchPainter(strokes: strokes);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    if (_backgroundImage != null && _pagePattern != PagePattern.blank) {
      final patternPainter = PagePatternPainter(
        pattern: _pagePattern,
        lineColor: isDark(_backgroundColor)
            ? Colors.white.withValues(alpha: 0.25)
            : Colors.black.withValues(alpha: 0.18),
      );
      patternPainter.paint(canvas, pageDimension);
    }

    painter.paint(canvas, pageDimension);
    picture = recorder.endRecording();
    image = await picture.toImage(
      (pageDimension.width * quality).toInt(),
      (pageDimension.height * quality).toInt(),
    );
    return image.toByteData(format: ui.ImageByteFormat.png);
  }
}
