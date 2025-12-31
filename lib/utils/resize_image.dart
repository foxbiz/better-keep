import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/rendering.dart';

Future<Uint8List> resizeImage(
  Uint8List data, {
  double? quality,
  double? width,
  double? height,
}) async {
  if (quality == null && width == null && height == null) {
    throw Exception(
      'At least one of quality, width or height must be provided',
    );
  }

  final image = await decodeImageFromList(data);

  if (quality != null) {
    width ??= image.width * quality;
    height ??= image.height * quality;
  }

  width ??= image.width.toDouble();
  height ??= image.height.toDouble();

  final recorder = PictureRecorder();
  final canvas = Canvas(recorder);
  final paint = Paint()..filterQuality = FilterQuality.high;
  final src = Rect.fromLTWH(
    0,
    0,
    image.width.toDouble(),
    image.height.toDouble(),
  );
  final dst = Rect.fromLTWH(0, 0, width, height);
  canvas.drawImageRect(image, src, dst, paint);
  final picture = recorder.endRecording();
  final img = await picture.toImage(width.toInt(), height.toInt());
  final byteData = await img.toByteData(format: ImageByteFormat.png);
  return byteData!.buffer.asUint8List();
}
