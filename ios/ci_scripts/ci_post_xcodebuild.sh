#!/bin/sh
set -eu

if [ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] && [ "${CI_PRODUCT_PLATFORM:-}" = "iOS" ] && [ "${CI_XCODEBUILD_EXIT_CODE:-0}" = "0" ]; then
  # Verify an exported signature; Xcode Cloud can archive with ad-hoc signing.
  signed_export=
  export_declared=0
  for candidate in "${CI_APP_STORE_SIGNED_APP_PATH:-}" "${CI_AD_HOC_SIGNED_APP_PATH:-}" "${CI_DEVELOPMENT_SIGNED_APP_PATH:-}"; do
    if [ -n "$candidate" ]; then export_declared=1; fi
    if [ -d "$candidate" ] || [ -f "$candidate" ]; then
      signed_export=$candidate
      break
    fi
  done
  if [ -z "$signed_export" ]; then
    if [ "$export_declared" = "1" ] || [ "${IMAGE_SHARE_REQUIRE_SIGNED_EXPORT:-0}" = "1" ]; then
      echo "Expected a signed iOS export for image-share provisioning verification" >&2
      exit 1
    fi
    echo "Skipping image-share signing verification for an archive-only job (no signed export declared)."
    exit 0
  fi
  script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  python3 "$script_dir/../../tool/verify_ios_image_share_signing.py" "$signed_export"
fi
