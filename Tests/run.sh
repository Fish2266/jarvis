#!/bin/bash
# Offline tests: clap detection, phrase matching, and command resolution.
# No microphone, no network, no model. Safe to run any time.
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
T="-target arm64-apple-macos26.0"

echo "===== DSP + phrase matching ====="
swiftc -O $T -o "$OUT/dsp" \
    Jarvis/ClapDetector.swift Jarvis/PhraseMatcher.swift Jarvis/Prefs.swift \
    Tests/dsp/main.swift
"$OUT/dsp"

echo
echo "===== command resolution ====="
swiftc -O $T -o "$OUT/resolver" \
    Jarvis/PhraseMatcher.swift Jarvis/AppIndex.swift Jarvis/Macro.swift \
    Jarvis/Resolver.swift Jarvis/AppLauncher.swift Jarvis/Browser.swift \
    Tests/resolver/main.swift
"$OUT/resolver"

echo
echo "===== Chrome profiles ====="
swiftc -O $T -o "$OUT/browser" \
    Jarvis/Browser.swift Jarvis/Macro.swift Jarvis/AppLauncher.swift \
    Jarvis/AppIndex.swift Jarvis/PhraseMatcher.swift \
    Tests/browser/main.swift
"$OUT/browser"

echo
echo "===== profiles, tabs and reminders ====="
swiftc -O $T -o "$OUT/features" \
    Jarvis/PhraseMatcher.swift Jarvis/AppIndex.swift Jarvis/Macro.swift \
    Jarvis/Resolver.swift Jarvis/AppLauncher.swift Jarvis/Browser.swift \
    Jarvis/Reminders.swift Tests/features/main.swift
"$OUT/features"

echo
echo "===== voice ====="
swiftc -O $T -o "$OUT/voice" \
    Jarvis/VoiceBox.swift Jarvis/Prefs.swift Jarvis/ClapDetector.swift \
    Tests/voice/main.swift
"$OUT/voice"

echo
echo "===== questions ====="
swiftc -O $T -o "$OUT/questions" \
    Jarvis/PhraseMatcher.swift Jarvis/AppIndex.swift Jarvis/Macro.swift \
    Jarvis/Resolver.swift Jarvis/AppLauncher.swift Jarvis/Browser.swift \
    Jarvis/Questions.swift Jarvis/Intelligence.swift Tests/questions/main.swift
"$OUT/questions"

echo
echo "===== answer strip + voice envelope ====="
swiftc -O $T -o "$OUT/readout" \
    Jarvis/AnswerBar.swift Jarvis/HUDStyle.swift Jarvis/VoiceBox.swift \
    Jarvis/Prefs.swift Jarvis/ClapDetector.swift Tests/readout/main.swift
"$OUT/readout"

echo
echo "===== sleep command ====="
swiftc -O $T -o "$OUT/sleep" \
    Jarvis/PhraseMatcher.swift Jarvis/AppIndex.swift Jarvis/Macro.swift \
    Jarvis/Resolver.swift Jarvis/AppLauncher.swift Jarvis/Browser.swift \
    Tests/sleep/main.swift
"$OUT/sleep"
