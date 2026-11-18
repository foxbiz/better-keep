import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

void observeBrowserConnection(void Function(bool available) changed) {
  bool? last;
  Timer? offlineCheck;
  void refresh() {
    offlineCheck?.cancel();
    final available = web.window.navigator.onLine;
    if (available != last) {
      last = available;
      changed(available);
    }
    // Firefox can restore navigator.onLine after an offline reload without
    // delivering an online event to the new page. This reads a local flag only.
    if (!available && !web.document.hidden) {
      offlineCheck = Timer(const Duration(seconds: 5), refresh);
    }
  }

  final listener = ((web.Event _) => refresh()).toJS;
  web.window.addEventListener('offline', listener);
  web.window.addEventListener('online', listener);
  web.window.addEventListener('pageshow', listener);
  web.document.addEventListener('visibilitychange', listener);
  refresh();
}
