/// Web implementation for camera capture
/// Uses the browser's getUserMedia API to capture images from camera
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Capture an image from the camera on web using getUserMedia API.
/// Returns the captured image as bytes, or null if cancelled/failed.
Future<Uint8List?> captureImageFromWebCamera() async {
  web.MediaStream? stream;

  try {
    // Request camera access
    final constraints = web.MediaStreamConstraints(
      video: true.toJS,
      audio: false.toJS,
    );

    stream = await web.window.navigator.mediaDevices
        .getUserMedia(constraints)
        .toDart;

    // Create video element to display camera feed
    final video = web.document.createElement('video') as web.HTMLVideoElement;
    video.srcObject = stream;
    video.setAttribute('autoplay', 'true');
    video.setAttribute('playsinline', 'true');
    video.style.width = '100%';
    video.style.height = '100%';
    video.style.objectFit = 'cover';
    video.style.transform = 'scaleX(-1)'; // Mirror for selfie camera

    // Create modal overlay
    final overlay = web.document.createElement('div') as web.HTMLDivElement;
    overlay.style.position = 'fixed';
    overlay.style.top = '0';
    overlay.style.left = '0';
    overlay.style.width = '100%';
    overlay.style.height = '100%';
    overlay.style.backgroundColor = 'rgba(0, 0, 0, 0.9)';
    overlay.style.zIndex = '999999';
    overlay.style.display = 'flex';
    overlay.style.flexDirection = 'column';
    overlay.style.alignItems = 'center';
    overlay.style.justifyContent = 'center';

    // Create video container
    final videoContainer =
        web.document.createElement('div') as web.HTMLDivElement;
    videoContainer.style.width = '100%';
    videoContainer.style.maxWidth = '640px';
    videoContainer.style.aspectRatio = '4/3';
    videoContainer.style.borderRadius = '12px';
    videoContainer.style.overflow = 'hidden';
    videoContainer.style.backgroundColor = '#000';
    videoContainer.appendChild(video);

    // Create button container
    final buttonContainer =
        web.document.createElement('div') as web.HTMLDivElement;
    buttonContainer.style.display = 'flex';
    buttonContainer.style.gap = '20px';
    buttonContainer.style.marginTop = '20px';

    // Create capture button with SVG camera icon
    final captureBtn =
        web.document.createElement('button') as web.HTMLButtonElement;
    // Create SVG icon for camera
    final cameraSvg =
        web.document.createElementNS('http://www.w3.org/2000/svg', 'svg')
            as web.SVGElement;
    cameraSvg.setAttribute('width', '24');
    cameraSvg.setAttribute('height', '24');
    cameraSvg.setAttribute('viewBox', '0 0 24 24');
    cameraSvg.setAttribute('fill', 'white');
    cameraSvg.style.marginRight = '8px';
    final cameraPath = web.document.createElementNS(
      'http://www.w3.org/2000/svg',
      'path',
    );
    cameraPath.setAttribute(
      'd',
      'M12 15.2c1.77 0 3.2-1.43 3.2-3.2S13.77 8.8 12 8.8 8.8 10.23 8.8 12s1.43 3.2 3.2 3.2zm0-8.4c2.87 0 5.2 2.33 5.2 5.2s-2.33 5.2-5.2 5.2-5.2-2.33-5.2-5.2 2.33-5.2 5.2-5.2zM9 2L7.17 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2h-3.17L15 2H9z',
    );
    cameraSvg.appendChild(cameraPath);
    final captureText = web.document.createTextNode('Capture');
    captureBtn.appendChild(cameraSvg);
    captureBtn.appendChild(captureText);
    captureBtn.style.padding = '16px 32px';
    captureBtn.style.fontSize = '18px';
    captureBtn.style.borderRadius = '30px';
    captureBtn.style.border = 'none';
    captureBtn.style.backgroundColor = '#4CAF50';
    captureBtn.style.color = 'white';
    captureBtn.style.cursor = 'pointer';
    captureBtn.style.fontWeight = 'bold';
    captureBtn.style.display = 'flex';
    captureBtn.style.alignItems = 'center';

    // Create cancel button with X icon
    final cancelBtn =
        web.document.createElement('button') as web.HTMLButtonElement;
    // Create SVG icon for close
    final closeSvg =
        web.document.createElementNS('http://www.w3.org/2000/svg', 'svg')
            as web.SVGElement;
    closeSvg.setAttribute('width', '20');
    closeSvg.setAttribute('height', '20');
    closeSvg.setAttribute('viewBox', '0 0 24 24');
    closeSvg.setAttribute('fill', 'none');
    closeSvg.setAttribute('stroke', 'white');
    closeSvg.setAttribute('stroke-width', '2.5');
    closeSvg.setAttribute('stroke-linecap', 'round');
    closeSvg.style.marginRight = '8px';
    final line1 = web.document.createElementNS(
      'http://www.w3.org/2000/svg',
      'line',
    );
    line1.setAttribute('x1', '18');
    line1.setAttribute('y1', '6');
    line1.setAttribute('x2', '6');
    line1.setAttribute('y2', '18');
    final line2 = web.document.createElementNS(
      'http://www.w3.org/2000/svg',
      'line',
    );
    line2.setAttribute('x1', '6');
    line2.setAttribute('y1', '6');
    line2.setAttribute('x2', '18');
    line2.setAttribute('y2', '18');
    closeSvg.appendChild(line1);
    closeSvg.appendChild(line2);
    final cancelText = web.document.createTextNode('Cancel');
    cancelBtn.appendChild(closeSvg);
    cancelBtn.appendChild(cancelText);
    cancelBtn.style.padding = '16px 32px';
    cancelBtn.style.fontSize = '18px';
    cancelBtn.style.borderRadius = '30px';
    cancelBtn.style.border = '2px solid white';
    cancelBtn.style.backgroundColor = 'transparent';
    cancelBtn.style.color = 'white';
    cancelBtn.style.cursor = 'pointer';
    cancelBtn.style.fontWeight = 'bold';
    cancelBtn.style.display = 'flex';
    cancelBtn.style.alignItems = 'center';

    buttonContainer.appendChild(captureBtn);
    buttonContainer.appendChild(cancelBtn);

    overlay.appendChild(videoContainer);
    overlay.appendChild(buttonContainer);
    web.document.body?.appendChild(overlay);

    // Wait for video to be ready
    await video.play().toDart;

    // Wait for user action
    final completer = Completer<Uint8List?>();

    void cleanup() {
      // Stop all tracks
      final tracks = stream?.getTracks().toDart ?? [];
      for (final track in tracks) {
        track.stop();
      }
      // Remove overlay
      overlay.remove();
    }

    captureBtn.onClick.listen((event) {
      try {
        // Create canvas to capture frame
        final canvas =
            web.document.createElement('canvas') as web.HTMLCanvasElement;
        canvas.width = video.videoWidth;
        canvas.height = video.videoHeight;

        final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;

        // Draw mirrored (to match what user sees)
        ctx.translate(canvas.width.toDouble(), 0);
        ctx.scale(-1, 1);
        ctx.drawImage(video, 0, 0);

        // Convert to blob and then to bytes
        canvas.toBlob(
          (web.Blob? blob) {
            if (blob == null) {
              cleanup();
              completer.complete(null);
              return;
            }

            final reader = web.FileReader();
            reader.onLoadEnd.listen((event) {
              final result = reader.result;
              if (result != null) {
                final arrayBuffer = result as JSArrayBuffer;
                final bytes = arrayBuffer.toDart.asUint8List();
                cleanup();
                completer.complete(bytes);
              } else {
                cleanup();
                completer.complete(null);
              }
            });
            reader.readAsArrayBuffer(blob);
          }.toJS,
          'image/jpeg',
          0.9.toJS,
        );
      } catch (e) {
        cleanup();
        completer.complete(null);
      }
    });

    cancelBtn.onClick.listen((event) {
      cleanup();
      completer.complete(null);
    });

    // Also close on escape key
    void onKeyDown(web.KeyboardEvent event) {
      if (event.key == 'Escape') {
        cleanup();
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      }
    }

    web.document.addEventListener('keydown', onKeyDown.toJS);

    final result = await completer.future;
    web.document.removeEventListener('keydown', onKeyDown.toJS);
    return result;
  } catch (e) {
    // Stop stream if it was started
    if (stream != null) {
      final tracks = stream.getTracks().toDart;
      for (final track in tracks) {
        track.stop();
      }
    }
    return null;
  }
}
