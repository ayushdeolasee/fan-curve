#!/bin/bash
# Removes the fancurve LaunchDaemon and returns fans to macOS control.
# Run:  sudo ./uninstall.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST=/Library/LaunchDaemons/com.ayush.fancurve.plist
SMC="$DIR/tools/smcFanControl/smc-command/smc"

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

launchctl bootout system "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -f /usr/local/bin/fan-status /usr/local/bin/fan-start

# Belt and braces: the daemon restores auto mode on SIGTERM, but force it anyway.
"$SMC" -k F0Md -w 00 >/dev/null 2>&1 || true
"$SMC" -k F1Md -w 00 >/dev/null 2>&1 || true
sleep 1   # SMC writes land asynchronously

# smc prints e.g. "  F0Md  [ui8 ]  0 (bytes 00)" — the value is the field after "]".
rd() { "$SMC" -k "$1" -r | sed -E 's/.*\] +([^ ]+).*/\1/'; }
echo "✓ fancurve removed — fans are back under macOS automatic control."
echo "  (modes now: F0Md=$(rd F0Md) F1Md=$(rd F1Md) — 0 or 3 both mean macOS auto)"
