/// Stub implementation for non-web platforms
/// This file is used when dart.library.js_interop is not available
library;

import 'dart:typed_data';

/// Capture an image from the camera on web.
/// On native platforms, this is not used (image_picker handles it).
Future<Uint8List?> captureImageFromWebCamera() async {
  // Not supported on non-web platforms
  return null;
}
