#!/bin/bash
# Live tests. These touch the real world: Apple Intelligence, the network, and
# the running Jarvis.app. Slower, and they need Jarvis to be installed.
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
T="-target arm64-apple-macos26.0"

echo "===== Apple Intelligence ====="
swiftc -O $T -parse-as-library -o "$OUT/intel" \
    Jarvis/Intelligence.swift Jarvis/Macro.swift Jarvis/Minecraft.swift Jarvis/AppLauncher.swift \
    Jarvis/PhraseMatcher.swift Jarvis/AppIndex.swift Jarvis/Resolver.swift \
    Jarvis/Browser.swift Tests/live/intelligence_tests.swift
"$OUT/intel"

echo
echo "===== weather ====="
mkdir -p "$OUT/wx" && cp Tests/live/weather_tests.swift "$OUT/wx/main.swift"
swiftc -O $T -o "$OUT/wxbin" \
    Jarvis/Weather.swift Jarvis/Prefs.swift Jarvis/ClapDetector.swift "$OUT/wx/main.swift"
"$OUT/wxbin"

echo
echo "===== integration (needs Jarvis.app running) ====="
mkdir -p "$OUT/ig" && cp Tests/live/integration.swift "$OUT/ig/main.swift"
swiftc -O $T -o "$OUT/igbin" "$OUT/ig/main.swift"
"$OUT/igbin"
