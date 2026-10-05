#!/bin/bash
# Builds build/VolumeMixer.app. Prints one summary line; full log path on failure.
set -euo pipefail
cd "$(dirname "$0")/.."

LOG=$(mktemp -t volumemixer-build)
if ! swift build -c release >"$LOG" 2>&1; then
    grep -E "error" "$LOG" | head -20
    echo "BUILD FAILED (log: $LOG)"
    exit 1
fi

APP=build/VolumeMixer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VolumeMixer "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# A real identity keeps the audio permission across rebuilds; ad-hoc signing resets it.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}' || true)
codesign --force --sign "${IDENTITY:--}" "$APP" 2>>"$LOG"

echo "OK $APP (signed: ${IDENTITY:-ad-hoc}, warnings: $(grep -c 'warning:' "$LOG" || true))"
