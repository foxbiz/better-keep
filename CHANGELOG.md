# Changelog

All notable changes to Better Keep will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Local-only Google Keep Takeout importer with metadata preservation, duplicate
  protection, archive safety limits, cancellation, and a shareable report.
- Ethical native review prompting after sustained use and a successful import,
  export, or reminder milestone.
- Static Astro marketing site, focused switching/privacy guides, comparison
  pages, security documentation, structured data, and privacy-first aggregate
  acquisition events.
- Automated visibility, store-copy, Firebase route, external-link, and
  Lighthouse quality gates.

### Changed

- Flutter Web now lives under `/app/`; the indexable marketing site is served
  at `/`.
- Public source licensing and encryption claims now use verified,
  product-fact-backed wording.

## [1.2.2] - 2026-08-12

### Fixed

- Preserved the Android notification icon in shrunk release bundles and added
  a post-build resource payload verification gate.
- Isolated reminder initialization and scheduling from note persistence so a
  notification platform failure cannot create false sync errors or retry loops.
- Required an approved E2EE state and an available user master key for note,
  label, and ordering sync, with outgoing notes and attachments failing closed.
- Serialized startup and manual refresh work, and made note-order revision
  conflicts rebase cleanly without committing obsolete snapshots.
- Added durable bounded retries for unexpected local remote-note application
  failures, cached-entry recovery, and neutral encryption-key deferrals.

## [1.0.58] - 2026-04-13

- **Published to iOS App Store**: Better Keep version 1.0.58 is now live on the App Store for iPhone and iPad.
  - Updated app metadata, screenshots, and descriptions to reflect the latest features and improvements.
  - Ensured compliance with App Store guidelines and resolved any issues during the review process.
  - Added the public App Store link across the site and project documentation: https://apps.apple.com/us/app/better-keep-notes/id6759548198

## [1.0.43] - 2026-01-17

### Changed

- **Adaptive Toolbar Refactor**: Consolidated toolbar layout logic with per-toolbar grid mode persistence
  - Each toolbar now remembers its own expanded/collapsed state independently
  - Improved responsive icon sizing based on screen width
- Replaced QuillToolbarHistoryButton with custom UndoButton and RedoButton widgets for better control

### Removed

- Removed unused ToolbarLayoutToggleButton component (merged into AdaptiveToolbar)
- Removed unused TooltipPopover component
- Removed unused SubscriptionSettingsSection page
- Removed deprecated `appDeepLinkScheme` constant
- Removed deprecated `getToolbarIconSize()` function

### Technical

- Migrated toolbar grid mode storage from single global value to keyed per-toolbar persistence
- Updated custom icons generation script to use stdout/stderr instead of Flutter's debugPrint
- Added `-webkit-tap-highlight-color: transparent` to web index.html for better mobile UX

---

## [1.0.42] - 2026-01-16

### Added

- **Folder View**: Implemented folder view for notes with grouping by labels and colors
  - Added FolderView and FolderTile components for displaying notes in a folder structure
  - Introduced FolderBreadcrumb for navigation within folders
  - Users can now organize notes effectively by labels and colors in a hierarchical view
- **View Mode Toggle**: Added toggle to switch between grid and list view modes for notes
- **Shared Content Support**: Added support for receiving shared text and files from other apps with system labels
- **Country Detection**: Implemented country detection service for automatic currency selection in subscription flow
- **Adaptive Toolbar**: Enhanced toolbar with grid mode support and responsive icon sizing

### Changed

- Updated UI elements for better spacing and layout consistency in folder view
- Enhanced Notes component to handle folder navigation and state management
- Improved AppState to manage notes view mode and folder grouping preferences

### Fixed

- Fixed markdown export of nested lists to ensure proper indentation

### Technical

- Refactored Firebase functions to replace `admin.firestore.FieldValue` with `FieldValue` for consistency

---

## [1.0.41] - Previous Release

See git history for changes before this version.
