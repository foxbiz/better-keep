#!/bin/sh
set -e

# Ensure flutter/dart symlinks exist in /usr/local/bin for xcodebuild Run Script build phases
# (PATH exports in a script subshell don't survive into xcodebuild's environment)
ln -sf "$HOME/flutter/bin/flutter" /usr/local/bin/flutter
ln -sf "$HOME/flutter/bin/dart" /usr/local/bin/dart
