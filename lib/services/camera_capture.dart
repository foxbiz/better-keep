/// Platform-selecting entry point for web camera capture.
///
/// This exposes a function to capture images from camera on web.
/// On native platforms, this returns null (use image_picker instead).
library;

export 'web_camera_stub.dart' if (dart.library.js_interop) 'web_camera.dart';
