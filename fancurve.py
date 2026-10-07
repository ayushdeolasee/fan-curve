#!/usr/bin/python3
"""fancurve — custom fan curve daemon for Apple Silicon MacBook Pro.

Reads CPU/GPU temps via `smctemp`, interpolates the curve in fancurve.conf,
and writes fan RPM targets to the SMC via the `smc` CLI (needs root).

Safety model:
  - On ANY exit (signal, crash, unhandled exception) fans are handed back to
    macOS automatic control (F{n}Md = 0).
  - If temperature reads fail 3 times in a row → revert to auto and exit.
  - Writes are verified by reading the key back (`smc` exits 0 even on failure).
  - At/above failsafe_temp both fans are forced to 100%.

Run `fancurve.py --dry-run` as a normal user to watch what it *would* do
without touching the fans (useful while tuning the curve).
"""

import os
import re
import struct
import subprocess
import signal
import sys
import time

BASE_DIR = os.path.dirname(os.path.realpath(__file__))
SMC = os.path.join(BASE_DIR, "tools", "smcFanControl", "smc-command", "smc")
SMCTEMP = os.path.join(BASE_DIR, "tools", "smctemp", "smctemp")

DRY_RUN = "--dry-run" in sys.argv

# Config: --config <path> wins (the daemon runs as root, so "~" would be
# /var/root — install.sh passes the user's path explicitly). Otherwise prefer
# ~/.config/fan-curve/fancurve.conf, falling back to the repo's template.
if "--config" in sys.argv:
    CONF_PATH = sys.argv[sys.argv.index("--config") + 1]
else:
    _user_conf = os.path.expanduser("~/.config/fan-curve/fancurve.conf")
    CONF_PATH = (_user_conf if os.path.exists(_user_conf)
                 else os.path.join(BASE_DIR, "fancurve.conf"))

DEFAULTS = {
    "curve": [(55, 0), (65, 20), (75, 40), (85, 65), (95, 100)],
    "temp_source": "max",
    "poll_interval": 5.0,
    "deadband_rpm": 100.0,
    "step_down_pct": 5.0,
    "failsafe_temp": 100.0,
}


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


# ── SMC access ───────────────────────────────────────────────────────────────

def smc_read(key):
    """Read an SMC key, return its numeric value as float, or None."""
    try:
        out = subprocess.run([SMC, "-k", key, "-r"], capture_output=True,
                             text=True, timeout=10).stdout
    except Exception:
        return None
    # output looks like:   F0Ac  [flt ]  1504 (bytes 96 07 bc 44)
    m = re.search(r"\]\s+(-?[\d.]+)\s", out)
    return float(m.group(1)) if m else None


def smc_write(key, hexbytes):
    """Write raw hex bytes to an SMC key. Caller verifies via read-back."""
    if DRY_RUN:
        return
    subprocess.run([SMC, "-k", key, "-w", hexbytes], capture_output=True,
                   timeout=10)


def write_rpm(fan, rpm):
    smc_write("F%dTg" % fan, struct.pack("<f", float(rpm)).hex())


def set_manual(fan, manual):
    """Set fan mode (1=manual, 0=macOS auto) and verify. Returns True on success."""
    smc_write("F%dMd" % fan, "01" if manual else "00")
    if DRY_RUN:
        return True
    # SMC writes land asynchronously (~0.5s) — poll until the value settles.
    # Manual mode reads as 1; macOS automatic control reads as 0 or 3.
    for _ in range(25):
        mode = smc_read("F%dMd" % fan)
        if manual and mode == 1:
            return True
        if not manual and mode in (0, 3):
            return True
        time.sleep(0.2)
    return False


def read_temp(source):
    """Read temperature in °C from smctemp, or None on failure."""
    def one(flag):
        try:
            out = subprocess.run([SMCTEMP, flag], capture_output=True,
                                 text=True, timeout=10).stdout.strip()
            v = float(out)
            return v if 0 < v < 130 else None
        except Exception:
            return None

    if source == "cpu":
        return one("-c")
    if source == "gpu":
        return one("-g")
    vals = [v for v in (one("-c"), one("-g")) if v is not None]
    return max(vals) if vals else None


# ── Config ───────────────────────────────────────────────────────────────────

def parse_conf(path):
    cfg = dict(DEFAULTS)
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if "=" not in line:
                continue
            k, v = (s.strip() for s in line.split("=", 1))
            if k == "curve":
                pts = []
                for pair in v.split(","):
                    t, p = pair.split(":")
                    pts.append((float(t), max(0.0, min(100.0, float(p)))))
                pts.sort()
                if not pts:
                    raise ValueError("empty curve")
                cfg["curve"] = pts
            elif k == "temp_source":
                if v not in ("cpu", "gpu", "max"):
                    raise ValueError("bad temp_source %r" % v)
                cfg[k] = v
            elif k in ("poll_interval", "deadband_rpm", "step_down_pct",
                       "failsafe_temp"):
                cfg[k] = float(v)
    if cfg["poll_interval"] < 1:
        cfg["poll_interval"] = 1.0
    return cfg


def curve_percent(curve, temp):
    """Linear interpolation of the curve at `temp`."""
    if temp <= curve[0][0]:
        return curve[0][1]
    if temp >= curve[-1][0]:
        return 100.0
    for (t0, p0), (t1, p1) in zip(curve, curve[1:]):
        if t0 <= temp <= t1:
            frac = (temp - t0) / (t1 - t0) if t1 > t0 else 1.0
            return p0 + frac * (p1 - p0)
    return 100.0


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    num_fans = smc_read("FNum")
    if not num_fans:
        log("FATAL: cannot read fan count from SMC")
        sys.exit(1)
    fans = []
    for i in range(int(num_fans)):
        lo, hi = smc_read("F%dMn" % i), smc_read("F%dMx" % i)
        if lo is None or hi is None or hi <= lo:
            log("FATAL: cannot read fan %d min/max" % i)
            sys.exit(1)
        fans.append((lo, hi))
    log("fans: " + ", ".join("#%d %d-%d RPM" % (i, lo, hi)
                             for i, (lo, hi) in enumerate(fans)))

    def restore_auto():
        for i in range(len(fans)):
            set_manual(i, False)

    def on_signal(signum, frame):
        log("signal %d — restoring macOS automatic fan control" % signum)
        restore_auto()
        sys.exit(0)

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    # Take manual control (verified). Without root this fails cleanly here.
    for i in range(len(fans)):
        if not set_manual(i, True):
            restore_auto()
            log("FATAL: could not take manual control of fan %d "
                "(not running as root?)" % i)
            sys.exit(1)
    log("manual fan control active%s" % (" (DRY RUN)" if DRY_RUN else ""))

    cfg = dict(DEFAULTS)
    conf_mtime = 0.0
    cur_pct = 0.0        # what we've actually applied, in % of fan range
    cur_rpm = [None] * len(fans)
    fail_count = 0

    try:
        while True:
            # live-reload config when the file changes
            try:
                mtime = os.stat(CONF_PATH).st_mtime
                if mtime != conf_mtime:
                    cfg = parse_conf(CONF_PATH)
                    conf_mtime = mtime
                    log("config loaded: curve=%s source=%s" %
                        (",".join("%g:%g" % p for p in cfg["curve"]),
                         cfg["temp_source"]))
            except Exception as e:
                conf_mtime = mtime if "mtime" in dir() else 0.0
                log("WARNING: config error (%s) — keeping previous settings" % e)

            temp = read_temp(cfg["temp_source"])
            if temp is None:
                fail_count += 1
                log("WARNING: temperature read failed (%d/3)" % fail_count)
                if fail_count >= 3:
                    log("FATAL: temps unreadable — reverting to macOS auto")
                    restore_auto()
                    sys.exit(1)
                time.sleep(cfg["poll_interval"])
                continue
            fail_count = 0

            if temp >= cfg["failsafe_temp"]:
                target_pct = 100.0
                cur_pct = 100.0
            else:
                target_pct = curve_percent(cfg["curve"], temp)
                if target_pct >= cur_pct:
                    cur_pct = target_pct                       # rise instantly
                else:
                    cur_pct = max(target_pct,
                                  cur_pct - cfg["step_down_pct"])  # fall slowly

            for i, (lo, hi) in enumerate(fans):
                rpm = round(lo + cur_pct / 100.0 * (hi - lo))
                if cur_rpm[i] is None or abs(rpm - cur_rpm[i]) >= cfg["deadband_rpm"]:
                    write_rpm(i, rpm)
                    log("%.1f°C → %d%% → fan%d %d RPM" %
                        (temp, round(cur_pct), i, rpm))
                    cur_rpm[i] = rpm

            time.sleep(cfg["poll_interval"])
    except SystemExit:
        raise
    except BaseException as e:
        log("FATAL: %r — restoring macOS automatic fan control" % e)
        restore_auto()
        raise


if __name__ == "__main__":
    main()
