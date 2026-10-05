#!/bin/bash
# Builds, installs to /Applications, relaunches.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh
pkill -x VolumeMixer || true
# Wait for the old instance to exit, or `open` attaches to it and nothing is left running.
while pgrep -x VolumeMixer >/dev/null; do sleep 0.1; done
rm -rf /Applications/VolumeMixer.app
cp -R build/VolumeMixer.app /Applications/
open /Applications/VolumeMixer.app
echo "Installed /Applications/VolumeMixer.app"
