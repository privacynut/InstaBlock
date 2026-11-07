#!/bin/bash
#
# Capture all iPhone network traffic over USB (rvictl) and summarize how
# Instagram reaches its CDN: DNS queries/answers, TLS/QUIC SNI, and whether
# the IPs carrying the video bytes were obtained via DNS in this capture.
#
# Usage:  tools/capture-instagram.sh [seconds] [output.pcapng]
#         default 30 seconds, output in ~/Desktop
#
# The phone must be plugged in via USB and on Wi-Fi/cellular (NOT airplane
# mode — rvictl mirrors the radios' traffic, it doesn't route through USB).
# Captures with Wireshark's tshark (no sudo needed with ChmodBPF installed;
# it also handles the rvi PKTAP link type cleanly, unlike Apple's tcpdump).
#
set -euo pipefail

DURATION="${1:-30}"
OUT="${2:-$HOME/Desktop/instagram-$(date +%Y%m%d-%H%M%S).pcapng}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TSHARK="$(command -v tshark || echo /Applications/Wireshark.app/Contents/MacOS/tshark)"

# --- find the iPhone (modern UDID: 8 hex, dash, 16 hex) -------------------
# xctrace may list a USB-connected phone under "Devices Offline" (that
# reflects Xcode's debug link, not the USB connection rvictl needs), so
# search both sections. Override with UDID=... if you have several phones.
UDID="${UDID:-$(xcrun xctrace list devices 2>/dev/null \
  | sed -n '/== Devices ==/,/== Simulators ==/p' \
  | grep -oE '\(([0-9A-F]{8}-[0-9A-F]{16})\)' | tr -d '()' | head -1 || true)}"

if [[ -z "$UDID" ]]; then
  echo "No iPhone found. Plug it in via USB, unlock it, and tap Trust if asked." >&2
  echo "Or run: UDID=<your-udid> $0 $*" >&2
  xcrun xctrace list devices 2>/dev/null | sed -n '/== Devices/,/== Simulators/p' >&2
  exit 1
fi
echo "iPhone UDID: $UDID"

# --- bring up the remote virtual interface --------------------------------
cleanup() {
  echo
  echo "Tearing down rvi for ${UDID}..."
  rvictl -x "$UDID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# `rvictl -l` reports the interface as (null) on recent macOS, so take the
# name from the start command's own output, falling back to ifconfig.
START_OUT="$(rvictl -s "$UDID" 2>&1 || true)"
RVI="$(echo "$START_OUT" | grep -oE 'rvi[0-9]+' | head -1 || true)"
[[ -z "$RVI" ]] && RVI="$(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep -E '^rvi[0-9]+$' | head -1 || true)"
if [[ -z "$RVI" ]]; then
  echo "rvictl did not create an interface (it prints nothing when the phone isn't reachable over USB)." >&2
  echo "Make sure the phone is plugged in via USB, UNLOCKED, and trusted; then re-run." >&2
  [[ -n "$START_OUT" ]] && echo "rvictl said: $START_OUT" >&2
  exit 1
fi
echo "Capturing on $RVI for ${DURATION}s → $OUT"
echo
echo "  >>> NOW: open Instagram on the phone and scroll Reels / play videos. <<<"
echo

# --- capture --------------------------------------------------------------
if [[ ! -x "$TSHARK" ]]; then
  echo "tshark not found — install Wireshark (https://www.wireshark.org) first." >&2
  exit 1
fi
"$TSHARK" -i "$RVI" -a "duration:$DURATION" -w "$OUT" -q 2>&1 | grep -v "^Capturing on" || true

echo "Capture finished: $OUT ($(du -h "$OUT" | cut -f1))"
echo

# --- summarize --------------------------------------------------------------
python3 "$SCRIPT_DIR/summarize-capture.py" "$OUT" --tshark "$TSHARK"
