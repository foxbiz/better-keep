#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
node tool/firebase_cli.mjs --check-only --require-java
# A demo project and dedicated test emulators keep deletion tests away from real accounts.
node tool/firebase_cli.mjs -- emulators:exec \
  --only auth,firestore,storage \
  --project demo-better-keep-deletion \
  --config firebase.emulator-tests.json \
  "node functions/scripts/runTests.mjs deletion"
