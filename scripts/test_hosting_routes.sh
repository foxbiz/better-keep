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
astro_asset_path="$(
  rg --only-matching '/_astro/[^"[:space:]<>]+\.[[:alnum:]_-]{8,}\.(css|js)' \
    "$TEST_OUTPUT/home.body" |
    head -n 1 || true
)"
if [[ -n "$astro_asset_path" ]]; then
  request "$astro_asset_path" "astro_asset"
else
  failures+=("home does not reference a fingerprinted Astro asset")
fi
request "/app/" "app"
request "/app/client-side-route" "app_fallback"
request "/app/manifest.json" "app_manifest"
request "/media/screenshots/2.png" "manifest_screenshot"
request "/icons/platforms/apple.svg" "redundant_platform_icon"
request "/icons/store-badges/app-store.svg" "redundant_store_badge"
request "/auth" "auth"
request "/s/example" "share"
request "/welcome" "welcome"
request "/welcome.html" "welcome_html"
request "/encryption.html" "encryption_html"
request "/open-source.html" "open_source_html"
request "/self-host.html" "self_host_html"
request "/faqs.html" "faqs_html"
request "/privacy" "privacy"
request "/terms" "terms"
request "/pricing" "pricing"
request "/contact" "contact"
request "/cancellation-refund" "cancellation_refund"
request "/delete-user" "delete_user"
request "/robots.txt" "robots"
request "/sitemap.xml" "sitemap"
request "/llms.txt" "llms"
request "/indexnow-key.txt" "indexnow"
request "/changelog" "changelog"
request "/flutter_service_worker.js" "legacy_worker"
request "/this-route-does-not-exist" "missing"

expect_status "home" "200"
expect_header "home" "^cache-control: no-cache, max-age=0, must-revalidate"
expect_body "home" "Notes that stay"
expect_body "home" "out of your way"
expect_body "home" "media/brand/logo.svg"
expect_body "home" "data-platform-icon=.apple"
if [[ -n "$astro_asset_path" ]]; then
  expect_status "astro_asset" "200"
  expect_header "astro_asset" "^cache-control: public, max-age=31536000, immutable"
fi
expect_status "app" "200"
expect_header "app" "^x-robots-tag: noindex, nofollow"
expect_status "app_fallback" "200"
expect_header "app_fallback" "^x-robots-tag: noindex, nofollow"
expect_status "app_manifest" "200"
expect_body "app_manifest" '"src": "/media/screenshots/2.png"'
expect_status "manifest_screenshot" "200"
expect_header "manifest_screenshot" "^content-type: image/png"
expect_header "manifest_screenshot" "^cache-control: public, max-age=86400"
expect_status "redundant_platform_icon" "404"
expect_status "redundant_store_badge" "404"
expect_status "auth" "200"
expect_header "auth" "^x-robots-tag: noindex, nofollow"
expect_status "share" "200"
expect_header "share" "^x-robots-tag: noindex, nofollow"
expect_body "share" "Securely shared through Better Keep"
expect_body "share" "data-share-screen=.?loading"
expect_body "share" "media/brand/logo.svg"
expect_status "welcome" "301"
expect_header "welcome" "^location: /"
expect_status "welcome_html" "301"
expect_header "welcome_html" "^location: /"
expect_status "encryption_html" "301"
expect_header "encryption_html" "^location: /security"
expect_status "open_source_html" "301"
expect_header "open_source_html" "^location: /source-available-notes"
expect_status "self_host_html" "301"
expect_header "self_host_html" "^location: /source-available-notes"
expect_status "faqs_html" "301"
expect_header "faqs_html" "^location: /google-keep-alternative"
expect_status "privacy" "200"
expect_body "privacy" "Privacy Policy"
expect_status "terms" "200"
expect_body "terms" "Terms of Service"
expect_status "pricing" "200"
expect_body "pricing" "Feature Comparison"
expect_status "contact" "200"
expect_body "contact" "Contact Better Keep"
expect_status "cancellation_refund" "200"
expect_body "cancellation_refund" "Cancellation and Refund Policy"
expect_status "delete_user" "200"
expect_body "delete_user" "Delete Your Account"
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
