import 'package:better_keep/config.dart';
import 'package:flutter/widgets.dart';

/// A wide but short window still needs drawer navigation. Reserve enough room
/// for the toolbar, navigation and account actions at the current text size.
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
      height >= 640 * textScale;
}
