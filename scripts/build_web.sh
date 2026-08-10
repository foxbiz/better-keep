#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
APP_OUTPUT="$PROJECT_DIR/build/flutter-web"
HOSTING_OUTPUT="$PROJECT_DIR/build/web"
ADMIN_HOSTING_OUTPUT="$PROJECT_DIR/build/admin"

cd "$PROJECT_DIR"

DART_DEFINE_ARGS=()
if [[ -f "$PROJECT_DIR/.env" ]]; then
  DART_DEFINE_ARGS+=(--dart-define-from-file="$PROJECT_DIR/.env")
fi

rm -rf "$APP_OUTPUT"

"$FLUTTER_BIN" build web \
  --release \
  --base-href=/app/ \
  --output="$APP_OUTPUT" \
  "${DART_DEFINE_ARGS[@]}" \
  "$@"

npm --prefix "$PROJECT_DIR/site" run build
npm --prefix "$PROJECT_DIR/admin-site" run build

rm -rf "$HOSTING_OUTPUT"
mkdir -p "$HOSTING_OUTPUT/app"

cp -R "$PROJECT_DIR/site/dist/." "$HOSTING_OUTPUT/"
cp -R "$APP_OUTPUT/." "$HOSTING_OUTPUT/app/"

rm -f \
  "$HOSTING_OUTPUT/app/auth.html" \
  "$HOSTING_OUTPUT/app/desktop-checkout.html" \
  "$HOSTING_OUTPUT/app/reset-password.html"

cp -R "$PROJECT_DIR/web/icons" "$HOSTING_OUTPUT/icons"
cp -R "$PROJECT_DIR/web/.well-known" "$HOSTING_OUTPUT/.well-known"

for page in \
  auth \
  reset-password \
  desktop-checkout
do
  cp "$PROJECT_DIR/web/$page.html" "$HOSTING_OUTPUT/$page.html"
done

cp -R "$PROJECT_DIR/web/js" "$HOSTING_OUTPUT/js"

node "$PROJECT_DIR/scripts/validate_visibility.mjs" "$HOSTING_OUTPUT"

rm -rf "$ADMIN_HOSTING_OUTPUT"
mkdir -p "$ADMIN_HOSTING_OUTPUT"
cp -R "$PROJECT_DIR/admin-site/dist/." "$ADMIN_HOSTING_OUTPUT/"
node "$PROJECT_DIR/scripts/validate_admin_bundle.mjs" "$ADMIN_HOSTING_OUTPUT"
