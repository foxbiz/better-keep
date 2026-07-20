#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace_dir="$(cd "$script_dir/.." && pwd)"

cd "$workspace_dir"
TZ=America/New_York flutter test test/reminder_dst_scenarios.dart
