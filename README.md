# fan-curve

Custom fan curve for the 16" MacBook Pro (M1 Max), replacing macOS's
late-ramping default with an earlier, quieter-but-cooler curve.

## Install / remove

```sh
git clone --recurse-submodules https://github.com/ayushdeolasee/fan-curve.git
cd fan-curve
sudo ./install.sh      # installs a LaunchDaemon, starts at every boot
sudo ./uninstall.sh    # removes it, fans go back to macOS auto control
```

## Restart or reclaim fan control

```sh
fan-start             # asks for your sudo password once if needed
# Before reinstalling to add the command, use: ./start.sh
```

This stops the Macs Fan Control background helper and restarts fancurve,
then checks that both fans are under its control. Quit the Macs Fan Control
app first if it is open. The helper may return after a reboot or when you
reopen its app; run `fan-start` again, or uninstall Macs Fan Control if you
no longer use it. fancurve itself starts automatically at boot.

Re-run `sudo ./install.sh` to install `fan-start` on an existing setup.

## Tune it

Edit **`~/.config/fan-curve/fancurve.conf`** — the daemon picks up changes
live (within one poll cycle, default 5 s). No restart, no sudo. The installer
seeds it from the repo's `fancurve.conf` template on first install and never
overwrites your copy. The main knob is the curve:

```
curve = 55:0, 65:20, 75:40, 85:65, 95:100
```

`temp°C : fan%` points, linearly interpolated. 0% = fan minimum (~1500 RPM,
inaudible — same as macOS at idle), 100% = max (5348/5776 RPM, loud).
Loudness reference for this machine: ≤2200 RPM near-silent, ~3000 soft hum,
~3800 clearly audible, 4500+ loud.

Watch what it's doing:

```sh
fan-status                     # temps, RPM, mode (installed by install.sh; no sudo)
tail -f /var/log/fancurve.log  # daemon log (logs only on changes)
python3 fancurve.py --dry-run  # simulate the curve without touching fans
```

## How it works

- **SMC** (System Management Controller) is the chip that owns fans/sensors.
  It exposes 4-char keys: `F0Ac` (fan 0 actual RPM), `F0Tg` (target),
  `F0Mn`/`F0Mx` (min/max), `F0Md` (mode: 0 = macOS auto, 1 = manual).
  RPM values are little-endian floats; writes require root.
- `tools/smctemp/` reads CPU/GPU temps on Apple Silicon;
  `tools/smcFanControl/smc-command/` is the generic SMC read/write CLI.
  Both built from source; `install.sh` rebuilds them if missing.
- `fancurve.py` loops: read temp → interpolate curve → write `F{n}Tg`.
  Fans rise instantly but fall at most `step_down_pct` per cycle (no yo-yo),
  and changes under `deadband_rpm` are skipped (no constant micro-adjusting).
- **launchd** (macOS's service manager) runs it as root via
  `/Library/LaunchDaemons/com.ayush.fancurve.plist`; `KeepAlive` restarts it
  if it dies.

## Safety

- Any exit — signal, crash, unloading the daemon — restores macOS auto mode.
- 3 consecutive failed temperature reads → revert to auto and exit.
- At/above `failsafe_temp` (100 °C) both fans go straight to 100%.
- Even in the worst case, the SMC's own firmware protection still throttles
  and shuts down the machine before hardware damage.
