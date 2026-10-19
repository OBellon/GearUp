#!/usr/bin/env bash
#
# Builds the app and opens each screen in turn, checking that every one of them
# comes up: the bridge has to reach "Listening on port …" within a few seconds.
#
# This exists because the interesting failures in this app are not unit-testable.
# A SwiftUI update loop (a two-way binding whose setter announces writes that
# changed nothing, say) does not throw and does not fail to build: the app opens,
# spins at 100 % of a core, and dies of a stack overflow a second or two later,
# before `.task { controller.start() }` ever gets to run. Nothing but launching
# the real app notices that, and the settings screen is where the bindings are,
# so it is launched too rather than assumed.
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

failures=0

for section in ride settings diagnostics; do
    # The process may be left over from an earlier run, and `open` ignores
    # --args when the app is already running: start from a clean slate.
    pkill -x GearUp 2>/dev/null && sleep 1

    lines_before=0
    [ -f "$LOG" ] && lines_before=$(wc -l < "$LOG")

    open .build/GearUp.app --args --section "$section"

    deadline=$((SECONDS + TIMEOUT))
    heard=""
    while [ $SECONDS -lt $deadline ]; do
        if ! pgrep -x GearUp >/dev/null; then
            echo "smoke: FAIL — the app exited while opening the $section screen."
            failures=$((failures + 1))
            break
        fi
        if [ -f "$LOG" ] && tail -n +$((lines_before + 1)) "$LOG" | grep -q "Listening on port"; then
            heard="yes"
            echo "smoke: OK — the bridge came up with the $section screen open."
            break
        fi
        sleep 1
    done

    if [ -z "$heard" ]; then
        echo "----- $section startup log -----"
        [ -f "$LOG" ] && tail -n +$((lines_before + 1)) "$LOG"
        echo "smoke: FAIL — no \"Listening on port\" within ${TIMEOUT}s on the $section screen."
        echo "If the log above stops early, look for a SwiftUI update loop before assuming the radio is at fault."
        failures=$((failures + 1))
    fi
done

pkill -x GearUp 2>/dev/null

if [ "$failures" -eq 0 ]; then
    echo "smoke: OK — every screen came up and the bridge is listening."
    exit 0
fi

echo "smoke: FAIL — $failures screen(s) did not come up."
exit 1
