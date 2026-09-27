import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/models/note_recording.dart';
import 'package:better_keep/models/sketch.dart';

enum AttachmentType { image, sketch, audio }

class NoteAttachment {
  /// Assigned when referenced from note content; independent of local file paths.
  String? id;
  AttachmentType type;
  SketchData? sketch;
  NoteImage? image;
  NoteRecording? recording;

  NoteAttachment({
    required this.type,
    this.sketch,
    this.image,
    this.recording,
    this.id,
  });

  factory NoteAttachment.image(NoteImage image) {
    return NoteAttachment(type: AttachmentType.image, image: image);
  }

  factory NoteAttachment.sketch(SketchData sketch) {
    return NoteAttachment(type: AttachmentType.sketch, sketch: sketch);
  }

  factory NoteAttachment.audio(NoteRecording recording) {
    return NoteAttachment(type: AttachmentType.audio, recording: recording);
  }

  factory NoteAttachment.fromJson(Map<String, dynamic> json) {
    final attachment = NoteAttachment._fromJson(json);
    attachment.id = json['id'] as String?;
    return attachment;
  }

  factory NoteAttachment._fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String;
    switch (typeStr) {
      case 'image':
        return NoteAttachment.image(NoteImage.fromJson(json['data']));
      case 'sketch':
        return NoteAttachment.sketch(SketchData.fromJson(json['data']));
      case 'audio':
        // Support old format (just path string) and intermediate format (map with path/title)
        final data = json['data'];
        if (data is String) {
          return NoteAttachment.audio(NoteRecording(src: data));
        } else {
          return NoteAttachment.audio(NoteRecording.fromJson(data));
        }
      default:
        throw Exception('Unknown NoteAttachment type: $typeStr');
    }
  }

  Map<String, dynamic> toJson() {
    return {if (id != null) 'id': id, ..._payloadJson()};
  }

  Map<String, dynamic> _payloadJson() {
    switch (type) {
      case AttachmentType.image:
        return {'type': 'image', 'data': image!.toJson()};
      case AttachmentType.sketch:
        return {'type': 'sketch', 'data': sketch!.toJson()};
      case AttachmentType.audio:
        return {'type': 'audio', 'data': recording!.toJson()};
    }
  }
}
