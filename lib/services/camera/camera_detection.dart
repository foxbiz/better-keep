/// Platform-selecting entry point for camera detection.
///
/// This exposes a function to check if a camera is available on the device.
/// On web, it uses the MediaDevices API. On native platforms, it assumes
/// camera is available (the image_picker handles actual availability).
library;

export 'camera_detection_stub.dart'
    if (dart.library.js_interop) 'camera_detection_web.dart';
