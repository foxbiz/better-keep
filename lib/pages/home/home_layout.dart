import 'package:better_keep/services/iphone_duo.dart';
import 'package:better_keep/config.dart';
import 'package:flutter/widgets.dart';

/// Widths of the note list and an open note shown side by side. Both include
/// the system inset on their outer side.
class NotePaneLayout {
  const NotePaneLayout._(this.listWidth, this.paneWidth);

  final double listWidth;
  final double paneWidth;

  /// Null when a note should fill the window, as on any device but an iPhone
  /// Duo. An open one has 867 points between its side insets.
  static NotePaneLayout? of(MediaQueryData media, TextDirection direction) {
    if (!isIPhoneDuo) return null;
    final textScale = (media.textScaler.scale(14) / 14).clamp(
      1.0,
      double.infinity,
    );
    final insets = media.viewPadding;
    final width = media.size.width - insets.horizontal;
    if (width < 840 * textScale ||
        media.size.height - insets.vertical < 480 * textScale) {
      return null;
    }
    final start = direction == TextDirection.ltr ? insets.left : insets.right;
    final listWidth = start + (width * 0.42).clamp(320.0, 420.0);
    return NotePaneLayout._(listWidth, media.size.width - listWidth);
  }
}

/// A wide but short window still needs drawer navigation. Reserve enough room
/// for the toolbar, navigation and account actions at the current text size.
/// An open iPhone Duo has 635 usable points in landscape.
/// This is a navigation policy, independent of windowed editor/page routing.
bool hasRoomForHomeSidebar(MediaQueryData media) {
  final textScale = (media.textScaler.scale(14) / 14).clamp(
    1.0,
    double.infinity,
  );
  final width = media.size.width - media.viewPadding.horizontal;
  final height = media.size.height - media.viewPadding.vertical;
  // Use viewPadding rather than keyboard insets so focusing search does not
  // switch navigation modes or move the field while the user is typing.
  return width >= bigScreenWidthThreshold * textScale &&
      height >= (isIPhoneDuo ? 600 : 640) * textScale;
}
