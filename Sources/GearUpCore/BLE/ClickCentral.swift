import Foundation
import CoreBluetooth

/// A discovered Zwift controller.
public struct ClickDevice: Equatable {
    public let id: UUID
    public let name: String?
    public let rssi: Int
    public let advertisedServices: [String]
    public let manufacturerData: Data?

    public init(
        id: UUID,
        name: String?,
        rssi: Int,
        advertisedServices: [String],
        manufacturerData: Data?
    ) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.advertisedServices = advertisedServices
        self.manufacturerData = manufacturerData
    }

    /// Zwift encodes its device type in the third byte of the manufacturer
    /// data. `0x0A` is the Click V2 right puck, `0x0B` the left one.
    public var zwiftDeviceType: UInt8? {
        guard let manufacturerData, manufacturerData.count >= 3 else { return nil }
        let company = UInt16(manufacturerData[0]) | (UInt16(manufacturerData[1]) << 8)
        guard company == ZwiftUUID.manufacturerID else { return nil }
        return manufacturerData[2]
    }

    public var zwiftDeviceTypeName: String? {
        switch zwiftDeviceType {
        case 0x09: return "Zwift Click (V1)"
        case 0x0A: return "Zwift Click V2 (right)"
        case 0x0B: return "Zwift Click V2 (left)"
        case 0x07: return "Zwift Ride (right)"
        case 0x08: return "Zwift Ride (left)"
        case 0x02: return "Zwift Play (right)"
        case 0x03: return "Zwift Play (left)"
        default: return zwiftDeviceType.map { String(format: "Zwift device 0x%02X", $0) }
        }
    }

    public var isClickV2Right: Bool { zwiftDeviceType == 0x0A }
    public var isClickV2Left: Bool { zwiftDeviceType == 0x0B }

    public var summary: String {
        var parts: [String] = []
        parts.append(name ?? "unnamed")
        parts.append("id=\(id.uuidString.prefix(8))")
        parts.append("rssi=\(rssi)")
        if let zwiftDeviceTypeName {
            parts.append("zwift=\(zwiftDeviceTypeName)")
        }
        return parts.joined(separator: "  ")
    }
}

public enum ClickCentralState: String {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn

    public var isReady: Bool { self == .poweredOn }
}

public enum ClickCentralEvent {
    case state(ClickCentralState)
    case discovered(ClickDevice)
    case connecting(ClickDevice)
    case connected(ClickDevice)
    case services([String])
    case characteristic(uuid: String, properties: String)
    case subscribed(uuid: String, enabled: Bool)
    case handshakeSent([UInt8])
    case notification(characteristic: String, bytes: [UInt8], decoded: ZwiftNotification?)
    case rssi(Int)
    case log(String)
    case error(String)
    case disconnected(String?)
}

/// Central-role client for a Zwift Click V2.
///
/// Responsibilities:
/// 1. Scan for Zwift controllers (both service UUID variants and the Zwift
///    manufacturer data are accepted, because a locked puck may not advertise
///    its custom service at all).
/// 2. Connect, discover the custom service and its three characteristics.
/// 3. Subscribe to notifications/indications and write the `RideOn` handshake.
/// 4. Forward every notification as raw bytes plus a decoded value.
///
/// It intentionally does no interpretation of button semantics: that is the
/// job of the shifting layer, so the two can evolve independently.
public final class ClickCentral: NSObject {

    public var onEvent: ((ClickCentralEvent) -> Void)?

    public private(set) var state: ClickCentralState = .unknown {
        didSet { onEvent?(.state(state)) }
    }

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var discoveredDevices: [UUID: ClickDevice] = [:]
    /// macOS re-reports the same advertisement repeatedly; announcing each
    /// device once keeps the diagnostic log readable.
    private var announcedPeripherals: Set<UUID> = []

    private var target: CBPeripheral?
    public private(set) var connectedDevice: ClickDevice?

    private var customService: CBService?
    private var asyncCharacteristic: CBCharacteristic?
    private var syncTxCharacteristic: CBCharacteristic?
    private var syncRxCharacteristic: CBCharacteristic?

    private var wantsScan = false
    private var notifyReady = false
    private var indicateReady = false
    private var didSendHandshake = false

    /// The puck the central was last pointed at.
    ///
    /// Kept across a drop because CoreBluetooth hands a peripheral to
    /// `didDiscover` once and then keeps quiet about it: a puck that dropped can
    /// only be picked up again by connecting to the handle we already have.
    private var lastTargetID: UUID?

    /// True while the last disconnect was GearUp's own doing — the bridge being
    /// stopped — so a stopped bridge does not immediately reconnect to the puck
    /// it just let go.
    private var didDisconnectOnPurpose = false

    /// Whether the last drop read as the puck's own sleep, so the log can say
    /// that the retry brought it back rather than leaving two bare lines.
    private var returningFromSleep = false

    private var watchTimer: Timer?
    private var restartTimer: Timer?
    private var reconnectTimer: Timer?
    /// When the puck last showed signs of life — a notification from it, which in
    /// normal use means a button press, or a handshake. The puck's sleep window
    /// runs from there, so this is the clock the hold watches.
    private var lastActivity = Date.distantPast
    /// When the rider last actually pressed a button.
    ///
    /// Distinct from `lastActivity` on purpose: this one is *not* moved by a reset
    /// or by the traffic a reconnect brings, which is what lets a long quiet spell
    /// be told from a busy one. GearUp's own reboots keep the puck awake; they must
    /// not keep the release clock from ever running out.
    private var lastPressAt = Date.distantPast
    /// Whether the hold has stood down for the current quiet spell, so the log says
    /// so once instead of on every tick.
    private var isReleased = false
    /// When the reset command was last written. A reset reboots the puck, so the
    /// disconnect that follows one is GearUp's own doing and says so.
    private var lastResetSentAt: Date?
    /// When the battery was last asked about, so the watch can keep a ride's worth
    /// of readings apart rather than asking on every tick.
    private var lastBatteryAskedAt = Date.distantPast
    private var resetsSent = 0

    /// When true, every discovered peripheral is reported, not just Zwift ones.
    public var reportAllDevices = false

    /// While true the puck is held: its link is kept alive and a drop is retried.
    ///
    /// The puck goes to standby by itself and drops the link **60 seconds after
    /// the last press** — measured on real hardware at 61, 61, 61 and 62 seconds
    /// across one session, and 61 seconds after connecting when nothing had been
    /// pressed at all. Out of standby it only comes back on a button press, so a
    /// rider who has been quiet for a minute loses the shift that wakes it.
    ///
    /// Nothing in the published protocol switches that sleep off, and the two
    /// other bridges document the same wall, so GearUp keeps the puck inside its
    /// window instead: quiet spells close to the sleep earn a reset. A press opens
    /// a fresh window, so a rider who is shifting never reaches the threshold and
    /// GearUp writes nothing at all while the puck is in use.
    ///
    /// Holding costs battery, so `GearUpController` turns this on only while a
    /// press has somewhere to go: a client is connected, or the settings screen
    /// is waiting for a button.
    ///
    /// This governs the *reset* only. Getting a dropped puck back is a separate
    /// matter and is not expensive: see `reconnectInterval`.
    /// Whether the hold is actually running right now: on, and not standing down
    /// for a quiet spell. The difference matters when the link drops, because a
    /// drop after a release is the release doing its job, not a fault.
    public var isHoldingPuck: Bool { keepsPuckAwake && !isReleased }

    public var keepsPuckAwake = false {
        didSet {
            guard keepsPuckAwake != oldValue else { return }
            if keepsPuckAwake {
                // A hold begins with a rider who has just done something: either
                // they are shifting, or a client just came up against a puck that
                // was awake anyway. Both clocks start here.
                lastPressAt = Date()
                isReleased = false
                startHolding()
            } else {
                // The resets stop and the puck is left to power down on its own
                // minute. The way back stays armed all the same.
                stopHolding()
            }
            armReconnect()
        }
    }

    /// How long the puck may sit quiet before GearUp resets it.
    public var idleResetThreshold: TimeInterval = ClickCentral.defaultIdleResetThreshold

    /// How long the puck may sit quiet before GearUp resets it.
    ///
    /// The window is 60 seconds from the last press, so 40 leaves twenty of margin
    /// for the clock and the radio, and a rider shifting at all regularly never
    /// reaches it.
    public static let defaultIdleResetThreshold: TimeInterval = 40

    /// How long after the last sign of life a drop still reads as the puck's sleep.
    ///
    /// A sleeping puck disappears with the same supervision-timeout error as a puck
    /// that walked out of range, and the two could hardly mean more different
    /// things: one is normal, the other is a fault. What tells them apart is the
    /// clock — the puck goes quiet about 61 seconds after the last press or reset
    /// and not before — so a drop that far into a silence is named as the sleep.
    /// Measured on the unit here, the sleep lands 61, 61, 61 and 62 seconds after
    /// the last press; 45 leaves room for the handshake that follows a reconnect.
    public static let sleepDropWindow: TimeInterval = 45

    /// How long the puck may sit quiet before GearUp gives up holding its window.
    ///
    /// The hold buys one thing: that the shift which wakes a sleeping puck is not
    /// swallowed. A rider on a long descent or a steady stretch is not shifting at
    /// all, so there is no shift to lose, and every reset in that spell is a reboot
    /// spent on nothing. Past this much silence GearUp stops resetting and lets the
    /// puck power down. The retry stays on, so the press that wakes it is caught and
    /// the session comes straight back: measured on the unit here, the wake-up
    /// reconnect landed 30 s after the drop and the press which caused it was never
    /// reported — that press is the price, and the one after it shifts as usual.
    public var idleReleaseThreshold: TimeInterval = ClickCentral.defaultIdleReleaseThreshold

    /// Three minutes.
    ///
    /// Long enough that a spell the rider would call "a minute of not shifting"
    /// never reaches it, short enough that a stint on the turbo does not spend a
    /// reboot every forty seconds on a bike nobody is pedalling.
    public static let defaultIdleReleaseThreshold: TimeInterval = 180

    /// What the hold resets the puck with: the RESET command, a single `0x18`.
    public static let resetCommand: [UInt8] = ZwiftClickCodec.resetCommand

    /// How long the puck is given between being reset and being started again.
    ///
    /// The reference's command sender pauses half a second after every write, and
    /// a reset reboots the puck, so the start command waits rather than racing it.
    public static let restartDelay: TimeInterval = 0.5

    /// How often the hold looks at the clock. The watch writes nothing by itself.
    public static let watchInterval: TimeInterval = 5

    /// How long after a reset a drop still counts as the reset's own doing.
    ///
    /// The measured gap is 0.12 s; this leaves room for a slow reboot before the
    /// distinction is dropped and the disconnect is reported as the puck's.
    public static let resetDropWindow: TimeInterval = 3

    /// Every how many resets the log says so — ten minutes' worth of quiet.
    public static let resetHeartbeat = 15

    /// How often the held puck is also asked about its battery.
    ///
    /// The battery is answered as a forecast — minutes left at the drain of the
    /// moment — and the part of it that is a measurement is the percentage. That
    /// percentage only says anything over hours, so a ride has to leave a series
    /// of readings behind rather than one at the start: this is the series. It is
    /// one four-byte read every five minutes while GearUp is holding the link, and
    /// a `Get` does not extend the puck's own window (the Info-Request sent every
    /// 5 s proved that much), so it costs nothing but the bytes.
    public static let batteryInterval: TimeInterval = 300

    /// What a reset writes. Replaceable so the probe can try a reset procedure
    /// other than the bare reboot.
    public var resetPayload: [UInt8] = ClickCentral.resetCommand

    /// How often a dropped link is retried.
    ///
    /// The hold drops the link on purpose now and then — a reset reboots the puck
    /// — so this is also what makes that cost about a second. Both are the same
    /// mechanism, and it is deliberately **not** part of the hold:
    ///
    /// A connect to a peripheral that is not there stays *pending* until it
    /// advertises, which costs the puck nothing at all — it is the same radio
    /// silence as scanning, and a puck in standby is powered down whether GearUp
    /// waits for it or not. So the retry is armed whenever the puck is known and
    /// the link is gone, held or not, and the press that wakes a sleeping puck is
    /// answered instead of being shouted into an empty room. What it buys is that
    /// GearUp left open for hours still shifts, or changes the volume, on the
    /// press after the one that woke the puck.
    ///
    /// Only a genuinely disconnected peripheral is retried, so attempts cannot
    /// stack up behind each other, and while one is pending there is nothing to
    /// do but wait for it to resolve — a failure re-arms the retry.
    public static let reconnectInterval: TimeInterval = 1

    public var isConnected: Bool { target?.state == .connected }

    public override init() {
        super.init()
        // Delegate callbacks are delivered on the main run loop.
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public API

    public func startScan() {
        wantsScan = true
        // A scan started afresh is the one moment a puck already seen in this run
        // is worth announcing again: CoreBluetooth reports a peripheral to
        // `didDiscover` once, so a bridge that was stopped and started would
        // otherwise never see the puck it handed back.
        announcedPeripherals.removeAll()
        guard state.isReady else {
            onEvent?(.log("Waiting for Bluetooth to become available…"))
            return
        }
        beginScan()
    }

    public func stopScan() {
        wantsScan = false
        stopRadioScan()
    }

    public func connect(to id: UUID) {
        guard let peripheral = peripherals[id] else {
            onEvent?(.error("Unknown peripheral \(id.uuidString). Run a scan first."))
            return
        }
        // The radio stops looking — the handle is the way back from here — but
        // GearUp still wants the puck, which is what `wantsScan` means.
        stopRadioScan()
        let device = discoveredDevices[id] ?? ClickDevice(
            id: id,
            name: peripheral.name,
            rssi: 0,
            advertisedServices: [],
            manufacturerData: nil
        )
        onEvent?(.connecting(device))
        target = peripheral
        lastTargetID = id
        didSendHandshake = false
        notifyReady = false
        indicateReady = false
        central.connect(peripheral, options: nil)
    }

    public func disconnect() {
        guard let target else { return }
        didDisconnectOnPurpose = true
        central.cancelPeripheralConnection(target)
    }

    /// Whether a new connection also starts the session.
    ///
    /// The probe turns this off to watch what a controller says without being
    /// asked for anything; the bridge always starts the session, because that is
    /// what makes the button stream arrive.
    public var sendsHandshake = true

    /// Writes the Click V2 start command to the sync-RX characteristic.
    public func sendHandshake() {
        guard let peripheral = target, let syncRxCharacteristic else {
            onEvent?(.error("Cannot send handshake yet: characteristics are not ready."))
            return
        }
        let command = ZwiftClickCodec.clickV2StartCommand
        peripheral.writeValue(Data(command), for: syncRxCharacteristic, type: .withoutResponse)
        // Then ask about the puck itself: the device info, the battery, and whether
        // it counts the link as paired. None of the three is ever volunteered, and
        // each is one write on a connection that has just come up. The Info-Request
        // is not a keep-awake — a whole minute of them, every 5 s, did not stop the
        // sleep — so nothing here is repeated until the link is remade.
        for request in [
            ZwiftClickCodec.infoRequest,
            ZwiftClickCodec.batteryRequest,
            ZwiftClickCodec.securityRequest,
        ] {
            peripheral.writeValue(Data(request), for: syncRxCharacteristic, type: .withoutResponse)
        }
        didSendHandshake = true
        lastActivity = Date()
        lastBatteryAskedAt = Date()
        onEvent?(.handshakeSent(command))
        // A link that just came up is a link worth keeping up, and its handshake
        // opens a fresh window of its own.
        startHolding()
        stopReconnecting()
    }

    // MARK: - Holding the puck

    /// Starts the hold: a clock to watch, and the retry that makes a reset cost
    /// about a second.
    private func startHolding() {
        stopHolding()
        guard keepsPuckAwake, isConnected else { return }
        if lastActivity == .distantPast { lastActivity = Date() }
        watchTimer = Timer.scheduledTimer(withTimeInterval: Self.watchInterval, repeats: true) { [weak self] _ in
            self?.watchIdlePuck()
        }
    }

    private func stopHolding() {
        watchTimer?.invalidate()
        watchTimer = nil
        restartTimer?.invalidate()
        restartTimer = nil
    }

    /// Resets a puck whose sleep window is close to running out.
    ///
    /// The window belongs to the puck and a button press opens a fresh one, so
    /// this only fires after a genuinely quiet spell — the same spell after which
    /// the puck would otherwise fall asleep and need a press to come back.
    private func watchIdlePuck() {
        guard keepsPuckAwake, isConnected else { return }
        askForBatteryIfDue()
        guard Date().timeIntervalSince(lastActivity) >= idleResetThreshold else { return }

        // A press is the whole reason for the hold. Past `idleReleaseThreshold` the
        // rider has stopped shifting — a descent, a steady stretch, the bike parked
        // — and there is no shift left for a reset to save, so the hold stands down
        // and the puck is left to power down on its own minute. The retry stays on,
        // so the press that wakes it puts the session back and the press after that
        // is a shift like any other.
        let quiet = Date().timeIntervalSince(lastPressAt)
        guard quiet < idleReleaseThreshold else {
            releasePuck(quiet: quiet)
            return
        }
        resetPuck()
    }

    /// Stands the hold down for a quiet spell that has run on too long.
    private func releasePuck(quiet: TimeInterval) {
        guard !isReleased else { return }
        isReleased = true
        // The puck is not asleep yet, and saying "leaving it to sleep" without
        // saying when is how a run where every press still landed looks like the
        // sleep was skipped: the window its last reset opened is still running.
        onEvent?(.log(
            "quiet for \(Int(quiet)) s, so leaving the puck to sleep: it powers down about a "
            + "minute after its last reset or press. The press that wakes it is lost, the next shifts."
        ))
    }

    /// Asks the puck for its battery, no more often than `batteryInterval`.
    ///
    /// A read, not a keep-awake: it goes out while the puck is held so that a long
    /// ride leaves a battery trend in the log, and the answer comes back as a data
    /// object like any other.
    private func askForBatteryIfDue() {
        guard let peripheral = target, let syncRxCharacteristic else { return }
        guard Date().timeIntervalSince(lastBatteryAskedAt) >= Self.batteryInterval else { return }
        lastBatteryAskedAt = Date()
        peripheral.writeValue(Data(ZwiftClickCodec.batteryRequest), for: syncRxCharacteristic, type: .withoutResponse)
    }

    /// Resets the puck, then starts it again.
    ///
    /// A reset reboots the puck and its link goes with it, which the retry picks
    /// up and which the handshake then starts exactly as it does on a fresh
    /// connect — so this is the cost of a fresh window paid without waiting for
    /// the puck to decide it is done for the day. The start command half a second
    /// later is for the case where the link survives the reset.
    private func resetPuck() {
        guard let peripheral = target, let syncRxCharacteristic else { return }
        peripheral.writeValue(Data(resetPayload), for: syncRxCharacteristic, type: .withoutResponse)
        lastActivity = Date()
        lastResetSentAt = lastActivity
        resetsSent += 1

        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: Self.restartDelay, repeats: false) { [weak self] _ in
            self?.restartPuck()
        }

        // One line the first time proves the mechanism is running; after that a
        // heartbeat, so a quiet hour does not bury the log. Each reset also shows
        // as the disconnect it is, named as GearUp's own, which is where the
        // timing of a cycle can be read.
        if resetsSent == 1 {
            onEvent?(.log("idle for \(Int(idleResetThreshold)) s, so resetting the puck to open a fresh window."))
        } else if resetsSent % Self.resetHeartbeat == 0 {
            onEvent?(.log("hold heartbeat: \(resetsSent) resets so far."))
        }
    }

    private func restartPuck() {
        restartTimer = nil
        guard let peripheral = target, let syncRxCharacteristic else { return }
        peripheral.writeValue(Data(ZwiftClickCodec.clickV2StartCommand), for: syncRxCharacteristic, type: .withoutResponse)
    }

    /// Retries the last puck by handle, which is the only way back to a device
    /// CoreBluetooth has already introduced: it reports each peripheral to
    /// `didDiscover` once, so scanning alone never finds a dropped puck again.
    ///
    /// A sleeping puck wakes on a button press and answers straight away, so this
    /// is also how the app recovers when a rider picks the controller up — and,
    /// because a pending connect costs the puck nothing, it is armed whether or
    /// not the puck is being held.
    private func startReconnecting() {
        guard reconnectTimer == nil, let id = lastTargetID, let peripheral = peripherals[id] else { return }
        guard peripheral.state == .disconnected else { return }
        reconnectTimer = Timer.scheduledTimer(
            withTimeInterval: Self.reconnectInterval,
            repeats: true
        ) { [weak self] _ in
            self?.retryConnection()
        }
    }

    private func stopReconnecting() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    /// Whether a dropped link should be answered with a retry.
    ///
    /// Two rules matter, and they are worth having in one place: a puck that
    /// dropped while GearUp is running is always worth waiting for — held or not,
    /// because a pending connect costs the puck nothing — and a bridge that let
    /// the puck go on purpose stays let go.
    public static func shouldReconnectAfterDrop(bridgeIsRunning: Bool, deliberate: Bool) -> Bool {
        bridgeIsRunning && !deliberate
    }

    /// Arms the way back, unless the bridge itself just let the puck go.
    private func armReconnect() {
        guard ClickCentral.shouldReconnectAfterDrop(
            bridgeIsRunning: wantsScan,
            deliberate: didDisconnectOnPurpose
        ) else { return }
        startReconnecting()
        // Ask at once instead of waiting out the first tick.
        retryConnection()
    }

    private func retryConnection() {
        guard let id = lastTargetID, let peripheral = peripherals[id] else {
            stopReconnecting()
            return
        }
        switch peripheral.state {
        case .connected:
            stopReconnecting()
        case .connecting:
            // A connect that is already in flight stays pending until the puck
            // advertises, so there is nothing to do and no reason for a timer to
            // keep asking. `didFailToConnect` re-arms if it comes to nothing.
            stopReconnecting()
        case .disconnected:
            target = peripheral
            central.connect(peripheral, options: nil)
        default:
            break
        }
    }

    // MARK: - Private

    private func beginScan() {
        onEvent?(.log("Scanning for Zwift controllers…"))
        // Scanning with no service filter is deliberate: a locked Click V2 may
        // hide its custom service and only be recognisable by name or by the
        // Zwift manufacturer data.
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func stopRadioScan() {
        if state.isReady {
            central.stopScan()
        }
    }

    private func isZwiftPeripheral(advertisementData: [String: Any], name: String?) -> Bool {
        if let name, name.localizedCaseInsensitiveContains("zwift") { return true }
        if let name, name.localizedCaseInsensitiveContains("click") { return true }

        if let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
           services.contains(where: { ZwiftUUID.isCustomService($0.uuidString) }) {
            return true
        }

        if let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           manufacturerData.count >= 2 {
            let company = UInt16(manufacturerData[0]) | (UInt16(manufacturerData[1]) << 8)
            if company == ZwiftUUID.manufacturerID { return true }
        }

        return false
    }

    private func characteristicSummary(_ characteristic: CBCharacteristic) -> String {
        var properties: [String] = []
        if characteristic.properties.contains(.read) { properties.append("read") }
        if characteristic.properties.contains(.write) { properties.append("write") }
        if characteristic.properties.contains(.writeWithoutResponse) { properties.append("writeNoResponse") }
        if characteristic.properties.contains(.notify) { properties.append("notify") }
        if characteristic.properties.contains(.indicate) { properties.append("indicate") }
        return properties.joined(separator: "|")
    }
}

// MARK: - CBCentralManagerDelegate

extension ClickCentral: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            state = .poweredOn
            onEvent?(.log("Bluetooth is available."))
            if wantsScan { beginScan() }
        case .poweredOff:
            state = .poweredOff
            onEvent?(.error("Bluetooth is turned off. Enable it in System Settings."))
        case .unauthorized:
            state = .unauthorized
            onEvent?(.error(
                "Bluetooth permission denied. Grant it in System Settings → Privacy & Security → Bluetooth, then run again."
            ))
        case .unsupported:
            state = .unsupported
            onEvent?(.error("This Mac does not support Bluetooth Low Energy."))
        case .resetting:
            state = .resetting
        default:
            state = .unknown
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
        let isZwift = isZwiftPeripheral(advertisementData: advertisementData, name: name)
        guard isZwift || reportAllDevices else { return }

        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map(\.uuidString) ?? []
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data

        let device = ClickDevice(
            id: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue,
            advertisedServices: services,
            manufacturerData: manufacturerData
        )

        peripherals[peripheral.identifier] = peripheral
        discoveredDevices[peripheral.identifier] = device

        // Refresh the RSSI/name in the cache, but only announce a device the
        // first time it is seen.
        guard announcedPeripherals.insert(peripheral.identifier).inserted else { return }
        onEvent?(.discovered(device))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedDevice = discoveredDevices[peripheral.identifier] ?? ClickDevice(
            id: peripheral.identifier,
            name: peripheral.name,
            rssi: 0,
            advertisedServices: [],
            manufacturerData: nil
        )
        onEvent?(.connected(connectedDevice!))
        // A reconnect that followed the puck's own sleep is the retry doing its
        // job, which is worth saying: it is the difference between a link that
        // came back because a rider picked the puck up and one that never came
        // back at all.
        if returningFromSleep {
            returningFromSleep = false
            onEvent?(.log("The puck answered the retry: it is back after its sleep, so a press "
                + "reached it. That press is lost; the next one shifts as usual."))
        }
        peripheral.delegate = self
        onEvent?(.log("Discovering services…"))
        peripheral.discoverServices(nil)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        onEvent?(.error("Failed to connect: \(error?.localizedDescription ?? "unknown error")"))
        // The attempt is spent, so the way back has to be re-armed or an
        // out-of-range puck would be given up on for good.
        armReconnect()
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        // A reset reboots the puck, so say when a drop is one of GearUp's own
        // rather than leaving a bare "disconnected" in the log with no cause. The
        // puck's own sleep reads and is named differently: same error, opposite
        // meaning, and the clock is the only thing that tells them apart.
        let deliberate = lastResetSentAt.map {
            Date().timeIntervalSince($0) < Self.resetDropWindow
        } ?? false
        let quiet = lastActivity == .distantPast ? 0 : Date().timeIntervalSince(lastActivity)
        let reason: String?
        if deliberate {
            reason = "the reset GearUp sent: \(error?.localizedDescription ?? "the puck reboots on it")"
        } else if quiet >= Self.sleepDropWindow {
            reason = "the puck's own sleep: it drops the link about a minute after the last press"
        } else {
            reason = error?.localizedDescription
        }
        returningFromSleep = !deliberate && !didDisconnectOnPurpose && quiet >= Self.sleepDropWindow
        onEvent?(.disconnected(reason))
        target = nil
        connectedDevice = nil
        asyncCharacteristic = nil
        syncTxCharacteristic = nil
        syncRxCharacteristic = nil
        didSendHandshake = false
        stopHolding()
        lastResetSentAt = nil
        // The link is gone whatever happens next, and the way back is a connect to
        // the handle we already have. That is armed whether or not the puck is
        // being held — a pending connect costs the puck nothing — so a puck that
        // is left to sleep still answers the press that wakes it. The one
        // exception is GearUp letting go on purpose: a stopped bridge stays
        // stopped.
        if didDisconnectOnPurpose {
            didDisconnectOnPurpose = false
            stopReconnecting()
        } else {
            armReconnect()
        }
        // Nothing to retry — a puck this run has never seen — is the only case a
        // radio scan can help with; the retry covers the rest.
        if wantsScan, lastTargetID == nil { beginScan() }
    }
}

// MARK: - CBPeripheralDelegate

extension ClickCentral: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            onEvent?(.error("Service discovery failed: \(error.localizedDescription)"))
            return
        }
        let services = peripheral.services ?? []
        onEvent?(.services(services.map(\.uuid.uuidString)))

        guard let custom = services.first(where: { ZwiftUUID.isCustomService($0.uuid.uuidString) }) else {
            onEvent?(.error(
                """
                Zwift custom service not found on \(connectedDevice?.summary ?? "device").
                The puck may be locked to Zwift. Connect it once in the Zwift app \
                (device connection screen, ~10-30 s) and retry, or use the right puck.
                """
            ))
            return
        }

        customService = custom
        onEvent?(.log("Found custom service \(custom.uuid.uuidString). Discovering characteristics…"))
        peripheral.discoverCharacteristics(nil, for: custom)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            onEvent?(.error("Characteristic discovery failed: \(error.localizedDescription)"))
            return
        }

        let characteristics = service.characteristics ?? []
        for characteristic in characteristics {
            onEvent?(.characteristic(uuid: characteristic.uuid.uuidString, properties: characteristicSummary(characteristic)))
        }

        asyncCharacteristic = characteristics.first {
            ZwiftUUID.isCharacteristic($0.uuid.uuidString, ZwiftUUID.asyncCharacteristic)
        }
        syncTxCharacteristic = characteristics.first {
            ZwiftUUID.isCharacteristic($0.uuid.uuidString, ZwiftUUID.syncTxCharacteristic)
        }
        syncRxCharacteristic = characteristics.first {
            ZwiftUUID.isCharacteristic($0.uuid.uuidString, ZwiftUUID.syncRxCharacteristic)
        }

        guard let asyncCharacteristic,
              let syncTxCharacteristic,
              syncRxCharacteristic != nil else {
            let found = characteristics.map(\.uuid.uuidString).joined(separator: ", ")
            onEvent?(.error(
                """
                Missing one of the expected characteristics (async 0x0002, sync RX 0x0003, sync TX 0x0004).
                Found on \(service.uuid.uuidString): [\(found)]
                """
            ))
            return
        }

        onEvent?(.log("Subscribing to notifications and indications…"))
        peripheral.setNotifyValue(true, for: asyncCharacteristic)
        peripheral.setNotifyValue(true, for: syncTxCharacteristic)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            onEvent?(.error("Subscription failed for \(characteristic.uuid.uuidString): \(error.localizedDescription)"))
            return
        }
        onEvent?(.subscribed(uuid: characteristic.uuid.uuidString, enabled: characteristic.isNotifying))

        if ZwiftUUID.isCharacteristic(characteristic.uuid.uuidString, ZwiftUUID.asyncCharacteristic) {
            notifyReady = characteristic.isNotifying
        }
        if ZwiftUUID.isCharacteristic(characteristic.uuid.uuidString, ZwiftUUID.syncTxCharacteristic) {
            indicateReady = characteristic.isNotifying
        }

        if notifyReady && indicateReady && !didSendHandshake, sendsHandshake {
            onEvent?(.log("Subscriptions ready. Sending handshake."))
            sendHandshake()
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            onEvent?(.error("Write to \(characteristic.uuid.uuidString) failed: \(error.localizedDescription)"))
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            onEvent?(.error("Notification error on \(characteristic.uuid.uuidString): \(error.localizedDescription)"))
            return
        }
        guard let data = characteristic.value, !data.isEmpty else { return }
        let bytes = [UInt8](data)
        // Anything the puck says counts as it being alive: a report, a handshake
        // echo, an answer to the Info-Request. In a ride that is a button press.
        lastActivity = Date()
        let decoded = ZwiftClickCodec.decode(bytes)
        // A press is what opens a fresh window on the puck, so it is also the only
        // thing that counts as the rider being there. The burst of reports that
        // follows a press, and the state report a reconnect brings with it, are
        // silence as far as the release clock is concerned.
        if case .rideKeyPad(let status)? = decoded, !status.pressedButtons.isEmpty {
            lastPressAt = Date()
            // A press after a quiet spell that had ended the hold is the rider
            // coming back, so the hold returns with them — and the log says so, or
            // a release line followed by resets looks like a contradiction.
            if isReleased {
                isReleased = false
                onEvent?(.log("a press after the quiet: holding the puck's window again."))
            }
        }
        onEvent?(.notification(characteristic: characteristic.uuid.uuidString, bytes: bytes, decoded: decoded))
    }

    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        onEvent?(.rssi(RSSI.intValue))
    }
}
