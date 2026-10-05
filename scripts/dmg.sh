#!/bin/bash
# Builds build/VolumeMixer.dmg: the app plus an Applications shortcut to drag it onto.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh

STAGE=$(mktemp -d -t volumemixer-dmg)
# Same name as scripts/install.sh uses, so dragging replaces that copy instead of adding a second.
cp -R build/VolumeMixer.app "$STAGE/VolumeMixer.app"
ln -s /Applications "$STAGE/Applications"

DMG=build/VolumeMixer.dmg
hdiutil create -volname "Volume Mixer" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "OK $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
