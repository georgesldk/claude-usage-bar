#!/bin/bash
# Builds "Claude Usage.app" and installs it to ~/Applications
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Claude Usage.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 \
  Sources/*.swift -lsqlite3 -o "$APP/Contents/MacOS/ClaudeUsageBar"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

pkill -x ClaudeUsageBar 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Claude Usage.app"
cp -R "$APP" "$HOME/Applications/"
echo ""
echo "Installed: $HOME/Applications/Claude Usage.app"
