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
echo "===== phrase matching, exact and cut short ====="
swiftc -O $T -o "$OUT/matcher" \
    Jarvis/PhraseMatcher.swift Jarvis/AppIndex.swift Jarvis/Macro.swift \
    Jarvis/Resolver.swift Jarvis/AppLauncher.swift Jarvis/Browser.swift \
    Tests/matcher/main.swift
"$OUT/matcher"

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
    Jarvis/Questions.swift Jarvis/Intelligence.swift Jarvis/Calc.swift \
    Jarvis/SystemInfo.swift Jarvis/Agenda.swift Jarvis/Clipboard.swift \
    Tests/questions/main.swift
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

echo
echo "===== audit regressions ====="
swiftc -O $T -o "$OUT/audit" \
    Jarvis/PhraseMatcher.swift Jarvis/AppIndex.swift Jarvis/Macro.swift \
    Jarvis/Resolver.swift Jarvis/AppLauncher.swift Jarvis/Browser.swift \
    Tests/audit/main.swift
"$OUT/audit"

echo
echo "===== bring it over ====="
swiftc -O $T -o "$OUT/bring" \
    Jarvis/PhraseMatcher.swift Jarvis/AppIndex.swift Jarvis/Macro.swift \
    Jarvis/Resolver.swift Jarvis/AppLauncher.swift Jarvis/Browser.swift \
    Jarvis/Spaces.swift Tests/bring/main.swift
"$OUT/bring"

echo
echo "===== talking to Chrome ====="
swiftc -O $T -o "$OUT/applescript" \
    Jarvis/PhraseMatcher.swift Jarvis/AppIndex.swift Jarvis/Macro.swift \
    Jarvis/AppLauncher.swift Jarvis/Browser.swift \
    Tests/applescript/main.swift
"$OUT/applescript"

echo
echo "===== a fresh tab ====="
swiftc -O $T -o "$OUT/tabs" \
    Jarvis/PhraseMatcher.swift Jarvis/AppIndex.swift Jarvis/Macro.swift \
    Jarvis/Resolver.swift Jarvis/AppLauncher.swift Jarvis/Browser.swift \
    Tests/tabs/main.swift
"$OUT/tabs"

echo
echo "===== hand gestures ====="
swiftc -O $T -o "$OUT/gestures" \
    Jarvis/Gestures.swift Tests/gestures/main.swift
"$OUT/gestures"

echo
echo "===== keyboard trigger ====="
swiftc -O $T -o "$OUT/trigger" \
    Jarvis/Prefs.swift Jarvis/ClapDetector.swift Tests/trigger/main.swift
"$OUT/trigger"

echo
echo "===== the new commands ====="
swiftc -O $T -o "$OUT/commands" \
    Jarvis/PhraseMatcher.swift Jarvis/AppIndex.swift Jarvis/Macro.swift \
    Jarvis/Resolver.swift Jarvis/AppLauncher.swift Jarvis/Browser.swift \
    Tests/commands/main.swift
"$OUT/commands"

echo
echo "===== exact answers ====="
swiftc -O $T -o "$OUT/answers" \
    Jarvis/PhraseMatcher.swift Jarvis/Calc.swift Jarvis/Countdown.swift \
    Jarvis/SystemAudio.swift Jarvis/MediaKeys.swift Jarvis/Spaces.swift \
    Jarvis/WebSearch.swift Jarvis/SystemInfo.swift Jarvis/Agenda.swift \
    Jarvis/Questions.swift Jarvis/Resolver.swift Jarvis/Macro.swift \
    Jarvis/AppIndex.swift Jarvis/AppLauncher.swift Jarvis/Browser.swift \
    Jarvis/HUDStyle.swift Jarvis/Clipboard.swift Jarvis/KeepAwake.swift \
    Jarvis/WindowManager.swift Tests/answers/main.swift
"$OUT/answers"
