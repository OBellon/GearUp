#!/usr/bin/env bash
#
# Builds the app, opens it, and checks that it actually came up: the bridge has
# to reach "Listening on port …" within a few seconds of launching.
#
# This exists because the interesting failures in this app are not unit-testable.
# A SwiftUI update loop (a two-way binding whose setter announces writes that
# changed nothing, say) does not throw and does not fail to build: the app opens,
# spins at 100 % of a core, and dies of a stack overflow a second or two later,
# before `.task { controller.start() }` ever gets to run. Nothing but launching
# the real app notices that.
#
# Needs a logged-in GUI session, and asks for the Bluetooth and Local Network
# permissions the first time.
#
#   ./scripts/smoke.sh [seconds]

set -uo pipefail
cd "$(dirname "$0")/.."

TIMEOUT="${1:-25}"
LOG="$HOME/Library/Logs/GearUp/GearUp.log"

./scripts/build-app.sh || exit 1

# The process may be left over from an earlier run; start from a clean slate.
pkill -x GearUp 2>/dev/null && sleep 1

lines_before=0
[ -f "$LOG" ] && lines_before=$(wc -l < "$LOG")

open .build/GearUp.app

deadline=$((SECONDS + TIMEOUT))
heard=""
while [ $SECONDS -lt $deadline ]; do
    if ! pgrep -x GearUp >/dev/null; then
        echo "smoke: FAIL — the app exited while starting up."
        break
    fi
    if [ -f "$LOG" ] && tail -n +$((lines_before + 1)) "$LOG" | grep -q "Listening on port"; then
        heard="yes"
        break
    fi
    sleep 1
done

echo "----- startup log -----"
[ -f "$LOG" ] && tail -n +$((lines_before + 1)) "$LOG"

pkill -x GearUp 2>/dev/null

if [ -n "$heard" ]; then
    echo "smoke: OK — the bridge came up and is listening."
    exit 0
fi

echo "smoke: FAIL — no \"Listening on port\" within ${TIMEOUT}s."
echo "If the log above stops early, look for a SwiftUI update loop before assuming the radio is at fault."
exit 1
