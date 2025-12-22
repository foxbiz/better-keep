# Better Keep

![Android](https://img.shields.io/badge/Android-3DDC84?style=flat&logo=android&logoColor=white) ![iOS](https://img.shields.io/badge/iOS-000000?style=flat&logo=apple&logoColor=white) ![macOS](https://img.shields.io/badge/macOS-000000?style=flat&logo=apple&logoColor=white) ![Windows](https://img.shields.io/badge/Windows-0078D6?style=flat&logo=windows&logoColor=white) ![Linux](https://img.shields.io/badge/Linux-FCC624?style=flat&logo=linux&logoColor=black) ![Web](https://img.shields.io/badge/Web-4285F4?style=flat&logo=googlechrome&logoColor=white)

[![Google Play](https://img.shields.io/badge/Google_Play-414141?style=for-the-badge&logo=google-play&logoColor=white)](https://play.google.com/store/apps/details?id=io.foxbiz.better_keep) [![Web App](https://img.shields.io/badge/Web_App-4285F4?style=for-the-badge&logo=googlechrome&logoColor=white)](https://betterkeep.app)

 <!-- [![App Store](https://img.shields.io/badge/App_Store-0D96F6?style=for-the-badge&logo=app-store&logoColor=white)](https://apps.apple.com/app/id<YOUR_APP_ID>) -->

[![Microsoft Store](https://img.shields.io/badge/Microsoft_Store-0078D4?style=for-the-badge&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMyAyMyI+PHBhdGggZmlsbD0iI2YxZjFmMSIgZD0iTTAgMGgxMXYxMUgweiIvPjxwYXRoIGZpbGw9IiNmMWYxZjEiIGQ9Ik0xMiAwaDExdjExSDEyeiIvPjxwYXRoIGZpbGw9IiNmMWYxZjEiIGQ9Ik0wIDEyaDExdjExSDB6Ii8+PHBhdGggZmlsbD0iI2YxZjFmMSIgZD0iTTEyIDEyaDExdjExSDEyeiIvPjwvc3ZnPg==&logoColor=white)](https://apps.microsoft.com/detail/9PHT5C6WK6Q1)

Better Keep is my take on the notes app I always wanted Google Keep to be. It keeps the familiar card-based experience, then layers on richer writing, better organization, and privacy controls while staying lightning fast and offline friendly.

## Why build it?

- Google Keep is great but misses power features I rely on for project planning and journaling.
- I wanted rich-text notes, better bulk actions, and real locking with encryption without leaving the Keep workflow.
- Flutter lets me reach mobile, desktop, and web with one codebase, so the app can live everywhere I take notes.

## Highlights for everyone

- **Rich-text editor** powered by `flutter_quill` with headings, lists, formatting, and color-coded backgrounds.
- **True offline mode** backed by SQLite across desktop, mobile, and web (where supported).
- **Secure notes**: lock individual notes with a PIN; content is encrypted before hitting disk.
- **End-to-end encryption**: notes and attachments are encrypted on your device before syncing. The server never sees your plaintext data.
- **Organize faster**: labels, quick filtering, instant search, and a masonry layout that keeps pinned notes up front.
- **Stay tidy**: archive or trash in bulk, restore when needed, or delete forever with one tap.
- **Full sync**: notes, attachments, and labels sync across devices with live updates.
- **Sketch with images**: the sketch page now supports adding images for annotation.
- **Audio transcription**: record audio notes and get automatic transcription.

## Platforms

Available on **Android**, **iOS**, **macOS**, **Windows**, **Linux**, and **Web**.

## Under the hood (developer notes)

- Flutter 3.10+ with a lightweight global `AppState` pub/sub instead of heavy state frameworks.
- Persistent storage via `sqflite` (and `sqflite_common_ffi` for desktop) with thin model layers in `lib/models`.
- Rich editor and previews courtesy of `flutter_quill`; read-only rendering reuses the same deltas.
- Simple XOR + SHA-256 based encryption (`lib/utils/encryption.dart`) for locked notes, keeping secrets out of the database.
- Responsive masonry grid (`lib/pages/home/notes.dart`) that adapts to any screen width and remembers scroll position.

## Screenshots

| Login                                 | Home                                  | Editor                                |
| ------------------------------------- | ------------------------------------- | ------------------------------------- |
| ![Home screen](web/screenshots/1.jpg) | ![Rich editor](web/screenshots/2.jpg) | ![Unlock note](web/screenshots/3.jpg) |

Watch a quick walkthrough of creating and completing a reminder:

- [Youtube Short](screenshots/recording.mp4)

## Try it quickly

```bash
git clone https://github.com/deadlyjack/better-keep.git
cd better-keep
flutter pub get
```

### Running the app

The app requires environment variables defined in a `.env` file. Create one at the project root with your configuration:

```bash
# .env example
# Add your Firebase and app configuration here
# FIREBASE_API_KEY=your_api_key
# FIREBASE_PROJECT_ID=your_project_id
#
# Web storage encryption key (64-char hex string, 256 bits)
# Generate with: openssl rand -hex 32
# WEB_STORAGE_KEY=<your-64-char-hex-key>
```

**Using VS Code:**

Open the project in VS Code and use the pre-configured launch configurations in `.vscode/launch.json`:

- `better_keep` – Debug mode
- `better_keep (Profile)` – Profile mode for performance analysis
- `better_keep (Release)` – Release mode
- `better_keep (Web Server)` – Run as web server on port 63630

All configurations automatically load environment variables from `.env` via `--dart-define-from-file`.

**Using the terminal:**

```bash
flutter run --dart-define-from-file=.env
```

- Use `flutter run -d windows`, `flutter run -d macos`, `flutter run -d ios`, etc. to target a specific platform.
- Desktop builds require `sqflite_common_ffi`; the app auto-initializes it on Windows/Linux/macOS.

### Building the app

Build release versions for distribution:

**Android:**

```bash
# APK (universal)
flutter build apk --dart-define-from-file=.env

# App Bundle (recommended for Play Store)
flutter build appbundle --dart-define-from-file=.env
```

**iOS:**

```bash
flutter build ios --dart-define-from-file=.env
```

Then open `ios/Runner.xcworkspace` in Xcode to archive and distribute.

**macOS:**

```bash
flutter build macos --dart-define-from-file=.env
```

The app will be at `build/macos/Build/Products/Release/better_keep.app`.

**Windows:**

```bash
flutter build windows --dart-define-from-file=.env
```

The app will be at `build/windows/x64/runner/Release/`.

**Linux:**

```bash
flutter build linux --dart-define-from-file=.env
```

The app will be at `build/linux/x64/release/bundle/`.

**Web:**

```bash
flutter build web --dart-define-from-file=.env
```

The output will be in `build/web/`. Deploy to any static hosting service.

## Project layout

```text
lib/
  app.dart               # MaterialApp, localization, theming
  config.dart            # App configuration and constants
  main.dart              # DB bootstrapping and platform init
  state.dart             # Global event-driven state store
  models/
    base_model.dart      # Base class for all models
    note.dart            # Note schema with sync support
    label.dart           # Label schema
    note_attachment.dart # Base attachment model
    note_image.dart      # Image attachment model
    note_recording.dart  # Audio recording with transcription
    sketch.dart          # Sketch/drawing data
    reminder.dart        # Reminder/alarm model
    *_sync_track.dart    # Sync tracking for notes, labels, files
  pages/
    home/                # Masonry feed, sidebar, labels, search
    note_editor/         # Rich-text editor, toolbar, actions
    sketch_page.dart     # Sketch editor with image support
    image_viewer.dart    # Full-screen image viewer
    login_page.dart      # Authentication UI
    user_page.dart       # User profile and settings
    settings.dart        # App settings
    nerd_stats_page.dart # Usage statistics
  services/
    database.dart        # SQLite database management
    auth_service.dart    # Firebase authentication
    note_sync_service.dart   # Note sync with Firestore
    label_sync_service.dart  # Label sync with Firestore
    file_system.dart     # Cross-platform file handling
    alarm_id_service.dart    # Reminder/alarm management
  components/            # Reusable UI (note card, animated icons, etc.)
  dialogs/               # Prompt, confirm, color picker, label manager
  themes/                # Dark theme configuration
  ui/                    # UI utilities and widgets
  utils/                 # Encryption, helpers, utilities
assets/
  sounds/                # Audio files for alarms/notifications
  ...                    # Fonts, images, lottie, etc. (see `pubspec.yaml`)
```

## Local data model

- **`note`** table: title, rich-text JSON content, labels (comma separated), color, archival flags, timestamps, lock metadata, sync status.
- **`label`** table: user-managed labels with conflict-safe upserts and sync tracking.
- **`note_image`** table: image attachments linked to notes with local/remote paths.
- **`note_recording`** table: audio recordings with transcription text and duration.
- **`sketch`** table: drawing data with stroke information and background images.
- **`reminder`** table: scheduled reminders with alarm support.
- **`*_sync_track`** tables: track sync state for notes, labels, and files.
- Locked notes store encrypted content; unlocking decrypts in-memory only.

## Sync & Conflict Resolution

Better Keep implements a robust **Local-First** sync strategy using Firebase Firestore and Storage with **live syncing** capabilities.

### What Syncs

- **Notes**: Full note content, metadata, and settings.
- **Labels**: User-created labels sync across all devices.
- **Attachments**: Images, audio recordings, and sketches.

### Live Sync

The app listens to Firestore in real-time. Changes made on one device appear on other devices within seconds, without requiring manual refresh.

### Sync Policy: "Newest Wins"

To ensure data integrity across devices, the app uses a timestamp-based conflict resolution strategy:

1.  **Pushing Changes**:
    - Before pushing a local update to the cloud, the app fetches the current remote version.
    - **Comparison**: It compares the `updatedAt` timestamp of the local item against the remote.
    - **Resolution**:
      - If **Remote is Newer**: The push is aborted. The local item is immediately updated with the newer remote data (effectively a "pull" operation).
      - If **Local is Newer**: The local changes are pushed to Firestore, overwriting the older remote version.

### Duplicate Prevention

- **Local IDs**: Each note and label maintains a `local_id` which is synced to Firestore.
- **Re-installation**: If the app is re-installed or the local database is cleared, the sync process uses the `local_id` from Firestore to map remote items back to the correct local records, preventing duplicate entries.

### Storage & Attachments

- **Full Attachment Sync**: Images, audio recordings (with transcriptions), and sketches are synced to Firebase Storage.
- **Recursive Deletion**: When a note is deleted, a recursive cleanup process ensures all associated files are permanently removed from Firebase Storage.
- **Offline Support**: Attachments are downloaded locally. The app prefers local files when available and syncs new attachments in the background.
- **File Sync Tracking**: A dedicated tracking system ensures attachments are properly synced and handles retries for failed uploads.

## Development workflows

### Firebase Setup (Required for Sync)

This project uses Firebase for sync and authentication. Since `firebase_options.dart` is git-ignored for security, you must configure your own Firebase project:

1.  Install the Firebase CLI: `npm install -g firebase-tools`
2.  Log in: `firebase login`
3.  Activate FlutterFire CLI: `dart pub global activate flutterfire_cli`
4.  Configure the app:
    ```bash
    flutterfire configure
    ```
    - Select your Firebase project (or create a new one).
    - Select the platforms you want to support (Android, iOS, Web, macOS, Windows).
    - This will generate `lib/firebase_options.dart`.
5.  Enable **Authentication** (Google Sign-In) and **Firestore Database** in your Firebase Console.

- `flutter pub get` – install dependencies.
- `flutter analyze` – static analysis.
- `dart format lib test` – keep style consistent.
- `flutter test` – run widget and unit tests (extend coverage as features grow).

## Roadmap

- [x] End-to-end encryption (E2EE) for notes and attachments. See [E2EE Documentation](docs/E2EE.md).
- [x] Light and dark theme support.
- [x] Fix alarm notifications on iOS.
- [x] Optimize sketch saving (reduce file size by lowering precision).
- [x] Revenue model implementation.
- [ ] Calendar-grade reminders and recurring nudges.
- [ ] Widgets and quick actions on mobile/desktop.
- [ ] Theme editor (custom colors).

## Contributing & feedback

- Issues and feature requests welcome via GitHub.
- Fork, branch (`git checkout -b feature/<name>`), add tests, and open a PR once `flutter analyze` and tests pass.
- Reach out in Discussions if you want to coordinate on a larger feature.

## License

This project is licensed under the **Creative Commons Attribution-NonCommercial 4.0 International Public License (CC BY-NC 4.0)**.

You are free to:

- **Share** — copy and redistribute the material in any medium or format.
- **Adapt** — remix, transform, and build upon the material.

Under the following terms:

- **Attribution** — You must give appropriate credit, provide a link to the license, and indicate if changes were made.
- **NonCommercial** — You may not use the material for commercial purposes.

See the [LICENSE](LICENSE) file for details.
