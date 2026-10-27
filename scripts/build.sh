#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
bundle="$PWD/dist/Codex Usage Monitor.app"
if [[ -e "$bundle" || -L "$bundle" ]]; then
    echo "Remove or move the existing bundle before rebuilding: $bundle" >&2
    exit 1
fi
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_dir/CodexUsageMonitor" "$bundle/Contents/MacOS/"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp Resources/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
printf 'Built %s\n' "$bundle"
