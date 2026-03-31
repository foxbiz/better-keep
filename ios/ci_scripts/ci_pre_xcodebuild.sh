#!/bin/sh
set -e

# Re-export Flutter PATH so xcodebuild can invoke flutter_tools during the build phase
export PATH="$HOME/flutter/bin:$PATH"
