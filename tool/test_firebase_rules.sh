#!/usr/bin/env bash
set -euo pipefail

node tool/firebase_cli.mjs -- emulators:exec \
  --only firestore,storage \
  --project demo-better-keep-rules \
  --config firebase.rules-test.json \
  "node --test --test-concurrency=1 test/firestore_rules/*.mjs test/storage_rules/*.mjs"
