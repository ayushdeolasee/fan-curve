#!/bin/bash
# Installs the fancurve LaunchDaemon. Run:  sudo ./install.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST=/Library/LaunchDaemons/com.ayush.fancurve.plist
LABEL=com.ayush.fancurve
LOG=/var/log/fancurve.log

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

# Config lives in the invoking user's ~/.config/fan-curve, seeded from the
# repo's fancurve.conf on first install and never overwritten after that.
TARGET_USER="${SUDO_USER:-root}"
USER_HOME=$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory | awk '{print $2}')
CONF_DIR="$USER_HOME/.config/fan-curve"
CONF="$CONF_DIR/fancurve.conf"
sudo -u "$TARGET_USER" mkdir -p "$CONF_DIR"
if [[ ! -f "$CONF" ]]; then
    sudo -u "$TARGET_USER" cp "$DIR/fancurve.conf" "$CONF"
    echo "✓ seeded config at $CONF"
fi

# Rebuild tools if the binaries are missing.
[[ -x "$DIR/tools/smctemp/smctemp" ]] || make -C "$DIR/tools/smctemp"
[[ -x "$DIR/tools/smcFanControl/smc-command/smc" ]] || make -C "$DIR/tools/smcFanControl/smc-command"

if pgrep -qf "Macs Fan Control|macsfancontrol"; then
    echo "❌ Macs Fan Control (or its background helper com.crystalidea.macsfancontrol.smcwrite)"
    echo "   is running. It re-applies its own fan settings and will revert this daemon's"
    echo "   writes. Stop it first:"
    echo "     sudo launchctl bootout system/com.crystalidea.macsfancontrol.smcwrite"
    echo "   (and quit the Macs Fan Control app if open, or uninstall it)."
    exit 1
fi

# Self-test: take manual control of fan 0, verify, release.
SMC="$DIR/tools/smcFanControl/smc-command/smc"
# smc prints e.g. "  F0Md  [ui8 ]  1 (bytes 01)" — the value is the field after "]".
read_f0md() { "$SMC" -k F0Md -r | sed -E 's/.*\] +([^ ]+).*/\1/'; }
# SMC writes land asynchronously (~0.5s) — poll for the value to settle
# instead of reading back immediately.
"$SMC" -k F0Md -w 01 >/dev/null
MODE=""
for _ in $(seq 1 25); do
    MODE=$(read_f0md)
    [[ "$MODE" == "1" ]] && break
    sleep 0.2
done
"$SMC" -k F0Md -w 00 >/dev/null
if [[ "$MODE" != "1" ]]; then
    echo "❌ SMC write self-test failed (F0Md stayed at '$MODE'). Not installing." >&2
    exit 1
fi
echo "✓ SMC write self-test passed"

# Stop any previous copy before (re)installing.
launchctl bootout system "$PLIST" 2>/dev/null || true

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$DIR/fancurve.py</string>
        <string>--config</string>
        <string>$CONF</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

# Install a `fan-status` command — a wrapper file (not a symlink) so status.sh
# still resolves the smc/smctemp tools relative to this repo.
BIN=/usr/local/bin/fan-status
install -d /usr/local/bin
cat > "$BIN" <<EOF
#!/bin/bash
exec "$DIR/status.sh" "\$@"
EOF
chmod 755 "$BIN"

cat > /usr/local/bin/fan-start <<EOF
#!/bin/bash
exec /bin/bash "$DIR/start.sh" "\$@"
EOF
chmod 755 /usr/local/bin/fan-start

launchctl bootstrap system "$PLIST"
sleep 3

echo "── first log lines ──────────────────────────"
tail -n 8 "$LOG" || true
echo "─────────────────────────────────────────────"
MODE=""
for _ in $(seq 1 25); do
    MODE=$(read_f0md)
    [[ "$MODE" == "1" ]] && break
    sleep 0.2
done
if [[ "$MODE" == "1" ]]; then
    echo "✓ Installed and running — fans are under fancurve control."
    echo "  Tune:      edit $CONF (applies live)"
    echo "  Watch:     tail -f $LOG   or   fan-status"
    echo "  Remove:    sudo $DIR/uninstall.sh"
else
    echo "❌ Daemon installed but fans are NOT in manual mode — check $LOG" >&2
    exit 1
fi
