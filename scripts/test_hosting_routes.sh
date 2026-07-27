#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:5002}"
TEST_OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/better-keep-hosting.XXXXXX")"
trap 'rm -rf "$TEST_OUTPUT"' EXIT

failures=()

request() {
  local route="$1"
  local name="$2"
  curl --silent --show-error \
    --output "$TEST_OUTPUT/$name.body" \
    --dump-header "$TEST_OUTPUT/$name.headers" \
    "$BASE_URL$route"
}

status_for() {
  awk 'toupper($1) ~ /^HTTP/ { code=$2 } END { print code }' "$1"
}

expect_status() {
  local name="$1"
  local expected="$2"
  local actual
  actual="$(status_for "$TEST_OUTPUT/$name.headers")"
  if [[ "$actual" != "$expected" ]]; then
    failures+=("$name returned $actual instead of $expected")
  fi
}

expect_header() {
  local name="$1"
  local pattern="$2"
  if ! rg --quiet --ignore-case "$pattern" "$TEST_OUTPUT/$name.headers"; then
    failures+=("$name is missing header pattern: $pattern")
  fi
}

expect_body() {
  local name="$1"
  local pattern="$2"
  if ! rg --quiet --ignore-case "$pattern" "$TEST_OUTPUT/$name.body"; then
    failures+=("$name is missing body pattern: $pattern")
  fi
}

request "/" "home"
request "/app/" "app"
request "/app/client-side-route" "app_fallback"
request "/auth" "auth"
request "/s/example" "share"
request "/welcome" "welcome"
request "/welcome.html" "welcome_html"
request "/robots.txt" "robots"
request "/sitemap.xml" "sitemap"
request "/llms.txt" "llms"
request "/indexnow-key.txt" "indexnow"
request "/changelog" "changelog"
request "/flutter_service_worker.js" "legacy_worker"
request "/this-route-does-not-exist" "missing"

expect_status "home" "200"
expect_body "home" "Your Notes,"
expect_body "home" "Reimagined"
expect_body "home" "lucide-text-cursor-input"
expect_status "app" "200"
expect_header "app" "^x-robots-tag: noindex, nofollow"
expect_status "app_fallback" "200"
expect_header "app_fallback" "^x-robots-tag: noindex, nofollow"
expect_status "auth" "200"
expect_header "auth" "^x-robots-tag: noindex, nofollow"
expect_status "share" "200"
expect_header "share" "^x-robots-tag: noindex, nofollow"
expect_status "welcome" "301"
expect_header "welcome" "^location: /"
expect_status "welcome_html" "301"
expect_header "welcome_html" "^location: /"
expect_status "robots" "200"
expect_header "robots" "^content-type: text/plain"
expect_body "robots" "OAI-SearchBot"
expect_status "sitemap" "200"
expect_header "sitemap" "^content-type: application/xml"
expect_body "sitemap" "https://betterkeep.app/google-keep-alternative"
expect_status "llms" "200"
expect_header "llms" "^content-type: text/plain"
expect_status "indexnow" "200"
expect_header "indexnow" "^content-type: text/plain"
expect_body "indexnow" "^[a-z0-9-]{8,128}$"
expect_status "changelog" "200"
expect_body "changelog" "Better Keep changelog"
expect_status "legacy_worker" "200"
expect_header "legacy_worker" "^cache-control: no-cache, no-store, must-revalidate"
expect_body "legacy_worker" "self.registration.unregister"
expect_status "missing" "404"
expect_body "missing" "Page not found"

if ((${#failures[@]})); then
  echo "Hosting route validation failed:"
  for failure in "${failures[@]}"; do
    echo "- $failure"
  done
  exit 1
fi

echo "Hosting route validation passed against $BASE_URL."
