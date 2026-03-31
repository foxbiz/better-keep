#!/bin/sh
set -e

# Clone Flutter latest stable directly into $HOME (avoids Homebrew permission issues on Xcode Cloud)
git clone https://github.com/flutter/flutter.git --depth 1 -b stable "$HOME/flutter"

export PATH="$HOME/flutter/bin:$PATH"

# CI_PRIMARY_REPOSITORY_PATH is set by Xcode Cloud to the repo root
cd "$CI_PRIMARY_REPOSITORY_PATH"

# Generate Generated.xcconfig and fetch pub dependencies
flutter pub get

# Download iOS engine artifacts required by the Podfile post-install hook
flutter precache --ios

# Install CocoaPods dependencies (generates all xcfilelist files)
cd ios && pod install
