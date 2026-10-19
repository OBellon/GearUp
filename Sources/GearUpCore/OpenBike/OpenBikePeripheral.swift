import Foundation
import CoreBluetooth

/// OpenBikeControl over Bluetooth LE: GearUp acts as the peripheral and a
/// trainer app connects to it as the central.
///
/// The GATT layout mirrors the reference implementation:
///
/// - `180A` Device Information — manufacturer `GearUp`, serial `1337`,
///   hardware and firmware revisions, all read-only.
/// - `180F` Battery — `2A19` readable and notifying, reporting 100 %.
/// - `d273f680…` OpenBikeControl — `…81` button state (notify), `…83` app info
///   (write), `…82` haptic (write, ignored).
///
/// Notifications are queued rather than dropped: `updateValue(_:for:)` reports
/// back that the transmit queue is full, and a shift that silently disappeared
/// would leave the rider wondering why the gear did not change.
public final class OpenBikePeripheral: NSObject, OpenBikeTransport {

    public static let localName = "GearUp"

    // The two standard services are spelled out in full rather than as "180A"
    // and "180F": in the short form CoreBluetooth refuses to publish them ("The
    // specified UUID is not allowed for this operation"), while the very same
    // UUID written out in 128 bits is accepted. Without them a BLE client would
    // only find the OpenBikeControl service.
    private static let deviceInformationService = "0000180A-0000-1000-8000-00805F9B34FB"
    private static let batteryService = "0000180F-0000-1000-8000-00805F9B34FB"
    private static let batteryLevelCharacteristic = "2A19"
    private static let manufacturerName = "2A29"
    private static let serialNumber = "2A25"
    private static let hardwareRevision = "2A27"
    private static let firmwareRevision = "2A26"

    private static let batteryLevel: UInt8 = 100
    private static let serviceCount = 3

    public let kind: OpenBikeTransportKind = .bluetooth
    public weak var delegate: OpenBikeTransportDelegate?

    public private(set) var status: OpenBikeStatus = .off {
        didSet {
            guard status != oldValue else { return }
            delegate?.transportDidChangeStatus(self)
        }
    }

    public private(set) var appInfo: OpenBikeAppInfo?

    private var manager: CBPeripheralManager?
    private var buttonStateCharacteristic: CBMutableCharacteristic?
    private var addedServices = 0
    private var wantsAdvertising = false

    /// Values served for read requests, keyed by uppercased UUID string.
    private var readableValues: [String: Data] = [:]
    private var lastNotifiedValue = Data()

    private var assembler = OpenBikeAppInfoReassembler()
    private var subscribers: [UUID: String] = [:]

    private var pendingNotifications: [[UInt8]] = []
    private var canSendNotifications = true

    public override init() {
        super.init()
    }

    // MARK: - Lifecycle

    public func start() {
        guard manager == nil else { return }
        status = .starting
        wantsAdvertising = true
        log("Starting the Bluetooth peripheral…")
        // A nil queue delivers delegate callbacks on the main queue, which is
        // where the rest of GearUp lives.
        manager = CBPeripheralManager(delegate: self, queue: nil)
        log("Bluetooth peripheral created.")
    }

    public func stop() {
        wantsAdvertising = false
        manager?.stopAdvertising()
        manager?.removeAllServices()
        manager = nil
        buttonStateCharacteristic = nil
        addedServices = 0
        subscribers.removeAll()
        pendingNotifications.removeAll()
        canSendNotifications = true
        appInfo = nil
        assembler.reset()
        status = .off
    }

    // MARK: - Sending

    public func send(_ states: [OpenBikeButtonState]) {
        let bytes = OpenBikeCodec.encodeButtonState(states)
        guard manager != nil else {
            log("Cannot send \(bytes.hexString): the Bluetooth peripheral is not running.", level: .warning)
            return
        }
        guard !subscribers.isEmpty else {
            log("Cannot send \(bytes.hexString): no app has subscribed yet.", level: .warning)
            return
        }
        log("→ \(bytes.hexString)")
        pendingNotifications.append(bytes)
        flushNotifications()
    }

    private func flushNotifications() {
        guard let manager, let characteristic = buttonStateCharacteristic else { return }
        guard canSendNotifications else { return }

        while let next = pendingNotifications.first {
            let delivered = manager.updateValue(Data(next), for: characteristic, onSubscribedCentrals: nil)
            if delivered {
                pendingNotifications.removeFirst()
            } else {
                // The transmit queue is full; CoreBluetooth calls
                // peripheralManagerIsReady(toUpdateSubscribers:) when it drains.
                canSendNotifications = false
                return
            }
        }
    }

    // MARK: - GATT

    private func publishServices() {
        guard let manager else { return }
        manager.removeAllServices()
        addedServices = 0
        readableValues.removeAll()

        readableValues[Self.manufacturerName] = Data(Self.localName.utf8)
        readableValues[Self.serialNumber] = Data("1337".utf8)
        readableValues[Self.hardwareRevision] = Data("1.0".utf8)
        readableValues[Self.firmwareRevision] = Data("0.1.0".utf8)
        readableValues[Self.batteryLevelCharacteristic] = Data([Self.batteryLevel])

        let deviceInformation = CBMutableService(
            type: CBUUID(string: Self.deviceInformationService),
            primary: true
        )
        deviceInformation.characteristics = [
            Self.readOnlyCharacteristic(Self.manufacturerName, "GearUp"),
            Self.readOnlyCharacteristic(Self.serialNumber, "1337"),
            Self.readOnlyCharacteristic(Self.hardwareRevision, "1.0"),
            Self.readOnlyCharacteristic(Self.firmwareRevision, "0.1.0"),
        ]

        let battery = CBMutableCharacteristic(
            type: CBUUID(string: Self.batteryLevelCharacteristic),
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )
        let batteryService = CBMutableService(type: CBUUID(string: Self.batteryService), primary: true)
        batteryService.characteristics = [battery]

        let buttonState = CBMutableCharacteristic(
            type: CBUUID(string: OpenBikeUUID.buttonState),
            properties: [.notify],
            value: nil,
            permissions: [.readable]
        )
        self.buttonStateCharacteristic = buttonState

        let appInfoCharacteristic = CBMutableCharacteristic(
            type: CBUUID(string: OpenBikeUUID.appInfo),
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.readable, .writeable]
        )

        let hapticCharacteristic = CBMutableCharacteristic(
            type: CBUUID(string: OpenBikeUUID.haptic),
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )

        let openBikeControl = CBMutableService(type: CBUUID(string: OpenBikeUUID.service), primary: true)
        openBikeControl.characteristics = [buttonState, appInfoCharacteristic, hapticCharacteristic]

        for service in [deviceInformation, batteryService, openBikeControl] {
            manager.add(service)
        }
    }

    private static func readOnlyCharacteristic(_ uuid: String, _ value: String) -> CBMutableCharacteristic {
        CBMutableCharacteristic(
            type: CBUUID(string: uuid),
            properties: [.read],
            value: nil,
            permissions: [.readable]
        )
    }

    private func startAdvertising() {
        guard let manager, manager.state == .poweredOn, wantsAdvertising, !manager.isAdvertising else { return }
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: OpenBikeUUID.service)],
            CBAdvertisementDataLocalNameKey: Self.localName,
        ])
    }

    private func updateConnectionStatus() {
        if subscribers.isEmpty {
            status = manager?.isAdvertising == true ? .waiting : .starting
        } else {
            let names = subscribers.values.sorted()
            status = .connected(peer: names.count == 1 ? names[0] : "\(names.count) apps")
        }
    }

    private static func describe(_ central: CBCentral) -> String {
        "Bluetooth app \(central.identifier.uuidString.prefix(8))"
    }

    private func log(_ message: String, level: LogEntry.Level = .info) {
        delegate?.transport(self, log: message, level: level)
    }
}

// MARK: - CBPeripheralManagerDelegate

extension OpenBikePeripheral: CBPeripheralManagerDelegate {

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            log("Bluetooth is available.")
            publishServices()
        case .poweredOff:
            status = .failed("Bluetooth is turned off. Enable it in System Settings.")
        case .unauthorized:
            status = .failed(
                "Bluetooth permission denied. Grant it in System Settings → Privacy & Security → Bluetooth."
            )
        case .unsupported:
            status = .failed("This Mac does not support Bluetooth Low Energy.")
        case .resetting:
            status = .starting
        default:
            status = .starting
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            // Seen when the standard services are added with their UUID in the
            // short form (see `deviceInformationService` above). A service that
            // does not make it into the GATT table is not fatal: the shifts
            // travel over the OpenBikeControl service, so this is reported and
            // skipped rather than treated as a broken transport.
            log(
                "Could not publish \(service.uuid.uuidString) (\(error.localizedDescription)); "
                    + "BLE clients will not see that service.",
                level: .warning
            )
        }
        addedServices += 1
        if addedServices >= Self.serviceCount {
            startAdvertising()
        }
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            log("Could not advertise: \(error.localizedDescription)", level: .error)
            status = .failed(error.localizedDescription)
            return
        }
        log("Advertising as “\(Self.localName)” with the OpenBikeControl service.")
        updateConnectionStatus()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let key = request.characteristic.uuid.uuidString.uppercased()
        let value = readableValues[key] ?? lastNotifiedValue

        guard request.offset <= value.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = value.subdata(in: request.offset..<value.count)
        peripheral.respond(to: request, withResult: .success)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            let key = request.characteristic.uuid.uuidString.uppercased()
            let bytes = request.value.map { [UInt8]($0) } ?? []

            switch key {
            case OpenBikeUUID.appInfo.uppercased():
                log("App info write: \(bytes.hexString)")
                if let info = assembler.offer(bytes) {
                    appInfo = info
                    log("\(info.appID) \(info.appVersion) supports \(info.supportedButtonNames.joined(separator: ", ")).")
                    delegate?.transport(self, didReceiveAppInfo: info)
                } else if let problem = assembler.lastProblem {
                    log(problem, level: .warning)
                }

            case OpenBikeUUID.haptic.uppercased():
                log("Ignoring haptic request: \(bytes.hexString)")

            default:
                log("Ignoring write to \(key): \(bytes.hexString)", level: .warning)
            }
        }
        // CoreBluetooth requires exactly one response per request batch.
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        let key = characteristic.uuid.uuidString.uppercased()
        guard key == OpenBikeUUID.buttonState.uppercased() else {
            log("\(Self.describe(central)) subscribed to \(key).")
            return
        }

        let name = Self.describe(central)
        subscribers[central.identifier] = name
        log("\(name) subscribed to button notifications.")
        updateConnectionStatus()
        delegate?.transport(self, didConnect: name)
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        let key = characteristic.uuid.uuidString.uppercased()
        guard key == OpenBikeUUID.buttonState.uppercased() else { return }

        let name = subscribers.removeValue(forKey: central.identifier) ?? Self.describe(central)
        log("\(name) unsubscribed.")
        updateConnectionStatus()
        delegate?.transport(self, didDisconnect: name)
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        canSendNotifications = true
        flushNotifications()
    }
}
