#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
APP_OUTPUT="$PROJECT_DIR/build/flutter-web"
HOSTING_OUTPUT="$PROJECT_DIR/build/web"

cd "$PROJECT_DIR"

DART_DEFINE_ARGS=()
if [[ -f "$PROJECT_DIR/.env" ]]; then
  DART_DEFINE_ARGS+=(--dart-define-from-file="$PROJECT_DIR/.env")
fi

"$FLUTTER_BIN" build web \
  --release \
  --base-href=/app/ \
  --output="$APP_OUTPUT" \
  "${DART_DEFINE_ARGS[@]}"

npm --prefix "$PROJECT_DIR/site" run build

rm -rf "$HOSTING_OUTPUT"
mkdir -p "$HOSTING_OUTPUT/app" "$HOSTING_OUTPUT/media/screenshots"

cp -R "$PROJECT_DIR/site/dist/." "$HOSTING_OUTPUT/"
cp -R "$APP_OUTPUT/." "$HOSTING_OUTPUT/app/"

# Flutter copies everything under web/ into its output. Remove legacy marketing
# documents so they cannot become duplicate content below the noindex SPA scope.
for legacy_page in \
  welcome \
  encryption \
  open-source \
  self-host \
  faqs \
  pricing \
  privacy \
  terms \
  contact \
  cancellation-refund \
  delete-user
do
  rm -f "$HOSTING_OUTPUT/app/$legacy_page.html"
done
rm -f \
  "$HOSTING_OUTPUT/app/auth.html" \
  "$HOSTING_OUTPUT/app/desktop-checkout.html" \
  "$HOSTING_OUTPUT/app/reset-password.html" \
  "$HOSTING_OUTPUT/app/sitemap.xml"

cp "$PROJECT_DIR/web/favicon.ico" "$HOSTING_OUTPUT/favicon.ico"
cp -R "$PROJECT_DIR/web/icons" "$HOSTING_OUTPUT/icons"
cp "$PROJECT_DIR/web/icons/logo.png" "$HOSTING_OUTPUT/media/logo.png"
cp "$PROJECT_DIR/web/screenshots/"*.png "$HOSTING_OUTPUT/media/screenshots/"
cp -R "$PROJECT_DIR/web/.well-known" "$HOSTING_OUTPUT/.well-known"

for page in \
  auth \
  reset-password \
  desktop-checkout
do
  cp "$PROJECT_DIR/web/$page.html" "$HOSTING_OUTPUT/$page.html"
done

cp -R "$PROJECT_DIR/web/js" "$HOSTING_OUTPUT/js"
cp -R "$PROJECT_DIR/web/s" "$HOSTING_OUTPUT/s"

node "$PROJECT_DIR/scripts/validate_visibility.mjs" "$HOSTING_OUTPUT"
