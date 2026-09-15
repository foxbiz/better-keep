# Android Play recommendations: implementation and validation

The Console recommendations inspected for production **83 (1.3.2)** were
addressed in the existing **84 (1.3.3)** checkout without changing the version.
No bundle has been uploaded or published by this task.

## Changes

| Recommendation | Change |
| --- | --- |
| Edge-to-edge | `MainActivity` uses AndroidX `WindowCompat.enableEdgeToEdge(window)`. Redundant Flutter bar-color overrides were removed; icon brightness, transparent startup themes, and existing safe-area handling remain. |
| Deprecated system-bar APIs | Direct app-owned color setters were removed. Compiled dependency calls are assessed separately below. |
| Bitmap allocations | `file_picker` 12.2.0 includes bounds-first sampled compression. ZIP imports use its single-file streaming API. The Android Quill bridge preserves encoded clipboard images and uses bounds-only validation instead of allocating full pixel buffers. |
| R8 optimization | AGP 9.0.1 / Gradle 9.1.0, explicit optimized resource shrinking, and existing minification/resource shrinking. Java compilation stays at 17, SDK 36, with Flutter's existing Kotlin/DSL compatibility flags. |

The picker requires win32 6. Its compatible dependency resolution also updates
device_info_plus to 13.2.0, package_info_plus to 10.2.1, share_plus to 13.3.0,
flutter_secure_storage_windows to 4.2.2, and the Quill bridge facade/Windows
implementation to 11.2.0/0.1.0. These additional upgrades were explicitly
approved. Firebase and the secure-storage core/Darwin packages remain pinned
to their previous resolved versions. Quill 11.2.0 also restores its upstream
Linux implementation.

The scoped Android override and its license, patch description, fixtures, and
test command are in `third_party/quill_native_bridge_android/PATCHES.md`.
Image header inspection is not a full pixel-integrity check. Encoded bytes,
EXIF orientation, transparency, animation, and resolution are preserved;
the existing attachment-compression policy is unchanged.

## Automated validation

- `flutter analyze --no-pub`: no issues.
- `flutter test --no-pub`: **981 tests passed**, including nine new isolated
  picker tests and the existing ordering, auto-scroll, filtering, and image tests.
- `./gradlew :quill_native_bridge_android:testDebugUnitTest`: **23 tests passed**,
  including native-graphics clipboard tests on API 28 and 35.
- Android notification-resource policy tests: **2 passed**.
- Picker widget tests in Chrome: **9 passed**. The fixture allows a real
  event-loop turn for browser stream completion before pumping animations.
- Web release build and unsigned iOS-device/macOS Debug builds succeeded.
  The iOS scheme exposes no simulator destination. CocoaPods sandboxes were
  synchronized without changing their lockfiles or Firebase versions.
- AAB release build succeeded. Its packaged metadata reports **AGP 9.0.1**,
  **R8 9.0.32**, full mode, optimization/obfuscation/shrinking enabled, and
  `resourceOptimization.isOptimizedShrinkingEnabled=true`.
- The shrunk notification drawable retains its actual file payload.
- All **12 packaged arm64/x86_64 native libraries** have ELF load-segment
  alignment of at least 16 KB, including Whisper.
- Release APK build and `zipalign -c -P 16 4` passed. Its manifest reports
  version 84, minimum SDK 24, and compile/target SDK 36.

Use normal `flutter build appbundle --release` / `flutter build apk --release`
commands after running tests. Flutter 3.47 can leave a dev-plugin registrant
behind when a release build is invoked with `--no-pub`; the normal command
regenerates the release registrant correctly. No generated-file workaround
or test-plugin release dependency was added.

## Compiled API findings

The new AAB's own embedded mapping and DEX files were inspected together.
The Quill path calls `BitmapFactory.decodeByteArray` with `Options`, and the
picker's compression path calls both bounds and sampled decoding with
`Options`. Neither flagged path retains its former optionless image decode.

System-bar color setters remain inside **AndroidX WindowCompat** and the
**Flutter Android embedding/platform plugin** for compatibility. No such
direct call was found in the currently mapped Firebase Auth `zzjs` class;
the production-83 attribution has not been reproduced in this artifact.
Do not claim the deprecated-API Console warning has cleared. FlutterFire
was not upgraded speculatively and dependency compatibility code was not
suppressed or stripped.

Flutter also warns that its Kotlin-plugin compatibility path will be removed
in a future release. Migrating all plugins to built-in Kotlin is separate from
this explicitly selected compatibility configuration.

## Artifacts and release acceptance

Local validation artifacts, built without release-specific Dart defines:

| Artifact | SHA-256 |
| --- | --- |
| `build/app/outputs/bundle/release/app-release.aab` | `455ad9d2f31dca8e6a712ceaaa0684589a80eed5895c6bc4497ce99bee82bd9d` |
| `build/app/outputs/flutter-apk/app-release.apk` | `e217dbe5f83175ca1743dc6301eba8a042b1655bc3684f91678624e70c29a3b7` |

The release APK was installed into a fresh temporary API 35 emulator. Startup,
login scrolling, the email form, and keyboard resizing were visually checked;
gesture and three-button navigation configurations were exercised. No account
credentials were entered and no existing user data was accessed.

The remaining manual acceptance work is API 24/34/36 coverage, the full
light/dark/cutout matrix, authenticated Home/editor/sketch and notification
flows, real picker-provider ZIP imports, and Windows/Linux runtime checks.
The isolated picker tests exercise streamed imports and failures on both the
host runner and Chrome; they do not replace provider/device acceptance.

Clearing the four Console recommendations requires a separately authorized
bundle built with the release configuration and Google's processing of that
exact version. The upstream system-bar compatibility calls may still be flagged.
