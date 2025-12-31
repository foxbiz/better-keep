import 'package:better_keep/models/attachments/image_attachment.dart';
import 'package:better_keep/models/attachments/recording_attachment.dart';
import 'package:better_keep/models/attachments/sketch_attachment.dart';

enum AttachmentType { image, sketch, audio }

class Attachment {
  String remotePath = '';
  AttachmentType type;
  SketchAttachment? sketch;
  ImageAttachment? image;
  RecordingAttachment? recording;

  String get id => switch (type) {
    AttachmentType.image => image!.id,
    AttachmentType.sketch => sketch!.id,
    AttachmentType.audio => recording!.id,
  };

  bool get dirty => switch (type) {
    AttachmentType.image => image!.dirty,
    AttachmentType.sketch => sketch!.dirty,
    AttachmentType.audio => recording!.dirty,
  };

  Attachment({required this.type, this.sketch, this.image, this.recording});

  factory Attachment.image(ImageAttachment image) {
    return Attachment(type: AttachmentType.image, image: image);
  }

  factory Attachment.sketch(SketchAttachment sketch) {
    return Attachment(type: AttachmentType.sketch, sketch: sketch);
  }

  factory Attachment.audio(RecordingAttachment recording) {
    return Attachment(type: AttachmentType.audio, recording: recording);
  }

  factory Attachment.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String;
    switch (typeStr) {
      case 'image':
        return Attachment.image(ImageAttachment.fromJson(json['data']));
      case 'sketch':
        return Attachment.sketch(SketchAttachment.fromJson(json['data']));
      case 'audio':
        return Attachment.audio(RecordingAttachment.fromJson(json['data']));
      default:
        throw Exception('Unknown NoteAttachment type: $typeStr');
    }
  }

  Map<String, dynamic> toJson() {
    switch (type) {
      case AttachmentType.image:
        return {'type': AttachmentType.image.name, 'data': image!.toJson()};
      case AttachmentType.sketch:
        return {'type': AttachmentType.sketch.name, 'data': sketch!.toJson()};
      case AttachmentType.audio:
        return {'type': AttachmentType.audio.name, 'data': recording!.toJson()};
    }
  }
}
