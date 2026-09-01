#!/bin/bash
# Rebuild Jarvis and replace the copy in ~/Applications, then restart it.
set -e
cd "$(dirname "$0")"

echo "Building…"
xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Release \
    -derivedDataPath build build -quiet

APP="$HOME/Applications/Jarvis.app"
osascript -e 'tell application "Jarvis" to quit' 2>/dev/null || true
pkill -f "Applications/Jarvis.app/Contents/MacOS/Jarvis" 2>/dev/null || true
sleep 1

mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R build/Build/Products/Release/Jarvis.app "$APP"
codesign --force --sign - --timestamp=none "$APP"

open "$APP"
echo "Installed to $APP and launched. Look for the clap icon in the menu bar."
