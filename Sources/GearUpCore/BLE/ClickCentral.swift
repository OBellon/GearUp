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

    private var keepAliveTimer: Timer?
    private var restartTimer: Timer?
    private var reconnectTimer: Timer?
    private var keepAliveCycles = 0

    /// When true, every discovered peripheral is reported, not just Zwift ones.
    public var reportAllDevices = false

    /// While true the puck is held: its link is kept alive and a drop is retried.
    ///
    /// The puck goes to standby by itself and drops the link **60 seconds after
    /// the last press** — measured on real hardware at 61, 61, 61 and 62 seconds
    /// across one session, and 61 seconds after connecting when nothing had been
    /// pressed at all. That is how it protects its coin cell, and why the first
    /// shift after a quiet spell is the one that has to wake it. Holding it awake
    /// costs battery, so `GearUpController` turns this on only while there is
    /// something to shift for.
    public var keepsPuckAwake = false {
        didSet {
            guard keepsPuckAwake != oldValue else { return }
            if keepsPuckAwake {
                // The policy can switch on long after the link came up — the log
                // has it 53 seconds in — and a connection's own window is only 60
                // seconds, so hold the puck the moment it is wanted.
                startKeepAlive(holdNow: true)
                startReconnecting()
            } else {
                stopKeepAlive()
                stopReconnecting()
            }
        }
    }

    /// How often the keep-awake cycle runs while the puck is held.
    public var keepAliveInterval: TimeInterval = ClickCentral.defaultKeepAliveInterval

    /// How often the keep-awake cycle runs.
    ///
    /// The puck sleeps 60 seconds after the last press, so the cycle has to land
    /// comfortably inside that; 40 seconds leaves twenty of margin. It is also
    /// cheap: two writes a minute, where a 5-second ping cost twelve.
    public static let defaultKeepAliveInterval: TimeInterval = 40

    /// What the cycle resets the puck with: the RESET command, a single `0x18`.
    public static let resetCommand: [UInt8] = ZwiftClickCodec.resetCommand

    /// How long the puck is given between being reset and being started again.
    ///
    /// The reference's command sender pauses half a second after every write, and
    /// a reset makes the puck stop, so the start command waits rather than racing
    /// it. Well inside the cycle either way.
    public static let restartDelay: TimeInterval = 0.5

    /// How often a dropped link is retried while the puck is held. The puck's
    /// radio is off until a button press wakes it, so early attempts simply fail
    /// until it is back; only a disconnected peripheral is retried, so attempts
    /// cannot stack up behind one another.
    public static let reconnectInterval: TimeInterval = 2

    public var isConnected: Bool { target?.state == .connected }

    public override init() {
        super.init()
        // Delegate callbacks are delivered on the main run loop.
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public API

    public func startScan() {
        wantsScan = true
        guard state.isReady else {
            onEvent?(.log("Waiting for Bluetooth to become available…"))
            return
        }
        beginScan()
    }

    public func stopScan() {
        wantsScan = false
        if state.isReady {
            central.stopScan()
        }
    }

    public func connect(to id: UUID) {
        guard let peripheral = peripherals[id] else {
            onEvent?(.error("Unknown peripheral \(id.uuidString). Run a scan first."))
            return
        }
        stopScan()
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
        central.cancelPeripheralConnection(target)
    }

    /// Writes the Click V2 start command to the sync-RX characteristic.
    public func sendHandshake() {
        guard let peripheral = target, let syncRxCharacteristic else {
            onEvent?(.error("Cannot send handshake yet: characteristics are not ready."))
            return
        }
        let command = ZwiftClickCodec.clickV2StartCommand
        peripheral.writeValue(Data(command), for: syncRxCharacteristic, type: .withoutResponse)
        didSendHandshake = true
        onEvent?(.handshakeSent(command))
        // A link that just came up is a link worth keeping up — and the handshake
        // is itself a fresh session, so the first cycle can wait a full interval.
        startKeepAlive(holdNow: false)
        stopReconnecting()
    }

    /// Every how many cycles the log says so — ten minutes' worth at the default
    /// cadence.
    public static let keepAliveHeartbeat = 15

    // MARK: - Holding the puck

    /// Runs one keep-awake cycle: reset the puck, then start it again.
    ///
    /// A reset is what the reference implementation sends periodically, and the
    /// log shows the same effect from a fresh connection: every link that came up
    /// gave the puck a new 60-second window. Resetting over the existing link buys
    /// that window without dropping the connection.
    private func holdPuckAwake() {
        guard let peripheral = target, let syncRxCharacteristic else { return }
        peripheral.writeValue(Data(Self.resetCommand), for: syncRxCharacteristic, type: .withoutResponse)
        keepAliveCycles += 1

        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: Self.restartDelay, repeats: false) { [weak self] _ in
            self?.restartPuck()
        }

        // One line when it starts proves the mechanism is running; after that a
        // heartbeat, so a long ride does not bury the log. The puck's answers on
        // the indicating characteristic are the evidence it is working rather than
        // merely wired: the reset brings back a `ff 05 …`, the restart the `RideOn`
        // echo.
        if keepAliveCycles == 1 {
            onEvent?(.log("Keep-awake: reset + start every \(Int(keepAliveInterval)) s."))
        } else if keepAliveCycles % Self.keepAliveHeartbeat == 0 {
            onEvent?(.log("Keep-awake heartbeat: \(keepAliveCycles) resets."))
        }
    }

    /// Starts the puck again after a reset, which is the same write the handshake
    /// uses because a reset makes the puck stop.
    ///
    /// The Info-Request rides along: it is the documented answer to the puck's
    /// *standby*, even though on its own it does not hold the link.
    private func restartPuck() {
        restartTimer = nil
        guard let peripheral = target, let syncRxCharacteristic else { return }
        let command = ZwiftClickCodec.clickV2StartCommand
        peripheral.writeValue(Data(command), for: syncRxCharacteristic, type: .withoutResponse)
        peripheral.writeValue(Data(ZwiftClickCodec.infoRequest), for: syncRxCharacteristic, type: .withoutResponse)
    }

    /// Starts, or re-phases, the keep-awake timer.
    ///
    /// `holdNow` is for a policy that has just switched on, which may be well into
    /// an existing connection's window; a caller that has itself started a fresh
    /// session — the handshake — wants a full interval first instead.
    private func startKeepAlive(holdNow: Bool) {
        stopKeepAlive()
        guard keepsPuckAwake, isConnected else { return }
        keepAliveCycles = 0
        if holdNow { holdPuckAwake() }
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: keepAliveInterval, repeats: true) { [weak self] _ in
            self?.holdPuckAwake()
        }
    }

    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        restartTimer?.invalidate()
        restartTimer = nil
    }

    /// Retries the last puck by handle, which is the only way back to a device
    /// CoreBluetooth has already introduced: it reports each peripheral to
    /// `didDiscover` once, so scanning alone never finds a dropped puck again.
    ///
    /// A sleeping puck wakes on a button press and answers straight away, so this
    /// is also how the app recovers when a rider picks the controller up.
    private func startReconnecting() {
        guard reconnectTimer == nil, let id = lastTargetID, let peripheral = peripherals[id] else { return }
        guard peripheral.state != .connected else { return }
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

    private func retryConnection() {
        guard keepsPuckAwake, let id = lastTargetID, let peripheral = peripherals[id] else {
            stopReconnecting()
            return
        }
        if peripheral.state == .connected {
            stopReconnecting()
            return
        }
        // Only a genuinely disconnected peripheral is retried: a connect the
        // system is already waiting on stays pending until the puck advertises, so
        // asking again every tick would only stack up.
        guard peripheral.state == .disconnected else { return }
        target = peripheral
        central.connect(peripheral, options: nil)
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
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        onEvent?(.disconnected(error?.localizedDescription))
        target = nil
        connectedDevice = nil
        asyncCharacteristic = nil
        syncTxCharacteristic = nil
        syncRxCharacteristic = nil
        didSendHandshake = false
        stopKeepAlive()
        // The link is gone whatever happens next; if the puck is meant to be
        // held, retrying by handle is how it comes back without a rescan.
        if keepsPuckAwake {
            startReconnecting()
        } else {
            stopReconnecting()
        }
        if wantsScan { beginScan() }
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

        if notifyReady && indicateReady && !didSendHandshake {
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
        let decoded = ZwiftClickCodec.decode(bytes)
        onEvent?(.notification(characteristic: characteristic.uuid.uuidString, bytes: bytes, decoded: decoded))
    }

    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        onEvent?(.rssi(RSSI.intValue))
    }
}
