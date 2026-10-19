import Foundation
import GearUpCore

// GearUp Probe — Phase 0 diagnostic tool.
//
// It scans for a Zwift Click V2, connects to it, performs the RideOn handshake
// and dumps every notification as raw bytes plus a decoded interpretation.
// The transcript is written to ~/Library/Logs/GearUp/ so it can be shared.

private struct ProbeOptions {
    var scanSeconds: Double = 10
    /// Stops automatically this many seconds after the handshake. Zero means
    /// "run until Ctrl-C".
    var runSeconds: Double = 0
    var connectID: UUID?
    var reportAll = false
    var idleResetThreshold: Double = 0
    var skipResets = false
    var resetProcedure: Int?
    var skipHandshake = false
    var logFile: URL?
    var logDirectory: URL

    static var defaultLogDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/GearUp", isDirectory: true)
    }

    static let usage = """
    GearUp Probe — map the buttons of a Zwift Click V2

    USAGE:
      gearup-probe [options]

    OPTIONS:
      --seconds <n>      How long to scan before connecting (default: 10)
      --duration <n>     Stop n seconds after the handshake (default: run until Ctrl-C)
      --connect <uuid>   Connect to a specific peripheral identifier
      --all              List every Bluetooth device, not only Zwift ones
      --keepalive <n>    Hold the puck awake, resetting it after n seconds of quiet (default: off)
      --no-reset         Hold the retry but never reset, so the puck sleeps: does the
                         press that wakes it also arrive as a shift?
      --reset-procedure <n>  Reset with that procedure number instead of the bare reboot
      --no-handshake     Do not send the Click V2 start command
      --log <path>       Write the transcript to this exact file
      --log-dir <path>   Directory for probe-<timestamp>.log (default: ~/Library/Logs/GearUp)
      -h, --help         Show this help

    TIP: run this through `make probe`, which launches the app bundle so macOS
    attributes the Bluetooth permission correctly. Make sure the Click V2 is not
    connected to Zwift, Companion or another device, and press a button on the
    puck to wake it before running the probe.
    """

    static func parse(_ arguments: [String]) -> ProbeOptions? {
        var options = ProbeOptions(logDirectory: defaultLogDirectory)
        var index = 1

        func value(after flag: String) -> String? {
            guard index + 1 < arguments.count else { return nil }
            index += 1
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                print(usage)
                return nil
            case "--all":
                options.reportAll = true
            case "--no-handshake":
                options.skipHandshake = true
            case "--no-reset":
                options.skipResets = true
            case "--seconds":
                if let raw = value(after: argument), let seconds = Double(raw) {
                    options.scanSeconds = seconds
                }
            case "--duration":
                if let raw = value(after: argument), let seconds = Double(raw) {
                    options.runSeconds = seconds
                }
            case "--keepalive":
                if let raw = value(after: argument), let seconds = Double(raw) {
                    options.idleResetThreshold = seconds
                }
            case "--reset-procedure":
                if let raw = value(after: argument), let procedure = Int(raw) {
                    options.resetProcedure = procedure
                }
            case "--connect":
                if let raw = value(after: argument) {
                    options.connectID = UUID(uuidString: raw)
                }
            case "--log":
                if let raw = value(after: argument) {
                    options.logFile = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
                }
            case "--log-dir":
                if let raw = value(after: argument) {
                    options.logDirectory = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
                }
            default:
                print("Unknown option: \(argument)\n")
                print(usage)
                return nil
            }
            index += 1
        }

        return options
    }
}

// MARK: - Choose the most likely target

private func chooseCandidate(from devices: [ClickDevice]) -> ClickDevice? {
    let right = devices.filter(\.isClickV2Right)
    if let best = right.max(by: { $0.rssi < $1.rssi }) { return best }

    let nameMatch = devices.filter {
        guard let name = $0.name?.lowercased() else { return false }
        return name.contains("click") || name.contains("zwift")
    }
    if let best = nameMatch.max(by: { $0.rssi < $1.rssi }) { return best }

    return nil
}

// MARK: - Options and logging

// Output goes to a log file as well as to the terminal, and the terminal is
// often a pipe (when launched by a helper script) where output would otherwise
// be buffered and lost if the process dies early.
setvbuf(stdout, nil, _IONBF, 0)

guard let options = ProbeOptions.parse(CommandLine.arguments) else {
    exit(0)
}

let log: ProbeLog
do {
    if let logFile = options.logFile {
        log = try ProbeLog(fileURL: logFile)
    } else {
        log = try ProbeLog(directory: options.logDirectory)
    }
} catch {
    FileHandle.standardError.write(Data("Could not open log file: \(error)\n".utf8))
    exit(1)
}

log.rule("GearUp Probe")
log.line("Date: \(Date())")
log.line("Log: \(log.fileURL.path)")
if let connectID = options.connectID {
    log.line("Target: \(connectID.uuidString)")
}
log.rule()

// macOS attributes Bluetooth access to the *responsible* process. That is this
// bundle when it was opened through LaunchServices, but whatever started it
// when the bare binary is executed from a shell — and that process may have no
// NSBluetoothAlwaysUsageDescription, which makes the system abort us.
if Bundle.main.bundleURL.pathExtension != "app" {
    log.line("⚠️  Running outside an app bundle.")
    log.line("    macOS may abort this process with a missing-usage-description error.")
    log.line("    Use `make probe` (or scripts/run-probe.sh) instead.")
    log.rule()
}

// MARK: - State

var candidates: [UUID: ClickDevice] = [:]
var didConnect = false
var didFinishScan = false
var durationTimer: DispatchSourceTimer?

/// The puck repeats each report several times per press and then keeps
/// repeating the released state for about a second. Tracking the previous
/// state lets identical reports be collapsed into a repeat count and lets the
/// transcript show press/release edges instead of a wall of duplicates.
var lastButtonMap: UInt32?
var lastPressedButtons: Set<RideButtonMask>?
var repeatCount = 0

/// Stops the probe on its own after `--duration` seconds, so a run can be
/// scripted without leaving a process behind.
func scheduleAutoStop() {
    guard options.runSeconds > 0, durationTimer == nil else { return }
    log.line("Auto-stop in \(Int(options.runSeconds))s (Ctrl-C stops earlier).")
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + options.runSeconds)
    timer.setEventHandler {
        log.rule("Duration reached")
        log.line("Transcript: \(log.fileURL.path)")
        central.stopScan()
        log.close()
        exit(0)
    }
    timer.resume()
    durationTimer = timer
}

// MARK: - Central

let central = ClickCentral()
central.reportAllDevices = options.reportAll
// The probe's `--keepalive` drives the same hold the app uses, so a probe run
// measures the real mechanism rather than a copy of it: `n` is how long the puck
// may sit quiet before it gets a reset.
central.keepsPuckAwake = options.idleResetThreshold > 0 || options.skipResets
if options.idleResetThreshold > 0 {
    central.idleResetThreshold = options.idleResetThreshold
}
if options.skipResets {
    // `--no-reset` answers a question GearUp has never actually put to the
    // hardware: whether the press that wakes a sleeping puck also arrives as a
    // shift. The retry stays on so the wake-up reconnect is caught, and the
    // threshold goes out of reach so the puck is never rebooted.
    central.idleResetThreshold = .infinity
    log.line("(--no-reset: the puck is held but never reset — it will sleep on its own minute.)")
    log.line("  Wait for it to drop, then press a button and watch whether the press arrives.)")
}
// `--no-handshake` used to only say it skipped the start command; the write is
// what actually has to be held back.
central.sendsHandshake = !options.skipHandshake
if let procedure = options.resetProcedure {
    central.resetPayload = ZwiftClickCodec.resetCommand(procedure: procedure)
}

central.onEvent = { event in
    switch event {
    case .state(let state):
        log.line("Bluetooth state: \(state.rawValue)")
        // The scan window starts when the radio does, not when the process did.
        if state == .poweredOn { armScanDeadline() }

    case .discovered(let device):
        candidates[device.id] = device
        var details = "Found: \(device.summary)"
        if !device.advertisedServices.isEmpty {
            details += "\n         services=[\(device.advertisedServices.joined(separator: ", "))]"
        }
        if let manufacturerData = device.manufacturerData {
            details += "\n         manufacturer=\(manufacturerData.hexString)"
        }
        log.line(details)

        // The right puck is the target, so there is no reason to keep scanning
        // and making the rider wait out the whole scan window. Any other
        // device (including the locked left puck) is only a fallback, so those
        // wait for the deadline to see whether the right one shows up.
        if device.isClickV2Right, options.connectID == nil, !didFinishScan {
            didFinishScan = true
            central.stopScan()
            log.line("Right puck found, connecting straight away.")
            central.connect(to: device.id)
        }

    case .connecting(let device):
        log.line("Connecting to \(device.summary)…")

    case .connected(let device):
        didConnect = true
        log.line("Connected to \(device.summary)")
        // A new connection is a new stream of reports, and the first report after
        // a reconnect is the interesting one: it is what the puck says when it
        // wakes up. Keeping the previous connection's button map collapsed it
        // against the last report before the sleep, which hid exactly that.
        lastButtonMap = nil
        repeatCount = 0
        if options.skipHandshake { scheduleAutoStop() }

    case .services(let services):
        log.line("Services: [\(services.joined(separator: ", "))]")

    case .characteristic(let uuid, let properties):
        log.line("  characteristic \(uuid)  [\(properties)]")

    case .subscribed(let uuid, let enabled):
        log.line("  subscribed \(uuid) → \(enabled)")

    case .handshakeSent(let bytes):
        log.line("→ handshake \(bytes.hexString)")
        log.rule()
        log.line("Press your buttons slowly, one at a time: Y, Z, A, B, +")
        log.line("Wait about a second between presses, then press Ctrl-C to stop.")
        log.rule()
        scheduleAutoStop()

    case .notification(let characteristic, let bytes, let decoded):
        // Collapse the repeats: only a change of button map is printed, with a
        // count of how many times the previous one was seen.
        if case .rideKeyPad(let status)? = decoded, status.buttonMap == lastButtonMap {
            repeatCount += 1
            break
        }
        if repeatCount > 0 {
            log.line("   (that report repeated \(repeatCount) more time\(repeatCount == 1 ? "" : "s"))")
            repeatCount = 0
        }

        log.line("← \(characteristic.prefix(8))  \(bytes.hexString)")

        if case .rideKeyPad(let status)? = decoded {
            let pressed = Set(status.pressedButtons)
            for button in pressed.subtracting(lastPressedButtons ?? []) {
                log.line("   ▶ PRESSED \(button.name)   (mask 0x\(String(format: "%04X", button.rawValue)))")
            }
            for button in (lastPressedButtons ?? []).subtracting(pressed) {
                log.line("   ■ released \(button.name)")
            }
            lastPressedButtons = pressed
            lastButtonMap = status.buttonMap
        }

        if let decoded {
            for line in ZwiftClickCodec.describe(decoded).split(separator: "\n") {
                log.line("   \(line)")
            }
        } else {
            log.line("   (empty or undecodable)")
        }

    case .rssi(let value):
        log.line("RSSI: \(value)")

    case .log(let message):
        log.line(message)

    case .error(let message):
        log.line("⚠️  \(message)")

    case .disconnected(let reason):
        log.line("Disconnected\(reason.map { ": \($0)" } ?? "")")
    }
}

central.startScan()

// A backstop for the case where the radio never comes up at all: without it a run
// with Bluetooth unavailable would sit there rather than say so.
DispatchQueue.main.asyncAfter(deadline: .now() + options.scanSeconds + 20) {
    armScanDeadline()
}

// MARK: - Scan deadline

/// Arms the scan window, once, from the moment the radio is actually up.
///
/// It used to be armed at launch, which spent the first seconds of it waiting for
/// Bluetooth to come up: a `--seconds 10` run that took 2.7 s to power the radio
/// listened for 7.8 s, and a puck woken a second late was never seen.
var didArmScanDeadline = false

func armScanDeadline() {
    guard !didArmScanDeadline else { return }
    didArmScanDeadline = true
    log.line("Scan window: \(options.scanSeconds)s — starting now that Bluetooth is up.")

    DispatchQueue.main.asyncAfter(deadline: .now() + options.scanSeconds) {
        guard !didFinishScan else { return }
        didFinishScan = true
        central.stopScan()

        if let connectID = options.connectID {
            guard candidates[connectID] != nil else {
                log.line("The requested peripheral was not seen during the scan.")
                log.line("Try --all to list every device, then pass --connect <uuid>.")
                log.close()
                exit(2)
            }
            central.connect(to: connectID)
            return
        }

        guard let best = chooseCandidate(from: Array(candidates.values)) else {
            log.rule()
            log.line("No Zwift controller found.")
            log.line("Checklist:")
            log.line("  • The puck is awake and advertising (press a button: the LED should blink).")
            log.line("  • Keep pressing while the window runs: a sleeping puck advertises nothing.")
            log.line("  • It is not connected to Zwift, Companion or another device.")
            log.line("  • Bluetooth is on and GearUp Probe has permission.")
            log.line("  • Run again with --all to list every nearby device.")
            log.close()
            exit(2)
        }

        log.line("Selected target: \(best.summary)")
        central.connect(to: best.id)

        if options.skipHandshake {
            log.line("(--no-handshake given: waiting for notifications without sending the start command)")
        }
    }
}

// MARK: - Shutdown

signal(SIGINT, SIG_IGN)
let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signalSource.setEventHandler {
    log.rule("Stopping")
    log.line("Transcript: \(log.fileURL.path)")
    central.stopScan()
    log.close()
    exit(0)
}
signalSource.resume()

RunLoop.main.run()
