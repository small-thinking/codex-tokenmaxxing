#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
"$project_dir/scripts/swiftpm.sh" build -c release --product CodexTokenmaxxing
binary_dir="$("$project_dir/scripts/swiftpm.sh" build -c release --show-bin-path)"
app_dir="$project_dir/dist/Codex Tokenmaxxing.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$binary_dir/CodexTokenmaxxing" "$app_dir/Contents/MacOS/CodexTokenmaxxing"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
echo "$app_dir"
