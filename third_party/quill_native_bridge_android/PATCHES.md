# Better Keep Android clipboard patch

Based on the published `quill_native_bridge_android` **0.0.2** package:
https://pub.dev/packages/quill_native_bridge_android/versions/0.0.2

The original MIT license is retained in `LICENSE`. Only this Android
implementation is overridden by Better Keep; the Dart/Pigeon channel interface
and other platform implementations remain upstream packages.

## Changes

- Read clipboard images as their original encoded bytes instead of decoding a
  full-size bitmap and recompressing it as PNG.
- Inspect dimensions and MIME type using `BitmapFactory.Options` with
  `inJustDecodeBounds`. Header inspection is not full pixel-data validation;
  consumers still handle corrupt image payloads when rendering them.
- Write encoded clipboard bytes with the detected format's file extension so
  the existing FileProvider reports the correct MIME type. Preserve EXIF,
  transparency, animation, and source resolution. No additional resizing or
  compression policy is introduced.
- Use header inspection for gallery-save validation and remove the unused
  bitmap decoding helpers.
- Align the Android module with the app's AGP 9.0.1/Kotlin 2.2.20 compatibility
  configuration. Robolectric is a test-only dependency.

## Validation

From the app's `android` directory:

```sh
./gradlew :quill_native_bridge_android:testDebugUnitTest
```

The clipboard tests use native Android graphics under Robolectric on APIs 28
and 35. Synthetic fixtures cover transparent PNG/WebP, an EXIF-rotated JPEG,
animated GIF, and a 6000 × 4000 transparent PNG. They contain no user data.
Tests exercise byte-preserving transfer, dimensions, MIME/extension agreement,
invalid headers, missing/revoked URIs, and closing provider streams.

Before removing this override, verify that an upstream release avoids pixel
decoding in both clipboard directions and validation, and rerun these tests
against that implementation. Do not regenerate the committed Pigeon bindings
as part of this patch.
