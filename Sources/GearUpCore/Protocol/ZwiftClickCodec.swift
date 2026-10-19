import Foundation

/// A minimal protobuf wire reader.
///
/// The Zwift controllers send plain serialized protocol buffers without a
/// `.proto` schema available to us, so GearUp hand-parses the few fields it
/// needs. This keeps the project dependency-free.
public struct ProtoReader {
    public let bytes: [UInt8]
    public private(set) var index: Int = 0

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public var isAtEnd: Bool { index >= bytes.count }

    public mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    public mutating func readKey() -> (field: Int, wire: Int)? {
        guard let key = readVarint() else { return nil }
        return (field: Int(key >> 3), wire: Int(key & 0x07))
    }

    public mutating func readLengthDelimited() -> [UInt8]? {
        guard let length = readVarint() else { return nil }
        let count = Int(length)
        guard count >= 0, index + count <= bytes.count else { return nil }
        let slice = Array(bytes[index..<(index + count)])
        index += count
        return slice
    }

    public mutating func readFixed32() -> UInt32? {
        guard index + 4 <= bytes.count else { return nil }
        let value = UInt32(bytes[index])
            | (UInt32(bytes[index + 1]) << 8)
            | (UInt32(bytes[index + 2]) << 16)
            | (UInt32(bytes[index + 3]) << 24)
        index += 4
        return value
    }

    public mutating func readFixed64() -> UInt64? {
        guard index + 8 <= bytes.count else { return nil }
        var value: UInt64 = 0
        for offset in 0..<8 {
            value |= UInt64(bytes[index + offset]) << (8 * UInt64(offset))
        }
        index += 8
        return value
    }

    /// Advances past a field whose wire type we do not care about.
    public mutating func skip(wire: Int) -> Bool {
        switch wire {
        case 0: return readVarint() != nil
        case 1: return readFixed64() != nil
        case 2: return readLengthDelimited() != nil
        case 5: return readFixed32() != nil
        default: return false
        }
    }

    /// Decodes a protobuf `sint32` (zig-zag encoded).
    public static func zigZag(_ value: UInt64) -> Int32 {
        let n = UInt32(truncatingIfNeeded: value)
        return Int32(bitPattern: (n >> 1) ^ (~(n & 1) &+ 1))
    }
}

/// Bit positions used by the Zwift Ride / Click V2 keypad report.
///
/// These were confirmed against a real Click V2 (right puck) by pressing each
/// button and reading the resulting `buttonMap`. Note that Zwift's published
/// `RideButtonMask` protobuf enum is **not** the wire mask: its values skip
/// `0x80`, while the hardware assigns bits in enum order. `Z` really is `0x80`
/// and `+` (shift up right) really is `0x1000`.
///
/// The logic is inverted: a bit set to `1` means the button is **released**,
/// a bit set to `0` means it is **pressed**. Bits above 15 are always set.
/// An idle right Click V2 reports `0xFFFFFFFF`; a Zwift Ride reports
/// `0x0FFFFFFF`.
public enum RideButtonMask: UInt32, CaseIterable, Codable {
    case left = 0x0001
    case up = 0x0002
    case right = 0x0004
    case down = 0x0008
    case a = 0x0010
    case b = 0x0020
    case y = 0x0040
    case z = 0x0080
    case shiftUpLeft = 0x0100
    case shiftDownLeft = 0x0200
    case powerUpLeft = 0x0400
    case onOffLeft = 0x0800
    case shiftUpRight = 0x1000
    case shiftDownRight = 0x2000
    case powerUpRight = 0x4000
    case onOffRight = 0x8000

    /// Index of the bit this mask refers to, e.g. `z` → 7.
    public var bit: Int {
        Int(rawValue.trailingZeroBitCount)
    }

    public var name: String {
        switch self {
        case .left: return "left"
        case .up: return "up"
        case .right: return "right"
        case .down: return "down"
        case .a: return "a"
        case .b: return "b"
        case .y: return "y"
        case .z: return "z"
        case .shiftUpLeft: return "shiftUpLeft"
        case .shiftDownLeft: return "shiftDownLeft"
        case .powerUpLeft: return "powerUpLeft"
        case .onOffLeft: return "onOffLeft"
        case .shiftUpRight: return "shiftUpRight"
        case .shiftDownRight: return "shiftDownRight"
        case .powerUpRight: return "powerUpRight"
        case .onOffRight: return "onOffRight"
        }
    }

    /// The name a rider sees.
    ///
    /// The right puck's buttons are labelled the way they are printed on the
    /// hardware, which is what the settings screen shows; the rest fall back to
    /// the protocol name.
    public var displayName: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .y: return "Y"
        case .z: return "Z"
        case .shiftUpRight: return "+"
        case .shiftDownRight: return "−"
        case .powerUpRight: return "power-up"
        case .onOffRight: return "on/off"
        case .left, .up, .right, .down,
             .shiftUpLeft, .shiftDownLeft, .powerUpLeft, .onOffLeft:
            return name
        }
    }

    /// The buttons on the right Click V2 puck, in the order they sit on the
    /// hardware.
    ///
    /// Confirmed against real hardware in Phase 0: the right puck reports these
    /// five and nothing else, so they are the ones a rider can map. The other
    /// masks belong to a Zwift Ride or to the left puck, which v1 does not use.
    public static let clickV2RightPuck: [RideButtonMask] = [.y, .z, .a, .b, .shiftUpRight]
}

public struct RideAnalogKeyPress: Equatable {
    public let location: UInt64
    public let value: Int32

    public init(location: UInt64, value: Int32) {
        self.location = location
        self.value = value
    }

    public var locationName: String {
        switch location {
        case 0: return "left"
        case 1: return "right"
        case 2: return "unknown2"
        case 3: return "unknown3"
        default: return "location\(location)"
        }
    }
}

/// The keypad report sent by Zwift Ride and Click V2 under message type `0x23`.
public struct RideKeyPadStatus: Equatable {
    public var buttonMap: UInt32
    public var analogPaddles: [RideAnalogKeyPress]

    public init(buttonMap: UInt32, analogPaddles: [RideAnalogKeyPress] = []) {
        self.buttonMap = buttonMap
        self.analogPaddles = analogPaddles
    }

    public static func decode(_ bytes: [UInt8]) -> RideKeyPadStatus? {
        var reader = ProtoReader(bytes)
        var buttonMap: UInt32?
        var paddles: [RideAnalogKeyPress] = []

        while let key = reader.readKey() {
            switch (key.field, key.wire) {
            case (1, 0):
                guard let value = reader.readVarint() else { return nil }
                buttonMap = UInt32(truncatingIfNeeded: value)
            case (2, 2):
                guard let nested = reader.readLengthDelimited() else { return nil }
                paddles.append(contentsOf: decodeAnalogGroup(nested))
            case (3, 2):
                // Some firmware revisions repeat the analog entries at field 3.
                guard let nested = reader.readLengthDelimited() else { return nil }
                if let paddle = decodeAnalogPress(nested) {
                    paddles.append(paddle)
                }
            default:
                guard reader.skip(wire: key.wire) else { return nil }
            }
        }

        guard let buttonMap else { return nil }
        return RideKeyPadStatus(buttonMap: buttonMap, analogPaddles: paddles)
    }

    private static func decodeAnalogGroup(_ bytes: [UInt8]) -> [RideAnalogKeyPress] {
        var reader = ProtoReader(bytes)
        var result: [RideAnalogKeyPress] = []
        while let key = reader.readKey() {
            if key.field == 1, key.wire == 2, let nested = reader.readLengthDelimited() {
                if let paddle = decodeAnalogPress(nested) {
                    result.append(paddle)
                }
            } else if !reader.skip(wire: key.wire) {
                break
            }
        }
        return result
    }

    private static func decodeAnalogPress(_ bytes: [UInt8]) -> RideAnalogKeyPress? {
        var reader = ProtoReader(bytes)
        var location: UInt64?
        var value: Int32?
        while let key = reader.readKey() {
            switch (key.field, key.wire) {
            case (1, 0):
                location = reader.readVarint()
            case (2, 0):
                guard let raw = reader.readVarint() else { return nil }
                value = ProtoReader.zigZag(raw)
            default:
                guard reader.skip(wire: key.wire) else { return nil }
            }
        }
        guard let location, let value else { return nil }
        return RideAnalogKeyPress(location: location, value: value)
    }

    /// Bit indices whose bit is `0`, i.e. the buttons currently pressed.
    public var pressedBitIndices: [Int] {
        (0..<32).filter { buttonMap & (UInt32(1) << UInt32($0)) == 0 }
    }

    /// Named buttons currently pressed, using the Ride bit layout.
    public var pressedButtons: [RideButtonMask] {
        RideButtonMask.allCases.filter { buttonMap & $0.rawValue == 0 }
    }
}

/// The two-button report sent by the original Zwift Click under type `0x37`.
///
/// The protobuf enum is inverted compared to intuition: `ON` is `0` and means
/// pressed, `OFF` is `1` and means released. Presence is tracked separately so
/// an omitted field is not mistaken for a press.
public struct ClickKeyPadStatus: Equatable {
    public var plusPressed: Bool?
    public var minusPressed: Bool?

    public init(plusPressed: Bool?, minusPressed: Bool?) {
        self.plusPressed = plusPressed
        self.minusPressed = minusPressed
    }

    public static func decode(_ bytes: [UInt8]) -> ClickKeyPadStatus? {
        var reader = ProtoReader(bytes)
        var plus: Bool?
        var minus: Bool?
        while let key = reader.readKey() {
            switch (key.field, key.wire) {
            case (1, 0):
                guard let value = reader.readVarint() else { return nil }
                plus = value == 0 // ON
            case (2, 0):
                guard let value = reader.readVarint() else { return nil }
                minus = value == 0 // ON
            default:
                guard reader.skip(wire: key.wire) else { return nil }
            }
        }
        return ClickKeyPadStatus(plusPressed: plus, minusPressed: minus)
    }
}

/// Message type codes seen on the Zwift custom service.
///
/// These are the `Opcode` values from Zwift's protocol. GearUp only needs the
/// ones the controllers actually emit.
public enum ZwiftMessageType: UInt8 {
    case empty = 0x15
    case batteryNotification = 0x19
    case batteryStatus = 0x1A
    case controllerNotification = 0x23
    case logData = 0x2A
    case clickNotification = 0x37
    case getResponse = 0x3C
    case statusResponse = 0x3E
    case rideOn = 0x52
    case disconnect = 0xFE

    public var name: String {
        switch self {
        case .empty: return "EMPTY"
        case .batteryNotification: return "BATTERY_NOTIF"
        case .batteryStatus: return "BATTERY_STATUS"
        case .controllerNotification: return "CONTROLLER_NOTIFICATION"
        case .logData: return "LOG_DATA"
        case .clickNotification: return "CLICK_NOTIFICATION"
        case .getResponse: return "GET_RESPONSE"
        case .statusResponse: return "STATUS_RESPONSE"
        case .rideOn: return "RIDE_ON"
        case .disconnect: return "DISCONNECT"
        }
    }
}

public enum ZwiftNotification: Equatable {
    case rideKeyPad(RideKeyPadStatus)
    case clickKeyPad(ClickKeyPadStatus)
    /// Battery percentage plus the raw charging state, when reported.
    case battery(level: Int, chargingState: Int?, raw: [UInt8])
    /// The device echoing `RideOn` back, which acknowledges the handshake.
    case handshake([UInt8])
    case empty
    case disconnect
    case deviceInfo([UInt8])
    case unknown(type: UInt8, payload: [UInt8])
}

/// Decodes notifications coming from a Zwift Click / Ride controller.
public enum ZwiftClickCodec {

    /// `"RideOn"` prefixed with the Click V2 start marker. Writing this to the
    /// sync-RX characteristic starts the button stream.
    public static let clickV2StartCommand: [UInt8] = Array("RideOn".utf8) + [0x02, 0x03]

    /// Plain `"RideOn"`, used by older controllers.
    public static let rideOn: [UInt8] = Array("RideOn".utf8)

    public static func decode(type: UInt8, payload: [UInt8]) -> ZwiftNotification {
        switch ZwiftMessageType(rawValue: type) {
        case .controllerNotification:
            if let status = RideKeyPadStatus.decode(payload) {
                return .rideKeyPad(status)
            }
            return .unknown(type: type, payload: payload)

        case .clickNotification:
            if let status = ClickKeyPadStatus.decode(payload) {
                return .clickKeyPad(status)
            }
            return .unknown(type: type, payload: payload)

        case .batteryNotification, .batteryStatus:
            // Both messages are protobufs of the same shape: field 1 is a
            // charging state enum, field 2 is the percentage.
            return decodeBattery(type: type, payload: payload)

        case .empty:
            return .empty

        case .disconnect:
            return .disconnect

        case .getResponse:
            return .deviceInfo(payload)

        case .logData, .statusResponse, .rideOn:
            return .unknown(type: type, payload: payload)

        case nil:
            return .unknown(type: type, payload: payload)
        }
    }

    private static func decodeBattery(type: UInt8, payload: [UInt8]) -> ZwiftNotification {
        var reader = ProtoReader(payload)
        var level: Int?
        var chargingState: Int?
        while let key = reader.readKey() {
            switch (key.field, key.wire) {
            case (1, 0):
                chargingState = reader.readVarint().map(Int.init)
            case (2, 0):
                level = reader.readVarint().map(Int.init)
            default:
                guard reader.skip(wire: key.wire) else {
                    return .battery(level: -1, chargingState: chargingState, raw: payload)
                }
            }
        }
        return .battery(level: level ?? -1, chargingState: chargingState, raw: payload)
    }

    /// Decodes a complete characteristic value, where the first byte is the
    /// message type.
    ///
    /// The `RideOn` handshake acknowledgement is checked first because its
    /// first byte is the ASCII `R` (0x52), which would otherwise be read as an
    /// opcode.
    public static func decode(_ bytes: [UInt8]) -> ZwiftNotification? {
        guard !bytes.isEmpty else { return nil }
        if bytes.starts(with: rideOn) {
            return .handshake(bytes)
        }
        return decode(type: bytes[0], payload: Array(bytes.dropFirst()))
    }

    /// Human-readable summary used by the diagnostic log.
    public static func describe(_ notification: ZwiftNotification) -> String {
        switch notification {
        case .rideKeyPad(let status):
            let pressedNames = status.pressedButtons.map(\.name).joined(separator: ", ")
            var lines = [
                "type=0x23 CONTROLLER_NOTIFICATION",
                String(format: "buttonMap=0x%08X pressedBits=%@", status.buttonMap, "\(status.pressedBitIndices)"),
                "pressed=[\(pressedNames.isEmpty ? "none" : pressedNames)]",
            ]
            if !status.analogPaddles.isEmpty {
                let analog = status.analogPaddles
                    .map { "\($0.locationName)=\($0.value)" }
                    .joined(separator: " ")
                lines.append("analog: \(analog)")
            }
            return lines.joined(separator: "\n")

        case .clickKeyPad(let status):
            return [
                "type=0x37 CLICK_NOTIFICATION",
                "plus=\(status.plusPressed.map(String.init) ?? "unchanged") minus=\(status.minusPressed.map(String.init) ?? "unchanged")",
            ].joined(separator: "\n")

        case .battery(let level, let chargingState, let raw):
            let state = chargingState.map { " chargingState=\($0)" } ?? ""
            return "type=battery level=\(level)%\(state) raw=\(raw.hexString)"

        case .handshake(let bytes):
            return "handshake acknowledged by device: \(bytes.hexString)"

        case .empty:
            return "type=0x15 EMPTY (keep-alive)"

        case .disconnect:
            return "type=0xFE DISCONNECT"

        case .deviceInfo(let payload):
            return "type=0x3C GET_RESPONSE payload=\(payload.hexString)"

        case .unknown(let type, let payload):
            let name = ZwiftMessageType(rawValue: type).map { " (\($0.name))" } ?? ""
            return String(format: "type=0x%02X UNKNOWN%@ payload=%@", type, name, payload.hexString)
        }
    }
}
