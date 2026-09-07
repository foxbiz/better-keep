import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartTestOut: 'test/test_api.g.dart',
    // Using `GeneratedMessages.kt` instead of `Messages.g.kt` to follow
    // Kotlin conventions: https://kotlinlang.org/docs/coding-conventions.html#source-file-names
    kotlinOut:
        'android/src/main/kotlin/dev/flutterquill/quill_native_bridge/generated/GeneratedMessages.kt',
    kotlinOptions: KotlinOptions(
      package: 'dev.flutterquill.quill_native_bridge.generated',
    ),
    dartPackageName: 'quill_native_bridge_android',
  ),
)
@HostApi(dartHostTestHandler: 'TestQuillNativeBridgeApi')
abstract class QuillNativeBridgeApi {
  // HTML
  String? getClipboardHtml();
  void copyHtmlToClipboard(String html);

  // Image
  Uint8List? getClipboardImage();
  void copyImageToClipboard(Uint8List imageBytes);
  Uint8List? getClipboardGif();

  void openGalleryApp();

  /// The [fileExtension] is only required for Android APIs before 29.
  @async
  void saveImageToGallery(
    Uint8List imageBytes, {
    required String name,
    required String fileExtension,
    required String mimeType,
    required String? albumName,
  });
}
