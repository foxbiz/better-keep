/// Web implementation for camera detection
/// Uses the browser's MediaDevices API to check for camera availability
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Check if a camera is available on the device using MediaDevices API.
/// Returns true if at least one video input device is found.
Future<bool> hasCameraAvailable() async {
  try {
    final navigator = web.window.navigator;
    final mediaDevices = navigator.mediaDevices;

    // Get all media devices
    final devices = await mediaDevices.enumerateDevices().toDart;

    // if devices is null or empty, no camera
    if (devices.length == 0) {
      return false;
    }

    // Check if any device is a video input (camera)
    for (final device in devices.toDart) {
      if (device.kind == 'videoinput') {
        return true;
      }
    }

    return false;
  } catch (e) {
    // If we can't enumerate devices, assume no camera
    // This can happen if permissions are denied or API is not available
    return false;
  }
}
