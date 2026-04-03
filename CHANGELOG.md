# Changelog

All notable changes to Better Keep will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.58] - 2026-04-03

- **Publish to IOS App Store**: Successfully published Better Keep version 1.0.58 to the iOS App Store, making it available for download on iPhone and iPad devices.
  - Updated app metadata, screenshots, and descriptions to reflect the latest features and improvements.
  - Ensured compliance with App Store guidelines and resolved any issues during the review process.

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
