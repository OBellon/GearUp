# GearUp

Native macOS bridge that lets a **Zwift Click V2** shift gears in **MyWhoosh** (or any
app that speaks **OpenBikeControl**).

GearUp reads the button presses from the Click V2 over Bluetooth Low Energy and
republishes them as standard OpenBikeControl shift commands, either over BLE or
over the local network (mDNS + TCP). MyWhoosh keeps full ownership of the trainer
resistance; GearUp never connects to the trainer, so the gear indicator in
MyWhoosh can never get out of sync.

```
 Zwift Click V2  ──BLE──▶  GearUp  ──OBC (BLE or mDNS/TCP)──▶  MyWhoosh  ──▶  Trainer
    (buttons)              (bridge)                                (owns resistance)
```

## Status

Phases 1 and 2 — the bridge works end to end and the settings screen is real.

| Phase | Content | State |
| --- | --- | --- |
| 0 | Repo, core codecs, `gearup-probe` diagnostic | ✅ protocol verified on hardware |
| 1 | App shell, Click V2 connection, OBC transport, shifting, gear readout | ✅ verified against MyWhoosh 5.7.0 |
| 2 | Settings: gear range and the button mapping editor | ✅ |
| 3 | Both pucks, icon and DMG | ⏳ planned |

Only the **right Click V2 puck** is supported at the start. The architecture keeps
the left puck possible later without rework.

## Requirements

- macOS 14 or newer, Apple Silicon or Intel.
- Swift toolchain 5.10+ (Command Line Tools are enough; Xcode is not required).
- A Zwift Click V2, and MyWhoosh with **Virtual Shifting** enabled.

## Repository layout

```
Sources/
  GearUpCore/        Shared logic, no UI and no external dependencies
    App/             GearUpController, settings, the event log
    BLE/             ClickCentral: scan, connect, handshake, notifications
    OpenBike/        OBC transports: Bluetooth peripheral, mDNS + TCP server
    Protocol/        OpenBikeCodec, ZwiftClickCodec, UUID tables
    Shifting/        Drivetrain model and the ShiftRouter
    Support/         Hex helpers
  GearUpApp/         SwiftUI app (assembled into GearUp.app)
  GearUpProbe/       Phase 0 diagnostic CLI
  GearUpChecks/      Unit checks (a tiny runner, since XCTest needs Xcode)
scripts/             App bundle assembly, Info.plist templates
```

Everything is built with SwiftPM. There are no third-party dependencies: only
SwiftUI, CoreBluetooth, Network and OSLog.

> **`@State` is unusable here.** GearUp builds with the Command Line Tools alone,
> and in the SDK those ship `@State` is a macro whose compiler plugin
> (`SwiftUIMacros`) only exists inside Xcode. View-local state therefore lives in
> a small `ObservableObject` (`ViewState` in `Components.swift`) instead of
> `@State`. Everything else — `@StateObject`, `@EnvironmentObject`, `@Published`,
> `@Environment` — is an ordinary property wrapper and works normally.

> **A binding handed to SwiftUI must not announce a write that changed nothing.**
> SwiftUI writes two-way bindings back with the value it just read; a menu bar
> extra does it on every scene update. If the setter announces anyway — which is
> what `@Published` does, changed or not — the announcement re-renders whatever
> owns the binding, which writes it again, and the update loop grows the stack
> until the app dies with a beachball. That is why `GearUpController.settings`
> and `ViewState.value` publish through `objectWillChange.send()` guarded by an
> equality check instead of `@Published`. `make smoke` launches the app and
> fails if the bridge does not come up, which is the only automated way to catch
> that class of loop.

## Build and test

```sh
swift build          # compile everything
swift run GearUpChecks   # run the unit checks
make build           # same as swift build
make test            # same as swift run GearUpChecks
make app             # assemble and ad-hoc sign .build/GearUp.app
make run             # build the app and open it
make smoke           # build, open every screen, and check the bridge came up
```

> XCTest and swift-testing both ship with Xcode, which GearUp does not require,
> so the checks live in a small dependency-free runner (`Sources/GearUpChecks`)
> and exit non-zero when something fails.

## Using the app

```sh
make run        # build, sign and open .build/GearUp.app
```

The window has three tabs: **Ride** (gear readout, the Click V2 card and the
MyWhoosh card), **Diagnostics** (the live event log) and **Settings**.

Settings holds the gear range, the button map and the transport switch. For the
button map you can pick a button from the list or press **Press…** and then the
button on the puck itself — the app waits for a press and assigns it. Giving an
action a button that already does the other one swaps the two, so the map is
never left with both actions on one button. Nothing shifts while the app is
waiting for that press.

Everything is logged twice: to the Diagnostics tab and to

```
~/Library/Logs/GearUp/GearUp.log
```

which is the file to look at (or attach) when something does not work.

1. Launch GearUp and **approve both permission prompts** — Bluetooth, and Local
   Network when the network transport starts. The app is ad-hoc signed, so a
   rebuild is a new identity and macOS asks again. Setting
   `GEARUP_SIGN_IDENTITY` to a stable identity avoids that.
2. Press a button on the **right** puck to wake it. GearUp connects on sight and
   the Ride tab shows the gear changing as you press `+` and `B`.
   The pair of buttons in the window sends the same shifts without the puck, so
   the MyWhoosh connection can be checked on its own.
3. In MyWhoosh, enable **Virtual Shifting**, open **Device Connection** and pick
   the OpenBikeControl device. The MyWhoosh card switches to *Connected* and
   names the app it heard from.

Only the **right Click V2 puck** is driven in this phase; the left one needs a
Zwift unlock before it reports anything useful.

## Phase 0: mapping your Click V2

`gearup-probe` scans for a Zwift controller, connects, performs the `RideOn`
handshake and prints every notification as raw bytes plus a decoded
interpretation. The transcript is also written to a log file, which
`make probe` follows for you.

```sh
make probe
make probe ARGS="--all"                        # list every nearby device
make probe ARGS="--seconds 20 --duration 90"   # longer scan, stop by itself
```

Options:

| Flag | Meaning |
| --- | --- |
| `--seconds <n>` | How long to scan before connecting (default 10) |
| `--duration <n>` | Stop n seconds after the handshake (default: run until Ctrl-C) |
| `--connect <uuid>` | Connect to a specific peripheral identifier |
| `--all` | List every Bluetooth device, not only Zwift ones |
| `--keepalive <n>` | Hold the puck awake, resetting it after n seconds of quiet |
| `--reset-procedure <n>` | Reset with that procedure number instead of the bare reboot |
| `--no-handshake` | Wait for notifications without sending the start command |
| `--log <path>` | Write the transcript to this exact file |
| `--log-dir <path>` | Directory for `probe-<timestamp>.log` (default `~/Library/Logs/GearUp`) |
| `-h`, `--help` | Show the help |

> **Always run the probe through `make probe`.** macOS attributes Bluetooth
> access to the process that *launched* the binary, and that process needs an
> `NSBluetoothAlwaysUsageDescription`. `make probe` builds a real
> `.build/GearUpProbe.app` and opens it through LaunchServices, so the probe
> owns its own permission. Executing `.build/release/GearUpProbe` directly from
> a shell can make macOS abort it with
> *"attempted to access privacy-sensitive data without a usage description"*.

### Before you run it

1. Make sure the puck is **not** connected to Zwift, the Zwift Companion app or
   anything else. A connected puck stops advertising and will not be found.
2. Press a button on the puck so it wakes up.
3. Run the probe and, once the handshake line appears, press the buttons **one at
   a time, about a second apart**, in this order: `Y`, `Z`, `A`, `B`, `+`.
4. Press `Ctrl-C` and share the log file.

The interesting lines look like this:

```
← 00000002  23 08 FF FF FF FF 0F 12 18 ...
   type=0x23 CONTROLLER_NOTIFICATION
   buttonMap=0x0FFFFFFF pressedBits=[] pressed=[none]
```

Note the inverted logic: a `0` bit means **pressed**, a `1` bit means **released**.
An idle controller reports `0x0FFFFFFF`.

### If the probe cannot find the puck

- The first run may show a system prompt asking to allow Bluetooth. Approve it;
  until then the probe sits at *"Waiting for Bluetooth to become available…"*
  and finds nothing.
- The custom Zwift service is hidden while the puck is **locked**. The right Click
  V2 does not need a daily Zwift unlock, but if it has never been paired it may
  help to connect it once in Zwift and then retry.
- Check `System Settings → Privacy & Security → Bluetooth` and allow the probe.
  Ad-hoc signing gives every rebuild a new identity, so macOS may ask again; a
  stable identity avoids this:
  `GEARUP_SIGN_IDENTITY="Apple Development: …" make app`.
- Run with `--all` to confirm the puck is visible at all, then connect by UUID.

## Setting up MyWhoosh

1. Open MyWhoosh and enable **Virtual Shifting** in its settings.
2. Go to **Device Connection** and tap the **OpenBikeControl** icon in the top
   right corner.
3. Accept the pairing popup. MyWhoosh then drives shifting through GearUp.
4. **There is nothing else to connect for the gear.** MyWhoosh's own virtual
   shifting (MyShift) owns the gear *and* the trainer: it has 30 gears, starts
   every ride in gear 15, and shows the current one at the **bottom right of the
   ride HUD**. GearUp's readout defaults to the same 30 gears starting at 15 so
   the two numbers agree, and `Reset gear` returns it to 15.
5. Start a ride — MyWhoosh needs a trainer (or Speed Sensor Mode with a speed
   sensor) to let you in, so without one there is no HUD to show a gear in and
   nothing for a shift to change. The resistance comes from the trainer, which
   MyWhoosh controls; GearUp never touches it.

GearUp advertises the OpenBikeControl service `d273f680-d548-419d-b9d1-fa0472345229`
over BLE and over mDNS (`_openbikecontrol._tcp`) plus TCP.

## Protocol notes

OpenBikeControl messages:

| Message | Bytes |
| --- | --- |
| Button state | `0x01`, then `buttonID`, `state` pairs (`0x01` pressed, `0x00` released) |
| Device status | `0x02`, `battery`, `connected` |
| Haptic | `0x03`, `pattern`, `duration`, `intensity` |
| App info (app → controller) | `0x04`, `version`, `appIDLen`, `appID`, `appVerLen`, `appVer`, `buttonCount`, `buttonIDs` |

Shift buttons: `0x01` = Shift Up, `0x02` = Shift Down.

The protocol carries **button presses only**: there is no message for
resistance, power, gear ratios or the trainer itself. That is why GearUp never
connects to a trainer — it is a controller, and MyWhoosh keeps ownership of both
the trainer and the gear. MyWhoosh also sends a lone `0x00` byte every few
seconds as a keep-alive; that is not a protocol message, and GearUp notes the
first one per connection and then ignores it.

Zwift Click V2 (for the probe): service `FC82`/`00000001-19CA-4651-86E5-FA29DCDD09D1`,
handshake `RideOn` + `[0x02, 0x03]`, keypad reports as protobuf `RideKeyPadStatus`
under message type `0x23` (older firmware uses `0x37` with `ClickKeyPadStatus`).
The device acknowledges the handshake by echoing `RideOn` back on the
indicate characteristic.

### The puck sleeps after a minute

A Click V2 drops the BLE link **60 seconds after the last press** and then
powers down; that is its own way of protecting a coin cell. On real hardware the
drop landed 61, 61, 61 and 62 seconds after the last button, and 61 seconds
after connecting when nothing had been pressed at all.

It explains two things that look like faults. The puck's LED sits there blinking
blue, which is the state a sleeping puck wakes up in — Zwift's own documentation
reads *flashing blue* as "ready to pair", *solid blue* as connected, and the LED
off while riding to save battery. And a rider who has not shifted for a minute
finds that the next press is the one that has to wake the controller. QZ, another
bridge, documents the same wall and its workaround is to pair the pucks in the
official Zwift app for about three minutes before handing them over, which is
the "opening Zwift first" that riders notice.

**A reset is what puts the window back — and a reset is a reboot.** BikeControl's
own stub for its Click logic says it *"drives the periodic RESET recovery"*, and a
command frame on this protocol is just `[opcode, ...payload]` — no header — so
RESET is opcode 24 and the whole command is one byte, `0x18`, on the same
characteristic as the handshake. GearUp measured what that does: written at
12:54:20.154, the puck was gone by .274 (*"The specified device has disconnected
from us."*) and back when the retry asked for it. So a reset opens a fresh
60-second window at the cost of a reboot, and the start command plus the reconnect
put the session back.

That is why GearUp spends it **only when it has to**, never on a clock of its own.
The window belongs to the puck and a **press** opens a fresh one, so a rider who is
shifting never needs a reset at all: while the puck is in use GearUp writes
*nothing*. Only after 40 seconds of quiet — the spell that otherwise ends with the
puck asleep and needing a press to come back — does the hold reset it, which costs
about a second of link and starts the window again.

Two writes were tried first and measured to do no good on their own. The bare
`RideOn` header is answered — the puck echoes it — but does nothing about the
sleep: one every 20 seconds, and the link still died 61 seconds after the last
press. The documented Info-Request `00 08 00` every 5 seconds did not help either.
It is still worth spending once per connection, because what comes back is a
`DevInfoPage`: the unit tested names itself `Zwift Click`, hardware `B.0`, firmware
`1.2.0` — the release Zwift calls current — serial `0A-D4060F930E95` and protocol
515. That is where the log's device info line comes from.

Nothing in the published protocol switches the sleep off: the opcodes cover
firmware, battery, the trainer and powering *off*, and the data objects the device
info, the date and time, input config and the like. So GearUp does what BikeControl
does — reboot the puck to open a fresh window — but only when the window is
actually about to run out, which is why both bridges have to live with the sleep
and only GearUp gets to stay quiet through a ride.

GearUp holds the puck while, and only while, there is something to shift for: a
client is connected, or the settings screen is waiting for a button. Holding it
costs battery, and holding it for nothing spends a coin cell on a controller
nobody is using, so the rest of the time the puck is left alone to power down on
its own minute. While it is held, GearUp also retries a dropped link by handle —
CoreBluetooth introduces a peripheral once, so a rescan cannot turn up a puck it
has already seen.

### Confirmed Click V2 button map

Verified against real hardware by pressing each button on the right puck and
reading the resulting `buttonMap`. A `0` bit means pressed; an idle right puck
reports `0xFFFFFFFF`.

| Button | Mask | Bit |
| --- | --- | --- |
| Y (top) | `0x0040` | 6 |
| Z (left) | `0x0080` | 7 |
| A (right) | `0x0010` | 4 |
| B (bottom) | `0x0020` | 5 |
| `+` (shift up right) | `0x1000` | 12 |

Zwift's published `RideButtonMask` protobuf enum is **not** the wire mask: it
skips `0x80`, so a naive reading of it puts `Z` at `0x100`. The hardware assigns
bits in enum order, which is why `Z` is `0x80` and `+` is `0x1000`.

The puck repeats the same report several times per press and then repeats the
released state for about a second, so consumers must act on the *transition*
into "pressed" rather than on every report.

## License

MIT. See [LICENSE](LICENSE).
