/// Stub implementation for non-web platforms
/// This file is used when dart.library.js_interop is not available
library;

/// Check if a camera is available on the device.
/// On native platforms, we assume camera is available on mobile devices.
/// Desktop platforms may or may not have a camera.
Future<bool> hasCameraAvailable() async {
  // On native platforms, assume camera is available
  // The image_picker will handle the actual availability check
  return true;
}
