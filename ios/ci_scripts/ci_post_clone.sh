#!/bin/sh
set -e

# Speed up Homebrew by skipping auto-update
export HOMEBREW_NO_AUTO_UPDATE=1

# Install Flutter (latest stable)
brew install --cask flutter

# Navigate to the Flutter project root (script runs from ios/ci_scripts/)
cd ../..

# Generate Generated.xcconfig and fetch pub dependencies
flutter pub get

# Install CocoaPods dependencies (generates xcfilelist files)
cd ios && pod install
