#!/usr/bin/env bash
set -euo pipefail

if ! command -v firebase >/dev/null 2>&1; then
  echo "Firebase CLI is required: https://firebase.google.com/docs/cli"
  exit 1
fi

node_binary="$(command -v node)"

firebase emulators:exec \
  --only firestore \
  --project demo-better-keep-rules \
  --config firebase.rules-test.json \
  "\"$node_binary\" --test test/firestore_rules/note_sort_rules_test.mjs"
