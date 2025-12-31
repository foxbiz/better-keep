import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/models/attachments/attachment_body.dart';
import 'package:better_keep/services/file_system/file_system.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/resize_image.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/material.dart';

class ImageAttachment implements AttachmentBody {
  String id;
  Size dimension;
  String lastModified;
  Uint8List? _blob;
  bool _dirty = false;

  @override
  bool get dirty => _dirty;
  @override
  String get path => "${AppState.documentDir}/attachments/images/$id.image";
  @override
  String get thumbnailPath => "$path-thumb.jpg";
  @override
  String get previewPath => "";
  @override
  double get aspectRatio => dimension.width / dimension.height;

  Uint8List? get blob => _blob;
  set blob(Uint8List? data) {
    _blob = data;
    _dirty = true;
  }

  ImageAttachment({
    String? id,
    required this.dimension,
    required this.lastModified,
  }) : id = id ?? uuid();

  factory ImageAttachment.fromJson(Map<String, dynamic> json) {
    return ImageAttachment(
      id: json['id'] as String?,
      dimension: json['size'] != null
          ? Size(
              (json['size']['width'] as num).toDouble(),
              (json['size']['height'] as num).toDouble(),
            )
          : Size.zero,
      lastModified: json['lastModified'] as String,
    );
  }

  static Future<ImageAttachment> fromBlob(Uint8List blob) async {
    final image = await decodeImageFromList(blob);
    final dimension = Size(image.width.toDouble(), image.height.toDouble());
    final instance = ImageAttachment(
      dimension: dimension,
      lastModified: DateTime.now().toIso8601String(),
    );
    instance.blob = blob;
    await instance.save();
    return instance;
  }

  @override
  String toRawJson() {
    final jsonMap = toJson();
    return jsonEncode(jsonMap);
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'size': {'width': dimension.width, 'height': dimension.height},
      'lastModified': lastModified,
    };
  }

  @override
  Future<void> save({bool force = false, String? password}) async {
    final fs = await fileSystem();
    if (!await fs.exists(thumbnailPath)) {
      final thumbnailBlob = await _generateThumbnail();
      await fs.writeBytes(thumbnailPath, thumbnailBlob);
    }

    _dirty = false;
    if (_blob == null) {
      return;
    }

    await fs.writeBytes(path, _blob!);
  }

  @override
  Future<void> delete() async {
    final fs = await fileSystem();
    await fs.delete(path);
    await fs.delete(thumbnailPath);
  }

  @override
  Future<void> load([String? password]) async {}

  @override
  Future<void> lock(String password) async {}

  @override
  Future<void> unlock(String password) async {}

  @override
  void dispose() {
    _blob = null;
  }

  Future<Uint8List> _generateThumbnail([double quality = 0.5]) async {
    final fs = await fileSystem();
    if (await fs.exists(thumbnailPath)) {
      return fs.readBytes(thumbnailPath);
    }

    if (_blob == null) {
      await load();
    }

    final thumbnailBlob = await resizeImage(_blob!, quality: quality);
    await fs.writeBytes(thumbnailPath, thumbnailBlob);
    return thumbnailBlob;
  }
}
