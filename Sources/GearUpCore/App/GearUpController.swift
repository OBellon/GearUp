import Foundation
import Combine

/// What the Zwift Click V2 is doing, for the UI.
public struct ClickStatus: Equatable {
    public enum Phase: String, Equatable {
        case off
        case unavailable
        case searching
        case connecting
        case connected
    }

    public var phase: Phase
    public var name: String?
    public var identifier: String?
    public var rssi: Int?
    public var battery: Int?
    public var note: String?

    public init(
        phase: Phase = .off,
        name: String? = nil,
        identifier: String? = nil,
        rssi: Int? = nil,
        battery: Int? = nil,
        note: String? = nil
    ) {
        self.phase = phase
        self.name = name
        self.identifier = identifier
        self.rssi = rssi
        self.battery = battery
        self.note = note
    }

    public static let idle = ClickStatus()

    public var title: String {
        switch phase {
        case .off: return "Off"
        case .unavailable: return "Unavailable"
        case .searching: return "Looking for the puck"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        }
    }

    public var detail: String? {
        switch phase {
        case .off: return "Starting the bridge turns the radio on."
        case .unavailable: return note
        case .searching: return note ?? "Press a button on the puck to wake it up."
        case .connecting: return name
        case .connected:
            var parts: [String] = []
            if let name { parts.append(name) }
            if let identifier { parts.append("id \(identifier)") }
            if let rssi { parts.append("\(rssi) dBm") }
            if let battery { parts.append("battery \(battery)%") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }
}

/// Ties the whole bridge together:
///
///     Zwift Click V2 ──BLE──▶ ButtonRouter ──▶ OpenBikeControl ──▶ MyWhoosh
///                                            └─▶ the Mac (volume, desktops)
///
/// The Click V2 is the only thing GearUp reads, and the trainer app is the only
/// thing it talks to. GearUp never connects to the trainer, because MyWhoosh
/// owns resistance and would lose track of its own gear if two things drove it.
///
/// Everything runs on the main queue — CoreBluetooth is created with a nil queue
/// and Network with `.main` — so the published state can be mutated directly.
public final class GearUpController: ObservableObject {

    // MARK: - Published state

    @Published public private(set) var isRunning = false
    @Published public private(set) var click = ClickStatus.idle
    @Published public private(set) var gear: Drivetrain
    @Published public private(set) var transports: [TransportState] = []
    @Published public private(set) var pressedButtons: Set<RideButtonMask> = []
    @Published public private(set) var lastShiftAction: ButtonAction?
    @Published public private(set) var shiftCount = 0

    /// Whether the app currently holds the Accessibility grant that changing
    /// desktops needs. Published so the settings screen can say so.
    @Published public private(set) var hasAccessibility = MacControl.hasAccessibility

    /// The action waiting for the rider to press a button on the puck, or `nil`
    /// when no assignment is in progress.
    @Published public private(set) var learningAction: ButtonAction?

    /// The most recent settings change is written straight through to disk.
    ///
    /// Deliberately not `@Published`. SwiftUI writes two-way bindings back with
    /// the value it just read in several places — `MenuBarExtra(isInserted:)`
    /// does — and `@Published` announces every assignment, changed or not. Each
    /// announcement re-renders whatever owns the binding, which writes it
    /// again, which announces again: the update loop runs away until the stack
    /// overflows and the app dies with a beachball. Announcing only a real
    /// change is the smallest thing that stops it, and it keeps the settings
    /// view from being re-rendered for nothing.
    public var settings: GearUpSettings {
        willSet {
            guard newValue != settings else { return }
            objectWillChange.send()
        }
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
            if settings.buttonMap != oldValue.buttonMap {
                router.buttonMap = settings.buttonMap
                log.add("Button map: \(buttonMapSummary).")
            }
            if settings.gearCount != oldValue.gearCount {
                gear.setGearCount(settings.gearCount)
                log.add("Gear readout set to \(gear.gearCount) gears.")
            }
            if settings.startingGear != oldValue.startingGear {
                log.add("Starting gear set to \(settings.startingGear).")
            }
            if settings.transportMode != oldValue.transportMode {
                log.add("Transport changed to \(settings.transportMode.title).")
                applyTransportMode()
            }
        }
    }

    public let log = EventLog()

    /// One transport's state, as the UI sees it.
    public struct TransportState: Identifiable, Equatable {
        public let kind: OpenBikeTransportKind
        public var status: OpenBikeStatus
        public var appInfo: OpenBikeAppInfo?
        public var id: String { kind.rawValue }
    }

    // MARK: - Collaborators

    private let store: SettingsStore
    private let clickCentral = ClickCentral()
    private let router: ButtonRouter
    private let bluetoothPeripheral = OpenBikePeripheral()
    private let networkServer = OpenBikeNetworkServer()

    private var allTransports: [OpenBikeTransport] { [bluetoothPeripheral, networkServer] }

    /// The last notification, kept so the Click V2's flood of identical reports
    /// can be collapsed into a single line with a count.
    private var lastNotificationBytes: [UInt8]?
    private var repeatCount = 0

    // MARK: - Derived state

    /// The app info of whichever transport has an app attached.
    public var connectedApp: OpenBikeAppInfo? {
        transports.compactMap(\.appInfo).first
    }

    public var isAppConnected: Bool {
        transports.contains { $0.status.isConnected }
    }

    public var activeTransportCount: Int {
        transports.filter { $0.status.isRunning }.count
    }

    // MARK: - Lifecycle

    public init(store: SettingsStore = SettingsStore()) {
        self.store = store
        let settings = store.load()
        self.settings = settings
        self.gear = Drivetrain(gearCount: settings.gearCount, currentGear: settings.startingGear)
        self.router = ButtonRouter(buttonMap: settings.buttonMap)

        // The switcher has to be watching before the first press to know where
        // the rider came from, so it starts with the app rather than on demand.
        RideAppSwitcher.shared.start()

        router.onAction = { [weak self] action, _ in
            self?.perform(action)
        }
        router.onButtonChange = { [weak self] button, isPressed in
            guard let self else { return }
            if isPressed {
                pressedButtons.insert(button)
            } else {
                pressedButtons.remove(button)
            }
            if isPressed, let action = learningAction {
                learn(button, for: action)
            }
        }
        clickCentral.onEvent = { [weak self] event in
            self?.handleClickEvent(event)
        }
        for transport in allTransports {
            transport.delegate = self
        }
        transports = [
            TransportState(kind: .bluetooth, status: bluetoothPeripheral.status),
            TransportState(kind: .network, status: networkServer.status),
        ]

        log.add("GearUp ready. Button map: \(buttonMapSummary).")
        log.add("Readout: \(gear.gearCount) gears, starting at \(gear.currentGear).")
        log.add("Away from MyWhoosh: \(RideAppSwitcher.shared.awayDestinationName ?? "the next desktop").")
        log.add("Looking for a Zwift Click V2 (right puck).", level: .info)
    }

    /// Starts looking for the puck and opens the configured transports.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        click = ClickStatus(phase: .searching, note: "Press a button on the puck to wake it up.")
        log.add("Bridging enabled (\(settings.transportMode.title)).", level: .success)
        clickCentral.startScan()
        applyTransportMode()
    }

    /// Stops everything: the radio scan and every advertised transport.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        clickCentral.stopScan()
        clickCentral.disconnect()
        for transport in allTransports { transport.stop() }
        router.reset()
        pressedButtons.removeAll()
        updateTransportStates()
        click = .idle
        log.add("Bridging stopped.", level: .warning)
    }

    public func toggle() {
        isRunning ? stop() : start()
    }

    // MARK: - Buttons

    /// Runs an action without the puck, so the rider can check it before
    /// touching the bike: a shift against MyWhoosh, a Mac action against the Mac.
    public func sendTestAction(_ action: ButtonAction) {
        log.add("Sending a test \(action.title.lowercased()).")
        perform(action)
    }

    private func perform(_ action: ButtonAction) {
        // Mac actions never touch the gear and need no transport: a volume press
        // while MyWhoosh is closed should still change the volume.
        guard action.isShift else {
            // The grant can change while GearUp is running, so the settings
            // screen's answer is refreshed from the source each time a button
            // asks about it.
            refreshAccessibility()
            MacControl.perform(action) { [weak self] note in
                self?.log.add("\(action.title): \(note)")
            }
            return
        }

        switch action {
        case .shiftUp: gear.shiftUp()
        case .shiftDown: gear.shiftDown()
        default: return
        }

        lastShiftAction = action
        shiftCount += 1
        log.add("\(action.title) → gear \(gear.currentGear) of \(gear.gearCount).", level: .success)

        let connected = allTransports.filter { $0.status.isConnected }
        guard !connected.isEmpty else {
            log.add("Nothing is connected to receive the shift.", level: .warning)
            return
        }
        for transport in connected { transport.sendTap(for: action) }
    }

    /// Puts the local gear readout back to the configured starting gear — where
    /// a fresh MyWhoosh ride begins — e.g. after a restart.
    public func resetGear() {
        gear.reset(to: settings.startingGear)
        log.add("Gear readout reset to \(gear.currentGear).")
    }

    // MARK: - Button map

    /// Waits for the next button pressed on the puck and gives it to an action.
    ///
    /// While this is running the router keeps reporting presses — so the screen
    /// still shows the puck being read — but stops emitting actions, which is why
    /// the gear cannot move and the volume cannot jump while a button is being
    /// reassigned.
    public func learnButton(for action: ButtonAction) {
        learningAction = action
        router.isCapturingButtons = true
        // Holding the puck now matters: a capture that waits on a puck which
        // falls asleep after a minute is a capture that never completes.
        updatePuckPolicy()
        log.add("Press a button on the puck to give it to \(action.title).")
    }

    /// Gives up on an assignment without changing anything.
    public func cancelLearning() {
        guard learningAction != nil else { return }
        learningAction = nil
        router.isCapturingButtons = false
        updatePuckPolicy()
        log.add("Button assignment cancelled.")
    }

    /// Points a puck button at an action, from the settings screen. `nil` takes
    /// the action off whatever button carries it, which is what "None" means.
    public func assign(_ button: RideButtonMask?, to action: ButtonAction) {
        guard let button else {
            guard let current = settings.button(for: action) else { return }
            settings.assign(current, to: nil)
            return
        }
        if settings.assign(button, to: action) != .unchanged {
            askForAccessibilityIfNeeded(for: action)
        }
    }

    /// Whether a desktop action needs the Accessibility grant, and the one-off
    /// prompt for it. Binding such a button is the calm moment to ask: the rider
    /// is in the settings screen, not mid-ride.
    public func askForAccessibilityIfNeeded(for action: ButtonAction) {
        guard action.needsAccessibility else { return }
        MacControl.askForAccessibilityOnce()
        refreshAccessibility()
    }

    /// Re-reads the grant, so the settings screen can say whether it is in place.
    public func refreshAccessibility() {
        let granted = MacControl.hasAccessibility
        if granted != hasAccessibility { hasAccessibility = granted }
    }

    /// Puts the button map back to the shipped `+` and `B`.
    public func restoreDefaultButtonMap() {
        settings.restoreDefaultButtonMap()
    }

    private func learn(_ button: RideButtonMask, for action: ButtonAction) {
        learningAction = nil
        router.isCapturingButtons = false
        // A real change is logged by the settings observer, which prints the
        // resulting map; only a press that changed nothing needs a word here.
        if settings.assign(button, to: action) == .unchanged {
            log.add("\(button.displayName) is already assigned to \(action.title).")
        } else {
            askForAccessibilityIfNeeded(for: action)
        }
        updatePuckPolicy()
    }

    /// The map in one line: `+ Shift Up, B Shift Down`.
    private var buttonMapSummary: String {
        let parts = settings.buttonMap.all.map { "\($0.button.displayName) \($0.action.title)" }
        return parts.isEmpty ? "nothing assigned" : parts.joined(separator: ", ")
    }

    // MARK: - Transports

    private func applyTransportMode() {
        guard isRunning else { return }
        let wanted = settings.transportMode.kinds
        for transport in allTransports {
            if wanted.contains(transport.kind) {
                if !transport.status.isRunning { transport.start() }
            } else if transport.status != .off {
                transport.stop()
            }
        }
        updateTransportStates()
    }

    private func updateTransportStates() {
        transports = allTransports.map { transport in
            TransportState(kind: transport.kind, status: transport.status, appInfo: transport.appInfo)
        }
        updatePuckPolicy()
    }

    // MARK: - Click V2

    /// Whether the puck earns its battery right now.
    ///
    /// Holding it awake is what stops it dropping the link 60 seconds after the
    /// last press, and it costs battery by design: that sleep *is* the puck's own
    /// power saving. It only buys anything while there is somewhere for a shift
    /// to go, so GearUp holds the puck exactly then — a client is connected, or a
    /// rider is waiting to assign a button — and leaves it alone the rest of the
    /// time, to power down on its own minute.
    private var isPuckWanted: Bool {
        isAppConnected || learningAction != nil
    }

    private func updatePuckPolicy() {
        let wanted = isPuckWanted
        guard wanted != clickCentral.keepsPuckAwake else { return }
        clickCentral.keepsPuckAwake = wanted
        if wanted {
            log.add("Holding the puck awake: presses have somewhere to go.")
        } else {
            log.add("Letting the puck sleep: no ride is listening and no capture is waiting.")
        }
    }

    private func handleClickEvent(_ event: ClickCentralEvent) {
        switch event {
        case .state(let state):
            handleBluetoothState(state)

        case .discovered(let device):
            // v1 drives the right puck only: the left one needs a Zwift unlock
            // before it will report anything useful.
            if device.isClickV2Right {
                click.phase = .connecting
                click.name = device.name
                click.identifier = String(device.id.uuidString.prefix(8))
                log.add("Found a Click V2 right puck (\(device.id.uuidString.prefix(8)), \(device.rssi) dBm). Connecting.", level: .success)
                clickCentral.connect(to: device.id)
            } else if device.isClickV2Left {
                log.add("Ignoring a Click V2 left puck: the left side needs a Zwift unlock.")
            } else {
                log.add("Ignoring \(device.zwiftDeviceTypeName ?? device.summary): not a Click V2 right puck.")
            }

        case .connecting(let device):
            click.phase = .connecting
            click.name = device.name
            log.add("Connecting to \(device.summary)…")

        case .connected(let device):
            click.phase = .connected
            click.name = device.name
            click.identifier = String(device.id.uuidString.prefix(8))
            click.note = nil
            log.add("Click V2 connected.", level: .success)

        case .services(let uuids):
            log.add("Services: \(uuids.joined(separator: ", "))")

        case .characteristic(let uuid, let properties):
            log.add("  \(uuid) [\(properties)]")

        case .subscribed(let uuid, let enabled):
            log.add("  \(enabled ? "subscribed to" : "unsubscribed from") \(uuid)")

        case .handshakeSent(let bytes):
            log.add("Sending the activation handshake (\(bytes.hexString)).")

        case .notification(let characteristic, let bytes, let decoded):
            handleNotification(characteristic: characteristic, bytes: bytes, decoded: decoded)

        case .rssi(let value):
            click.rssi = value

        case .log(let message):
            log.add("Click V2: \(message)")

        case .error(let message):
            log.add(message, level: .error)

        case .disconnected(let reason):
            router.reset()
            pressedButtons.removeAll()
            click.phase = isRunning ? .searching : .off
            click.rssi = nil
            click.battery = nil
            lastNotificationBytes = nil
            repeatCount = 0
            let suffix = reason.map { " (\($0))" } ?? ""
            if clickCentral.keepsPuckAwake {
                // The central is already retrying by handle, so say that instead
                // of telling the rider to press a button for nothing.
                click.note = "Reconnecting…"
                log.add("Click V2 disconnected\(suffix). Reconnecting.", level: .warning)
            } else {
                // Not held, so the resets stop and the puck powers down on its own
                // minute. The way back is armed all the same: the press that wakes
                // it is answered, and the press after that one does its job.
                click.note = "Sleeping; a press brings it back."
                log.add(
                    "Click V2 disconnected\(suffix). Leaving it to sleep; the press that wakes it "
                    + "brings the link back, and the one after it lands.",
                    level: .warning
                )
            }
        }
    }

    private func handleBluetoothState(_ state: ClickCentralState) {
        switch state {
        case .poweredOn:
            if click.phase == .unavailable || click.phase == .off, isRunning {
                click = ClickStatus(phase: .searching, note: "Press a button on the puck to wake it up.")
            }
        case .poweredOff:
            click.phase = .unavailable
            click.note = "Bluetooth is off. Turn it on in System Settings."
            log.add("Bluetooth is off.", level: .error)
        case .unauthorized:
            click.phase = .unavailable
            click.note = "Bluetooth permission denied. Grant it in System Settings → Privacy & Security → Bluetooth."
            log.add("Bluetooth permission denied.", level: .error)
        case .unsupported:
            click.phase = .unavailable
            click.note = "This Mac does not support Bluetooth Low Energy."
            log.add("Bluetooth Low Energy is unsupported.", level: .error)
        case .unknown, .resetting:
            break
        }
    }

    private func handleNotification(characteristic: String, bytes: [UInt8], decoded: ZwiftNotification?) {
        // The puck repeats every report several times per press, then repeats
        // the released state for about a second. Collapsing the repeats keeps
        // the log readable.
        if bytes == lastNotificationBytes {
            repeatCount += 1
            return
        }
        if repeatCount > 0 {
            log.add("  (the report above repeated \(repeatCount) more time\(repeatCount == 1 ? "" : "s"))")
            repeatCount = 0
        }
        lastNotificationBytes = bytes

        guard let decoded else {
            log.add("Unreadable notification \(bytes.hexString) on \(characteristic).", level: .warning)
            return
        }

        switch decoded {
        case .rideKeyPad(let status):
            let names = status.pressedButtons.map(\.name)
            if !names.isEmpty {
                log.add("Click V2: \(names.joined(separator: " + ")) pressed.")
            }
            router.handle(status)

        case .clickKeyPad(let status):
            let plus = status.plusPressed.map { $0 ? "pressed" : "released" }
            let minus = status.minusPressed.map { $0 ? "pressed" : "released" }
            log.add("Click V2 (legacy report): plus=\(plus ?? "—") minus=\(minus ?? "—")")

        case .battery(let level, let chargingState, _):
            click.battery = level
            let state = chargingState.map { ", charging state \($0)" } ?? ""
            log.add("Click V2 battery \(level)%\(state).")

        case .handshake(let value):
            log.add("Click V2 acknowledged the handshake (\(value.hexString)).", level: .success)

        case .dataObject(let object):
            handleDataObject(object)

        case .empty:
            log.add("Click V2 sent an empty report.")

        case .disconnect:
            log.add("Click V2 reported a disconnect.", level: .warning)

        case .unknown(let type, let payload):
            // The puck answers on the indicating characteristic with things that
            // are not rider input — its device info, and the `ff 05 …` the
            // reference reads as "stopped" after a reset. Identical ones collapse
            // into a repeat count above, so one quiet line each is enough, rather
            // than a warning per reply.
            if ZwiftUUID.isCharacteristic(characteristic, ZwiftUUID.syncTxCharacteristic) {
                log.add(String(format: "Click V2 answered (0x%02X): %@", type, payload.hexString))
            } else {
                log.add(String(format: "Unknown message 0x%02X %@", type, payload.hexString), level: .warning)
            }
        }
    }

    /// Reads out a data object the puck answered a `Get` with.
    ///
    /// GearUp asks about three ids on every connection and each one earns its own
    /// line: the device info, the battery — which also sets the level the UI shows
    /// — and the BLE security state, which is the reason the puck's LED sits in
    /// pairing mode, since it never gets past `none`.
    private func handleDataObject(_ object: ZwiftDataObject) {
        switch object.objectID {
        case ZwiftClickCodec.deviceInfoObjectID:
            if let info = ZwiftDevInfoPage.decode(object) {
                log.add("Click V2 device info: \(info.summary).")
                return
            }

        case ZwiftClickCodec.batteryObjectID:
            if let battery = ZwiftBatteryStatus.decode(object) {
                click.battery = battery.level
                log.add("Click V2 battery \(battery.summary).")
                return
            }

        case ZwiftClickCodec.securityObjectID:
            if let security = ZwiftSecurityStatus.decode(object) {
                let note = security.isActive
                    ? ""
                    : " That is why its LED stays in pairing mode."
                log.add("Click V2 secure connection: \(security.summary).\(note)")
                return
            }

        default:
            break
        }

        log.add("Click V2 data object \(object.objectID): \(object.data.hexString)")
    }
}

// MARK: - OpenBikeTransportDelegate

extension GearUpController: OpenBikeTransportDelegate {

    public func transportDidChangeStatus(_ transport: OpenBikeTransport) {
        updateTransportStates()
    }

    public func transport(_ transport: OpenBikeTransport, didConnect peer: String) {
        updateTransportStates()
        log.add("\(transport.kind.title): \(peer) connected.", level: .success)
    }

    public func transport(_ transport: OpenBikeTransport, didDisconnect peer: String) {
        updateTransportStates()
        log.add("\(transport.kind.title): \(peer) disconnected.", level: .warning)
    }

    public func transport(_ transport: OpenBikeTransport, didReceiveAppInfo info: OpenBikeAppInfo) {
        updateTransportStates()
        log.add("\(transport.kind.title): \(info.appID) \(info.appVersion) connected.", level: .success)
        if !info.supportedButtonNames.contains(OpenBikeButton.shiftUp.name) {
            log.add(
                "\(info.appID) does not list “\(OpenBikeButton.shiftUp.name)” as supported; shifts may be ignored.",
                level: .warning
            )
        }
    }

    public func transport(_ transport: OpenBikeTransport, log message: String, level: LogEntry.Level) {
        log.add("\(transport.kind.title): \(message)", level: level)
    }
}
