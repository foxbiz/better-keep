import 'dart:convert';
import 'package:better_keep/ui/custom_icons.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/material.dart';
import 'package:perfect_freehand/perfect_freehand.dart';

/// Drawing tool modes for sketch strokes
enum SketchTool {
  pen,
  pencil,
  brush,
  highlighter,
  eraser;

  String get displayName => switch (this) {
    SketchTool.pen => 'Pen',
    SketchTool.pencil => 'Pencil',
    SketchTool.brush => 'Brush',
    SketchTool.highlighter => 'Highlighter',
    SketchTool.eraser => 'Eraser',
  };

  IconData get icon => switch (this) {
    SketchTool.pen => CustomIcons.pen,
    SketchTool.pencil => CustomIcons.pencil,
    SketchTool.brush => CustomIcons.brush,
    SketchTool.highlighter => CustomIcons.highlight,
    SketchTool.eraser => CustomIcons.eraser,
  };

  /// Whether this tool is a drawing tool (not eraser)
  bool get isDrawingTool => this != SketchTool.eraser;
}

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

class SketchData {
  List<SketchStroke> strokes;
  double aspectRatio;
  Color backgroundColor;
  String? previewImage;
  String? backgroundImage;
  PagePattern pagePattern;

  /// Base64-encoded tiny thumbnail for locked note previews.
  /// Very low resolution (~24px) to ensure privacy while showing visual hint.
  /// Should be under 1KB.
  String? blurredThumbnail;

  /// @deprecated Use strokesFilePath instead.
  /// Encrypted strokes data for locked notes.
  /// When note is locked, strokes are encrypted and stored here.
  /// The regular `strokes` list will be empty when this is set.
  /// Kept for backward compatibility with existing synced data.
  String? encryptedStrokes;

  /// @deprecated Use strokesFilePath instead.
  /// Encrypted metadata for local data encryption (files encryption toggle).
  /// Contains strokes, bgColor, pagePattern as encrypted JSON.
  /// Different from encryptedStrokes which is for password-locked notes.
  /// Kept for backward compatibility with existing synced data.
  String? encryptedMetadata;

  /// Path to the file containing stroke data.
  /// This file contains all stroke data (strokes, bgColor, pagePattern) as JSON.
  /// Used for syncing instead of embedding strokes in the document or uploading preview images.
  /// The file is uploaded to Firebase Storage and downloaded on other devices.
  String? strokesFilePath;

  SketchData({
    this.previewImage,
    this.backgroundImage,
    this.aspectRatio = 1.0,
    this.strokes = const [],
    this.backgroundColor = Colors.white,
    this.pagePattern = PagePattern.blank,
    this.blurredThumbnail,
    this.encryptedStrokes,
    this.encryptedMetadata,
    this.strokesFilePath,
  });

  /// Returns true if this sketch has encrypted strokes (locked note)
  bool get hasEncryptedStrokes =>
      encryptedStrokes != null && encryptedStrokes!.isNotEmpty;

  /// Returns true if this sketch has encrypted metadata (local data encryption)
  bool get hasEncryptedMetadata =>
      encryptedMetadata != null && encryptedMetadata!.isNotEmpty;

  /// Returns true if this sketch has a strokes file (new format)
  bool get hasStrokesFile =>
      strokesFilePath != null && strokesFilePath!.isNotEmpty;

  Map<String, dynamic> toJson() {
    // strokesFilePath is required - all stroke data must be in a file
    // Old notes with inline strokes must be migrated before saving
    assert(
      hasStrokesFile,
      'strokesFilePath is required. Migrate old sketches before saving.',
    );
    return {
      'strokesFilePath': strokesFilePath,
      'aspectRatio': aspectRatio,
      'previewImage': previewImage,
      'backgroundImage': backgroundImage,
      if (blurredThumbnail != null) 'blurredThumbnail': blurredThumbnail,
    };
  }

  /// Creates JSON data for the strokes file.
  /// This contains all the data needed to regenerate the sketch on device.
  Map<String, dynamic> toStrokesFileJson() => {
    'strokes': strokes.map((s) => s.toString()).toList(),
    'bgColor': backgroundColor.toARGB32(),
    'pagePattern': pagePattern.name,
    'aspectRatio': aspectRatio,
    // Include encryptedStrokes if present (for locked notes)
    if (hasEncryptedStrokes) 'encryptedStrokes': encryptedStrokes,
  };

  /// Returns true if this sketch needs migration to the new strokes file format.
  /// Old sketches may have inline strokes, encryptedStrokes, or just a preview image.
  /// All sketches without a strokesFilePath need migration.
  bool get needsMigration => !hasStrokesFile;

  /// Parses strokes data from a strokes file JSON.
  /// Used when loading sketch data from downloaded strokes file.
  void loadFromStrokesFileJson(Map<String, dynamic> json) {
    if (json['strokes'] != null) {
      strokes = (json['strokes'] as List)
          .map((e) => SketchStroke.parse(e as String))
          .toList();
    }
    if (json['bgColor'] != null) {
      backgroundColor = Color(json['bgColor'] as int);
    }
    if (json['pagePattern'] != null) {
      pagePattern = PagePattern.values.firstWhere(
        (e) => e.name == json['pagePattern'],
        orElse: () => PagePattern.blank,
      );
    }
    if (json['aspectRatio'] != null) {
      aspectRatio = (json['aspectRatio'] as num).toDouble();
    }
  }

  factory SketchData.fromJson(Map<String, dynamic> json) {
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

      return SketchData(
        strokes: parsedStrokes,
        encryptedStrokes: encryptedStrokes,
        encryptedMetadata: encryptedMetadata,
        backgroundImage: json['backgroundImage'] as String?,
        backgroundColor: bgColor,
        previewImage: json['previewImage'] as String?,
        aspectRatio: (json['aspectRatio'] as num?)?.toDouble() ?? 1.0,
        pagePattern: pattern,
        blurredThumbnail: json['blurredThumbnail'] as String?,
        strokesFilePath: json['strokesFilePath'] as String?,
      );
    } catch (e) {
      AppLogger.error('Error parsing sketch data', e);
      return SketchData();
    }
  }

  String toRawJson() => json.encode(toJson());

  factory SketchData.fromRawJson(String str) =>
      SketchData.fromJson(json.decode(str));
}
