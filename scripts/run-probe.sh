#!/usr/bin/env bash
#
# Builds GearUpProbe.app, launches it through LaunchServices and follows the
# transcript.
#
# Why LaunchServices: a Terminal-launched process inherits the terminal as its
# "responsible process", and macOS then looks for the Bluetooth usage
# description in the terminal rather than in the probe. Launching with `open`
# makes the probe responsible for itself, so the permission is attributed
# correctly.
#
# Usage:
#   scripts/run-probe.sh
#   scripts/run-probe.sh --all
#   scripts/run-probe.sh --seconds 20 --duration 90
#
# The probe writes to a log file and to nothing else, so this script follows
# the log for you. Press Ctrl-C to stop.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_PATH=".build/GearUpProbe.app"
LOG_PATH="${GEARUP_PROBE_LOG:-${TMPDIR:-/tmp}/gearup-probe.log}"

./scripts/build-probe.sh

rm -f "$LOG_PATH"

echo "==> Launching probe"
echo "    Transcript: $LOG_PATH"
echo "    Press Ctrl-C to stop."
echo ""

open "$APP_PATH" --args --log "$LOG_PATH" "$@"

# Wait for the probe to create its transcript before following it.
for _ in $(seq 1 100); do
  [[ -f "$LOG_PATH" ]] && break
  sleep 0.1
done

if [[ ! -f "$LOG_PATH" ]]; then
  echo "error: the probe never wrote $LOG_PATH" >&2
  echo "       check that $APP_PATH is allowed to use Bluetooth in" >&2
  echo "       System Settings → Privacy & Security → Bluetooth" >&2
  exit 1
fi

cleanup() {
  pkill -f "GearUpProbe.app/Contents/MacOS/GearUpProbe" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

tail -f "$LOG_PATH"
