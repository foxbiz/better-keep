// This file is referenced by pubspec.yaml. If you plan on moving this file
// Make sure to update pubspec.yaml to the new location.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:quill_native_bridge_platform_interface/internal.dart';
import 'package:quill_native_bridge_platform_interface/quill_native_bridge_platform_interface.dart';

import 'src/messages.g.dart';

/// An implementation of [QuillNativeBridgePlatform] for Android.
class QuillNativeBridgeAndroid extends QuillNativeBridgePlatform {
  final QuillNativeBridgeApi _hostApi = QuillNativeBridgeApi();

  /// Registers this class as the default instance of [QuillNativeBridgePlatform].
  static void registerWith() {
    QuillNativeBridgePlatform.instance = QuillNativeBridgeAndroid();
  }

  @override
  Future<bool> isSupported(QuillNativeBridgeFeature feature) async => {
    QuillNativeBridgeFeature.getClipboardHtml,
    QuillNativeBridgeFeature.copyHtmlToClipboard,
    QuillNativeBridgeFeature.copyImageToClipboard,
    QuillNativeBridgeFeature.getClipboardImage,
    QuillNativeBridgeFeature.getClipboardGif,
    QuillNativeBridgeFeature.openGalleryApp,
    QuillNativeBridgeFeature.saveImageToGallery,
  }.contains(feature);

  @override
  Future<String?> getClipboardHtml() async => _hostApi.getClipboardHtml();

  @override
  Future<void> copyHtmlToClipboard(String html) =>
      _hostApi.copyHtmlToClipboard(html);

  @override
  Future<Uint8List?> getClipboardImage() async {
    try {
      return await _hostApi.getClipboardImage();
    } on PlatformException catch (e) {
      if (kDebugMode &&
          (e.code == 'FILE_READ_PERMISSION_DENIED' ||
              e.code == 'FILE_NOT_FOUND')) {
        _printAndroidClipboardImageAccessKnownIssue(e);
        return null;
      }
      rethrow;
    }
  }

  @override
  Future<void> copyImageToClipboard(Uint8List imageBytes) async {
    try {
      await _hostApi.copyImageToClipboard(imageBytes);
    } on PlatformException catch (e) {
      assert(() {
        if (e.code == 'ANDROID_MANIFEST_NOT_CONFIGURED') {
          throw StateError(
            '\nThe AndroidManifest.xml file was not configured to support copying images to the clipboard on Android\n'
            'For more details, refer to https://pub.dev/packages/quill_native_bridge#-copying-images-to-the-system-clipboard\n'
            'This exception will be only thrown in debug mode.\n\n'
            'Platform error details: ${e.toString()}',
          );
        }
        return true;
      }());

      rethrow;
    }
  }

  @override
  Future<Uint8List?> getClipboardGif() async {
    try {
      return await _hostApi.getClipboardGif();
    } on PlatformException catch (e) {
      if (kDebugMode &&
          (e.code == 'FILE_READ_PERMISSION_DENIED' ||
              e.code == 'FILE_NOT_FOUND')) {
        _printAndroidClipboardImageAccessKnownIssue(e);
        return null;
      }
      rethrow;
    }
  }

  // TODO: Create issue https://github.com/singerdmx/flutter-quill/issues/2243
  //  in this repo and update the current references to the new issue
  /// Should be only used internally for [getClipboardGif] and [getClipboardImage]
  /// for **Android only**.
  ///
  /// This issue can be caused by `SecurityException` or `FileNotFoundException`
  /// from Android side.
  ///
  /// See [#2243](https://github.com/singerdmx/flutter-quill/issues/2243) for more details.
  void _printAndroidClipboardImageAccessKnownIssue(PlatformException e) {
    if (kDebugMode) {
      debugPrint(
        'Could not retrieve the image from clipbaord as the app no longer have access to the image.\n'
        'This can happen on app restart or lifecycle changes.\n'
        'This is known issue on Android and this message will be only shown in debug mode.\n'
        'Refer to https://github.com/singerdmx/flutter-quill/issues/2243 for discussion.\n'
        'A similar but unrelated issue in Flutter `imager_picker`: https://github.com/flutter/flutter/issues/100025'
        'Platform error details: ${e.toString()}',
      );
    }
  }

  @override
  Future<void> openGalleryApp() => _hostApi.openGalleryApp();

  @override
  Future<void> saveImageToGallery(
    Uint8List imageBytes, {
    required GalleryImageSaveOptions options,
  }) async {
    try {
      await _hostApi.saveImageToGallery(
        imageBytes,
        name: options.name,
        fileExtension: options.fileExtension,
        mimeType: getImageMimeType(options.fileExtension),
        albumName: options.albumName,
      );
    } on PlatformException catch (e) {
      assert(() {
        if (e.code == 'ANDROID_MANIFEST_NOT_CONFIGURED') {
          throw StateError(
            '\nThe AndroidManifest.xml file was not configured to support saving images to the gallery on Android 9 (API 28).\n'
            'The `WRITE_EXTERNAL_STORAGE` permission is required only on previous versions of Android.\n'
            'For more details, refer to https://pub.dev/packages/quill_native_bridge#-saving-images-to-the-gallery\n'
            'This exception will be only thrown in debug mode.\n\n'
            'Platform error details: ${e.toString()}',
          );
        }
        return true;
      }());
      rethrow;
    }
  }
}
