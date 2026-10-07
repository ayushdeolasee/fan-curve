#!/bin/bash
# Stop the competing helper and restart the installed fancurve daemon.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL=com.ayush.fancurve
PLIST=/Library/LaunchDaemons/$LABEL.plist
HELPER=com.crystalidea.macsfancontrol.smcwrite

if [[ $EUID -ne 0 ]]; then
    exec sudo /bin/bash "$DIR/start.sh" "$@"
fi

if [[ ! -f "$PLIST" ]]; then
    echo "fancurve is not installed. Run: sudo $DIR/install.sh" >&2
    exit 1
fi

if pgrep -if 'Macs Fan Control.app/Contents/MacOS|macsfancontrol.app/Contents/MacOS' >/dev/null; then
    echo "Quit the Macs Fan Control app first, then run fan-start again." >&2
    exit 1
fi

if launchctl print "system/$HELPER" >/dev/null 2>&1; then
    launchctl bootout "system/$HELPER"
fi

if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    launchctl kickstart -k "system/$LABEL"
else
    launchctl bootstrap system "$PLIST"
fi

# Manual mode may take a few seconds to settle after restart.
SMC="$DIR/tools/smcFanControl/smc-command/smc"
for _ in {1..25}; do
    if "$SMC" -k F0Md -r | grep -Eq '\] +1 ' &&
       "$SMC" -k F1Md -r | grep -Eq '\] +1 '; then
        echo "✓ fancurve is running in the background and controlling both fans."
        exit 0
    fi
    sleep 0.2
done

echo "fancurve did not take control of both fans. Check /var/log/fancurve.log" >&2
exit 1
