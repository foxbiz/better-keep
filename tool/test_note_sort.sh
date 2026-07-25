#!/usr/bin/env bash
set -euo pipefail

FLUTTER_BIN="${FLUTTER_BIN:-flutter}"

"$FLUTTER_BIN" test \
  --concurrency=1 \
  test/masonry_layout_golden_test.dart \
  test/masonry_layout_test.dart \
  test/note_sort_service_test.dart \
  test/note_sort_widgets_test.dart
