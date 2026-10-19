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
make signing         # create GearUp's local signing identity (once per Mac)
make app             # assemble and sign .build/GearUp.app
make run             # build the app and open it
make smoke           # build, open every screen, and check the bridge came up
```

> XCTest and swift-testing both ship with Xcode, which GearUp does not require,
> so the checks live in a small dependency-free runner (`Sources/GearUpChecks`)
> and exit non-zero when something fails.

### Signing

macOS ties the Bluetooth and local-network permissions to the *signature* of the
app, which makes an ad-hoc signature a nuisance: its hash changes with every
build, a different hash is a different app, and the permission is asked for
again after every rebuild. `make signing` puts that right once per Mac — it
creates a self-signed certificate (`GearUp Dev`) in the login keychain and trusts
it for code signing — and from then on both bundles are signed with it, because
`scripts/sign-identity.sh` picks it up automatically. Nothing else is signed with
it, and only `codesign` and `security` are allowed to use the private key.

What makes the permission stick is the *designated requirement* rather than the
hash: two builds of the same bundle sign to
`identifier "com.oscar.gearup" and certificate root = H"9c2899…"` — the same
requirement with two different hashes, which is exactly what macOS matches on.

`GEARUP_SIGN_IDENTITY` overrides all of it (a real Apple Development certificate,
say). With neither, the build falls back to ad-hoc signing: it works, and will ask
for permissions again after each rebuild.

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
   Network when the network transport starts. They are asked for once and then
   kept, because the bundles are signed with GearUp's own identity (see
   *Signing* above). If the identity is not set up, every rebuild is a new app to
   macOS and the prompts come back.
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
| `--release <n>` | Stop holding after n seconds without a press and let the puck sleep (default: 180, the app's own threshold) |
| `--no-reset` | Hold the retry but never reset, so the puck sleeps on its own minute — the run that asks whether the press which wakes it also arrives as a shift |
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
2. **Press a button on the puck again and again while the scan window runs.** A
   sleeping puck advertises nothing, so a single press before launching can be
   spent before the radio is even up: keep pressing until the transcript says
   *"Connected to …"*. (The window is counted from the moment Bluetooth comes up,
   not from the launch, so it is all listening time.)
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
  `make signing` does the same for the diagnostic bundle: with a stable identity
  the permission survives rebuilds instead of being asked for each time.
- A sleeping puck advertises nothing, so a press made before launching can be
  spent before the radio is even up. **Keep pressing a button while the window
  runs**, until the transcript says *"Connected to …"*: the window is counted
  from the moment Bluetooth comes up, so it is all listening time.
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

**That blinking blue while GearUp is using the puck is the puck's own state
machine, not a fault.** Its `BleSecurityPage` reports a `secureConnectionStatus`
and a window in which pairing is allowed, and the `02 03` it answers the `RideOn`
handshake with is opcode 2, `BLE_SECURITY_REQUEST` — the controller wants a *paired*
connection before it counts itself in-session, and the LED is what shows the
difference. Nothing in the published protocol touches the LED (the reference's only
LED code draws a picture for a different device), and macOS CoreBluetooth has no API
to start that pairing, so a third-party bridge leaves the puck showing "ready to
pair" for as long as it is connected. GearUp asks for that state on every connection
(the data object 64, one of the ids the protocol lists), so the log says which it
is — `secure connection none, pairing window closed` is the flashing LED, and
`active` would mean the puck counts the link as paired. The LED goes out when the
puck sleeps, which GearUp lets it do whenever there is nothing to shift for.

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
puck asleep and needing a press to come back — does the hold reset it, which starts
a fresh window at the cost of a reboot. Measured on the unit here, a quiet cycle
runs: reset, the link gone 0.12 s later, the puck advertising again, and the
session up 2.3 s after the drop. The disconnect line names it — *"the reset GearUp
sent"* — so a drop in the log can be told from the puck's own sleep at a glance.
The sleep has a name of its own too: *"the puck's own sleep: it drops the link about
a minute after the last press"*. Both used to arrive as *"the connection has timed
out unexpectedly"*, which read like a fault and was in fact the mechanism working
exactly as designed — the error is the same, and only the clock tells them apart.

**And only while there is something to shift for.** A descent, a steady stretch,
an interval effort: minutes can pass without a gear change, and a rider who is not
shifting has no shift for a reset to save — that reboot would be spent protecting a
press that is not coming. So the hold has a second threshold. After **three
minutes** without a press it stands down, writes nothing further, and lets the puck
power down on its own minute. The retry stays on, which is what makes that safe:
the wake-up is caught, the session comes back, and the price is the one measured
below — the press that wakes the puck is lost, the press after it shifts. Three
minutes is long enough that no spell a rider would call "a pause between efforts"
reaches it, and short enough that a parked bike stops being rebooted every forty
seconds. The log says when it happens: *quiet for 182 s, so leaving the puck to
sleep: it powers down about a minute after its last reset or press.*

Standing down is not the same as switching the puck off, and the difference is what
makes a probe run look as if the sleep had been skipped. The window the *last reset*
opened keeps running, so a press within the next minute still lands — it was GearUp's
reboot, not the press, that bought that grace. And any press that does land puts the
hold straight back on its feet, because a press means the rider is there: the log
says so, *a press after the quiet: holding the puck's window again*, and the resets
resume. The one press that is genuinely lost is the one made after the puck has
actually powered down, which needs a full minute of no presses *and* no resets — the
state a ten-minute descent reaches and a probe run that presses every few seconds
never does.

Two writes were tried first and measured to do no good on their own. The bare
`RideOn` header is answered — the puck echoes it — but does nothing about the
sleep: one every 20 seconds, and the link still died 61 seconds after the last
press. The documented Info-Request `00 08 00` every 5 seconds did not help either.

**The transcript says why.** The puck is quiet, not chatty: it answers a press
with a short burst of reports — about ten inside the first second — and then sends
nothing at all until the next press, so a whole minute of the log holds nine
reports and no more. The window ends 61 seconds after the *press*, not after the
last byte, so a window that counts presses cannot be stretched by anything the
host writes. That is what the two attempts above were trying to do.
It is still worth spending once per connection, because what comes back is a
`DevInfoPage`: the unit tested names itself `Zwift Click`, hardware `B.0`, firmware
`1.2.0` — the release Zwift calls current — serial `0A-D4060F930E95` and protocol
515. That is where the log's device info line comes from. The battery is asked for
at the same time (object 771), and it is the only way to know it: the controller has
never sent a battery notification, in any log GearUp has. What it answers with —
level, charging state, minutes left — is what the app shows beside the puck's name.

**Which part of that answer is a measurement, and which is a forecast, matters.**
The percentage is the measurement. The "time to empty" is recomputed from the drain
of the moment, and it moves in steps rather than counting down: on the bench here it
read 2863, then 2797 twice, then 2773 twice, across four minutes of continuous
connection, while the level never left 90% once. Read as a countdown, those numbers
would mean the puck was flat within two hours of that reading — and it went on
answering. Two hours later, after a morning of resets, the same field read **2844**:
seventy-one minutes *higher* than the last of them, with the level still at 90%.
A countdown cannot rise. A forecast of the moment's drain can, and does. So the log now quotes anything above an hour in whole hours, where 2773
is "about 46 h" and does not read like a stopwatch. Zwift's own figure for the same
puck is **over 100 hours** on a CR2032, so an hour's ride is worth about a percent,
and the expensive case is a stress test that reconnects it every minute for an
afternoon, not riding.

To make the drain a measurement rather than an argument, a held puck is asked about
its battery every five minutes (`ClickCentral.batteryInterval`), so a ride leaves a
series of percentages in the log instead of one reading at the start. That series is
what to compare, and a `Get` does not lengthen the puck's own window, so it costs
the four bytes it is.

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

What the hold adds to a Zwift session is the reset, not the link: the radio is up
in both. A press opens the puck's window by itself, so a rider who is shifting is
never reset — the watch only ever reboots a puck that has been quiet for 40
seconds — and the resets in the log are therefore the price of quiet spells, not
of a ride.

**The reboot is the only mechanism anyone has found.** The published protocol has
no data object for sleeping, idling, waking or a timeout (the full list is device
info, client/server configuration, update info, date and time, BLE security,
trainer, gear index, tilt, battery, input, Wi-Fi and sensor relay), so there is no
window to configure and no keep-awake message to send — `RideOn` and the
Info-Request were both measured to do nothing. BikeControl, the reference for this
protocol, says the same in its own words: its Click logic *"drives the periodic
RESET recovery"*, and its keep-awake state machine needs a left puck in range
before it will call itself `active`. So the reboot is not laziness; three
independent bridges do it because it is what works.

That assumption has since been put to the hardware, and it holds.
`make probe ARGS="--no-reset"` finds the puck by mashing its buttons, holds it
without ever resetting it, and waits. On 19 October the link went at 15:15:49,
60.8 seconds after the last press, and the pending connect completed the moment
the puck advertised again — 15:16:19.209, half a minute later, which is itself
proof that a sleeping puck comes back to a held retry. Then the puck said
**nothing**: no report when it woke, and the next press (15:16:22.567) arrived
exactly as a press does on an awake link, with the pipe plainly working. The
press that woke it was not reported. The same run's first connection shows the
same thing from the other side, where the mashing that woke the puck produced no
button reports at all before the link dropped.

So the shift that has to wake a sleeping controller is the one the sleep costs,
and the reset buys exactly that back. The price of the hold is one reboot per
**quiet spell**, not per ride — and once a spell has run three minutes the hold
stands down altogether, as described above, because by then the rider is plainly not
shifting and the press the sleep would swallow is one nobody is making. The wake-up
costs that single press and nothing else.

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
