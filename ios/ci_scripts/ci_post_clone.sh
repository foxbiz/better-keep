#!/bin/sh
set -e

# Ensure both CI scripts are executable (guards against core.fileMode=false stripping the +x bit on checkout)
chmod +x "$CI_PRIMARY_REPOSITORY_PATH/ios/ci_scripts/ci_post_clone.sh"
chmod +x "$CI_PRIMARY_REPOSITORY_PATH/ios/ci_scripts/ci_pre_xcodebuild.sh"

# Clone Flutter latest stable directly into $HOME (avoids Homebrew permission issues on Xcode Cloud)
git clone https://github.com/flutter/flutter.git --depth 1 -b stable "$HOME/flutter"

export PATH="$HOME/flutter/bin:$PATH"

echo "--- Flutter version ---"
flutter --version

# CI_PRIMARY_REPOSITORY_PATH is set by Xcode Cloud to the repo root
cd "$CI_PRIMARY_REPOSITORY_PATH"

# Generate Generated.xcconfig and fetch pub dependencies
flutter pub get

echo "--- Generated.xcconfig FLUTTER_ROOT ---"
grep FLUTTER_ROOT ios/Flutter/Generated.xcconfig

# Download iOS engine artifacts required by the Podfile post-install hook
flutter precache --ios

# Symlink flutter and dart into /usr/local/bin so xcodebuild Run Script build phases
# can find them (PATH exports in scripts don't survive into xcodebuild's environment)
ln -sf "$HOME/flutter/bin/flutter" /usr/local/bin/flutter
ln -sf "$HOME/flutter/bin/dart" /usr/local/bin/dart

# Unset any proxy settings that would prevent CocoaPods from reaching GitHub
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
git config --global --unset http.proxy || true
git config --global --unset https.proxy || true

# Install CocoaPods dependencies (generates all xcfilelist files)
cd ios && pod install
