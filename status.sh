#!/bin/bash
# Quick fan/temperature status. No root needed (reads only).
DIR="$(cd "$(dirname "$0")" && pwd)"
SMC="$DIR/tools/smcFanControl/smc-command/smc"
SMCTEMP="$DIR/tools/smctemp/smctemp"

# smc prints e.g. "  F0Ac  [flt ]  1504 (bytes ...)" — the value is the field after "]".
val() { "$SMC" -k "$1" -r | sed -E 's/.*\] +([^ ]+).*/\1/'; }

cpu=$("$SMCTEMP" -c); gpu=$("$SMCTEMP" -g)
echo "CPU ${cpu}°C   GPU ${gpu}°C"
for i in 0 1; do
    mode=$(val F${i}Md)
    [[ "$mode" == "1" ]] && m="manual (fancurve)" || m="auto (macOS)"
    echo "fan$i: $(val F${i}Ac) RPM  (target $(val F${i}Tg), range $(val F${i}Mn)-$(val F${i}Mx))  mode: $m"
done
