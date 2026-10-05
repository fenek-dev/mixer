#!/bin/bash
# Regenerates Resources/AppIcon.icns from scripts/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d -t volumemixer-icon)
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
swift scripts/make-icon.swift "$WORK/icon-1024.png"

for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$WORK/icon-1024.png" --out "$SET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$WORK/icon-1024.png" --out "$SET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$WORK/icon-1024.png" Resources/AppIcon.png
echo "OK Resources/AppIcon.icns"
