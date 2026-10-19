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

Phase 0 — protocol verification.

| Phase | Content | State |
| --- | --- | --- |
| 0 | Repo, core codecs, `gearup-probe` diagnostic | 🚧 in progress |
| 1 | App shell, Click V2 connection, OBC transport, shifting | ⏳ planned |
| 2 | Settings: gear range, button mapping | ⏳ planned |
| 3 | Both pucks, menu bar, icon and DMG | ⏳ planned |

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
    BLE/             ClickCentral: scan, connect, handshake, notifications
    Protocol/        OpenBikeCodec, ZwiftClickCodec, UUID tables
    Shifting/        Drivetrain model
    Support/         Hex helpers
  GearUpApp/         SwiftUI app (assembled into GearUp.app)
  GearUpProbe/       Phase 0 diagnostic CLI
  GearUpChecks/      Unit checks (a tiny runner, since XCTest needs Xcode)
scripts/             App bundle assembly, Info.plist templates
```

Everything is built with SwiftPM. There are no third-party dependencies: only
SwiftUI, CoreBluetooth, Network and OSLog.

## Build and test

```sh
swift build          # compile everything
swift run GearUpChecks   # run the unit checks
make build           # same as swift build
make test            # same as swift run GearUpChecks
make app             # assemble and ad-hoc sign .build/GearUp.app
make run             # build the app and open it
```

> XCTest and swift-testing both ship with Xcode, which GearUp does not require,
> so the checks live in a small dependency-free runner (`Sources/GearUpChecks`)
> and exit non-zero when something fails.

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
| `--keepalive <n>` | Re-send `RideOn` every n seconds |
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

Zwift Click V2 (for the probe): service `FC82`/`00000001-19CA-4651-86E5-FA29DCDD09D1`,
handshake `RideOn` + `[0x02, 0x03]`, keypad reports as protobuf `RideKeyPadStatus`
under message type `0x23` (older firmware uses `0x37` with `ClickKeyPadStatus`).

## License

MIT. See [LICENSE](LICENSE).
