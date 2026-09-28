#!/bin/bash
# Records the README demo: opens IP config against the mock backend on an
# empty workspace and drives it with wtype. Takes over the keyboard for ~40s.
#
#   demo/record.sh [output.mp4]
#
# Needs gpu-screen-recorder and wtype. Convert with demo/make-gif.sh.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/demo.mp4}
monitor=$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .name')
return_ws=$(hyprctl activeworkspace -j | jq -r '.id')
export IP_CONFIG_DEMO_STATE=${XDG_RUNTIME_DIR:-/tmp}/ip-config-demo.tsv

pause() { sleep "$1"; }
focus_workspace() { hyprctl dispatch "hl.dsp.focus({ workspace = \"$1\" })" >/dev/null; }
key() { wtype -k "$1"; pause "${2:-0.7}"; }
type_slowly() { wtype -d 70 "$1"; pause 0.6; }

cleanup() {
  omarchy-shell shell hide ip-config >/dev/null 2>&1 || true
  [[ -n ${recorder:-} ]] && kill -INT "$recorder" 2>/dev/null && wait "$recorder" 2>/dev/null
  focus_workspace "$return_ws"
  rm -f "$IP_CONFIG_DEMO_STATE"
}
trap cleanup EXIT

rm -f "$IP_CONFIG_DEMO_STATE"
focus_workspace empty
pause 0.5

gpu-screen-recorder -w "$monitor" -f 30 -cursor no -o "$out" >/dev/null 2>&1 &
recorder=$!
pause 1.5

omarchy-shell shell summon ip-config "{\"backend\": \"$here/mock-backend\"}" >/dev/null
pause 1.8

# Wired: set a static IP.
key Down 1
key Right 0.9
type_slowly "10.0.0.50/24 10.0.0.1 1.1.1.1"
key Return 2.6

# Back to DHCP (each DHCP step plays out), then Static again: the old
# address is prefilled.
key Left 6.5
key Right 2.0
key Escape 1.2

# Wi-Fi: turn it off and on again.
key Up 0.8
key Return 1.6
key Return 2.4

key Escape 0.8
