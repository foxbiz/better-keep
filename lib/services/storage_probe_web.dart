import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<({int? availableBytes, double? usageRatio})> probeStorage() async {
  final estimate = await web.window.navigator.storage.estimate().toDart;
  final quota = estimate.quota;
  final usage = estimate.usage;
  // Chromium masks available capacity with whole-GiB buckets added to usage.
  // Such a value cannot establish that a previous quota failure has recovered.
  const gib = 1024 * 1024 * 1024;
  final remaining = quota - usage;
  final masked = remaining > 0 && remaining % gib == 0;
  return (
    availableBytes: null,
    usageRatio: quota > 0 && !masked ? usage / quota : null,
  );
}
