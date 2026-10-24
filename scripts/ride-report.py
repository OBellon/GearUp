#!/usr/bin/env python3
"""Summarises one GearUp ride from the app log.

    python3 scripts/ride-report.py --from 12:05 --to 13:40
    python3 scripts/ride-report.py --from 12:05          # to the end of the log

Times are the wall clock the log prints. The log has no dates, so the report
picks the *latest* window that matches, which is what you want right after a
ride even when the file spans several days.

What it answers, in the order a ride asks it:

  * did the shifts reach MyWhoosh, and which gear did the ride end on;
  * how many shifts were dropped because nothing was connected;
  * how the puck's battery moved, in %/h, next to the puck's own forecast;
  * how often the link was reset or dropped, and when it slept;
  * whether the Mac buttons fired, and what went wrong.
"""

import argparse
import re
import sys
from statistics import median

LINE = re.compile(r"^\[(\d{2}):(\d{2}):(\d{2})\.(\d{3})\]\s+([A-Z]+)\s+(.*)$")


def parse_time(hh, mm, ss):
    return int(hh) * 3600 + int(mm) * 60 + int(ss)


def read_log(path):
    """Every line with a monotonic clock, so midnight does not confuse ranges."""
    rows = []
    day = 0
    previous = None
    with open(path, encoding="utf-8", errors="replace") as handle:
        for text in handle:
            match = LINE.match(text.rstrip("\n"))
            if not match:
                continue
            hh, mm, ss, _ms, level, message = match.groups()
            clock = parse_time(hh, mm, ss)
            if previous is not None and clock < previous - 3600:
                day += 1
            previous = clock
            rows.append(
                {
                    "clock": clock,
                    "at": f"{hh}:{mm}:{ss}",
                    "when": day * 86400 + clock,
                    "level": level,
                    "text": message,
                }
            )
    return rows


def parse_hhmm(value):
    parts = value.split(":")
    if len(parts) == 2:
        return parse_time(parts[0], parts[1], "0")
    if len(parts) == 3:
        return parse_time(*parts)
    raise argparse.ArgumentTypeError(f"expected HH:MM or HH:MM:SS, got {value!r}")


def pick_window(rows, start_clock, end_clock):
    """The latest `start` whose window reaches `end` (or the log's end).

    Times are matched by the minute, because a ride is quoted as "from 12:05"
    and the log rarely has a line at 12:05:00 exactly.
    """
    def minute(clock):
        return clock // 60

    starts = [i for i, row in enumerate(rows) if minute(row["clock"]) == minute(start_clock)]
    if end_clock is None:
        if not starts:
            starts = [i for i, row in enumerate(rows) if row["clock"] >= start_clock]
        return rows[starts[-1]:] if starts else []

    # The end is "up to this time", not "a line exactly on this minute": the app
    # may have logged its last line at 17:03:16 for a ride ending at 17:04.
    offset = (end_clock - start_clock) % 86400
    for index in reversed(starts):
        end_when = rows[index]["when"] + offset
        if offset <= 0 or end_when - rows[index]["when"] > 6 * 3600:
            continue
        end_index = index
        for position in range(index, len(rows)):
            if rows[position]["when"] > end_when:
                break
            end_index = position
        return rows[index : end_index + 1]
    return []


def hours(value):
    return f"{value:.1f}"


def duration(value):
    """A length of time with its unit: minutes under the hour, then hours."""
    return f"{value * 60:.0f} min" if value < 1 else f"{value:.1f} h"


def battery(rows):
    readings = []
    pattern = re.compile(r"battery (\d+)%.*?(?:about (\d+) h left|(\d+) min left)")
    for row in rows:
        match = pattern.search(row["text"])
        if match:
            level = int(match.group(1))
            minutes = None
            if match.group(2):
                minutes = int(match.group(2)) * 60
            elif match.group(3):
                minutes = int(match.group(3))
            readings.append((row, level, minutes))
    return readings


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--log", default="~/Library/Logs/GearUp/GearUp.log")
    parser.add_argument("--from", dest="start", type=parse_hhmm, required=True)
    parser.add_argument("--to", dest="end", type=parse_hhmm)
    args = parser.parse_args()

    import os

    path = os.path.expanduser(args.log)
    rows = read_log(path)
    if not rows:
        sys.exit(f"no log lines in {path}")

    window = pick_window(rows, args.start, args.end)
    if not window:
        sys.exit("no lines in that window; check the times against the log")

    first, last = window[0], window[-1]
    elapsed = (last["when"] - first["when"]) / 3600

    print(f"Ride report  {first['at']} → {last['at']}  ({duration(elapsed)}, {len(window)} lines)")
    print(f"Log: {path}\n")

    # ── Shifting ────────────────────────────────────────────────────────────
    shifts = []
    gear = re.compile(r"(Shift Up|Shift Down) → gear (\d+) of (\d+)")
    for row in window:
        match = gear.search(row["text"])
        if match:
            shifts.append((row, match.group(1), int(match.group(2)), int(match.group(3))))
    up = sum(1 for s in shifts if s[1] == "Shift Up")
    down = sum(1 for s in shifts if s[1] == "Shift Down")
    dropped = [row for row in window if "Nothing is connected to receive the shift" in row["text"]]

    print("Shifting")
    print(f"  {len(shifts)} shifts: {up} up, {down} down")
    if shifts:
        print(f"  gear range: {min(s[2] for s in shifts)}–{max(s[2] for s in shifts)} of {shifts[0][3]}")
        print(f"  ended on gear {shifts[-1][2]} (last shift at {shifts[-1][0]['at']})")
    print(f"  dropped (nothing connected): {len(dropped)}")
    if dropped:
        print("    first at " + dropped[0]["at"] + ", last at " + dropped[-1]["at"])
    print()

    # ── Battery ─────────────────────────────────────────────────────────────
    readings = battery(window)
    print("Battery")
    if not readings:
        print("  no readings in this window")
    else:
        print(f"  {len(readings)} readings, first at {readings[0][0]['at']}, last at {readings[-1][0]['at']}")
        level_first, level_last = readings[0][1], readings[-1][1]
        battery_hours = (readings[-1][0]["when"] - readings[0][0]["when"]) / 3600

        # Each distinct level change is a data point; the raw first/last span can
        # be dominated by a plateau, so quote the drop and the window it fell in.
        changes = []
        for previous, current in zip(readings, readings[1:]):
            if current[1] != previous[1]:
                changes.append((current[0], previous[1], current[1]))
        print(f"  level: {level_first}% → {level_last}% over {duration(battery_hours)}")
        if level_first != level_last and battery_hours > 0:
            print(f"  measured: {hours((level_first - level_last) / battery_hours)} %/h")
        else:
            print("  measured: no step yet (the puck reports whole percent; "
                  "a short ride often does not move it)")

        forecasts = [(row, level, minutes) for row, level, minutes in readings if minutes]
        if forecasts:
            first_forecast = forecasts[0]
            last_forecast = forecasts[-1]
            implied_first = first_forecast[1] / (first_forecast[2] / 60)
            implied_last = last_forecast[1] / (last_forecast[2] / 60)
            print(f"  puck's forecast: {first_forecast[2] / 60:.0f} h left at {first_forecast[0]['at']}"
                  f" ({implied_first:.1f} %/h), {last_forecast[2] / 60:.0f} h left at {last_forecast[0]['at']}"
                  f" ({implied_last:.1f} %/h)")

        gaps = [(b[0]["when"] - a[0]["when"]) for a, b in zip(readings, readings[1:])]
        if gaps:
            print(f"  sampling: median {median(gaps):.0f} s between readings")
        if level_last <= 20:
            print("  LOW: charge before the next long ride")
    print()

    # ── The link ────────────────────────────────────────────────────────────
    resets = [row for row in window if "the reset GearUp sent" in row["text"]]
    drops = [row for row in window if "the puck's own sleep" in row["text"]]
    connected = [row for row in window if row["text"].startswith("Click V2 connected")]
    sleeps = [row for row in window if row["text"].startswith("Letting the puck sleep")]
    holding = [row for row in window if row["text"].startswith("Holding the puck awake")]

    print("Puck link")
    print(f"  held: {len(holding)} times, {len(resets)} resets, {len(connected)} connects")
    if resets:
        gaps = [(b["when"] - a["when"]) for a, b in zip(resets, resets[1:])]
        if gaps:
            print(f"  reset spacing: median {median(gaps):.0f} s")
        print(f"  first reset {resets[0]['at']}, last {resets[-1]['at']}")
    print(f"  slept on its own: {len(drops)}, released: {len(sleeps)}")
    if drops:
        print(f"    sleep drops at: {', '.join(row['at'] for row in drops[:6])}")
    print()

    # ── Mac actions ─────────────────────────────────────────────────────────
    buttons = {}
    button = re.compile(r"Click V2: (\w+|[+]) pressed")
    for row in window:
        match = button.search(row["text"])
        if match:
            buttons[match.group(1)] = buttons.get(match.group(1), 0) + 1
    actions = {}
    action = re.compile(r"^(MyWhoosh ⇄ Away|MyWhoosh ⇄ Last App|Volume Up|Volume Down|Mute|Next Desktop|Previous Desktop):")
    for row in window:
        match = action.search(row["text"])
        if match:
            actions[match.group(1)] = actions.get(match.group(1), 0) + 1

    print("Mac buttons")
    if buttons:
        print("  presses: " + ", ".join(f"{name}×{count}" for name, count in sorted(buttons.items())))
    if actions:
        print("  fired:   " + ", ".join(f"{name}×{count}" for name, count in sorted(actions.items())))
    if not buttons and not actions:
        print("  none")
    print()

    # ── Trouble ─────────────────────────────────────────────────────────────
    trouble = [row for row in window if row["level"] in ("WARNING", "ERROR")]
    # The reset and sleep warnings are expected during a hold, so they are not
    # repeated here; everything else is.
    unexpected = [
        row for row in trouble
        if "the reset GearUp sent" not in row["text"] and "the puck's own sleep" not in row["text"]
    ]
    print("Warnings and errors")
    if not unexpected:
        print("  none beyond the expected reset and sleep notices")
    else:
        grouped = {}
        for row in unexpected:
            key = re.sub(r"\d+", "N", row["text"])[:90]
            grouped.setdefault(key, []).append(row)
        for key, items in sorted(grouped.items(), key=lambda item: -len(item[1])):
            print(f"  {len(items)}× {key}")
            print(f"     first {items[0]['at']}, last {items[-1]['at']}")
            print(f"     “{items[-1]['text']}”")


if __name__ == "__main__":
    main()
