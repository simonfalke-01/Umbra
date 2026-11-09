#!/bin/bash
# Installs or removes the flip-shift daemon. Usage: sudo bash install.sh [uninstall]
set -eu
DIR=$(cd "$(dirname "$0")" && pwd)
PLIST=/Library/LaunchDaemons/app.umbra.flipshift.plist
launchctl bootout system "$PLIST" 2>/dev/null || true
if [ "${1:-}" = uninstall ]; then
  rm -f "$PLIST" "/Library/Application Support/Umbra/umbra-flipshift.sh"
  echo "flipshift removed"; exit 0
fi
mkdir -p "/Library/Application Support/Umbra"
install -m 755 -o root -g wheel "$DIR/umbra-flipshift.sh" "/Library/Application Support/Umbra/umbra-flipshift.sh"
install -m 644 -o root -g wheel "$DIR/app.umbra.flipshift.plist" "$PLIST"
launchctl bootstrap system "$PLIST"
sleep 3
launchctl print system/app.umbra.flipshift | grep -E "state|pid" | head -3
