import Foundation

/// Message types defined by the OpenBikeControl protocol.
public enum OpenBikeMessageType: UInt8 {
    case buttonState = 0x01
    case deviceStatus = 0x02
    case haptic = 0x03
    case appInfo = 0x04
}

/// Standard OpenBikeControl button identifiers.
///
/// Only the ones relevant to virtual shifting are given friendly names; the
/// rest are documented in the protocol specification.
public enum OpenBikeButton: UInt8, CaseIterable {
    case shiftUp = 0x01
    case shiftDown = 0x02
    case gearSet = 0x03
    case chainringSet = 0x04
    case cassetteSet = 0x05

    case navigateUp = 0x10
    case navigateDown = 0x11
    case navigateLeft = 0x12
    case navigateRight = 0x13
    case select = 0x14
    case back = 0x15
    case menu = 0x16
    case home = 0x17
    case steerLeft = 0x18
    case steerRight = 0x19
    case brake = 0x1A
    case steeringAngle = 0x1B

    case emote = 0x20
    case pushToTalk = 0x21
    case screenshot = 0x24

    case increaseDifficulty = 0x30
    case decreaseDifficulty = 0x31
    case skipInterval = 0x32
    case pause = 0x33
    case resume = 0x34
    case lap = 0x35
    case previousInterval = 0x36
    case uTurn = 0x37
    case changeMode = 0x38
    case takeABreak = 0x39
    case joinAnotherRider = 0x3A
    case changeRoute = 0x3B
    case cruiseControl = 0x3C

    case cameraView = 0x40
    case hudToggle = 0x44
    case mapToggle = 0x45
    case spectateRider = 0x46

    case powerUp1 = 0x50
    case powerUp2 = 0x51
    case powerUp3 = 0x52

    public var name: String {
        switch self {
        case .shiftUp: return "Shift Up"
        case .shiftDown: return "Shift Down"
        case .gearSet: return "Gear Set"
        case .chainringSet: return "Chainring Set"
        case .cassetteSet: return "Cassette Set"
        case .navigateUp: return "Navigate Up"
        case .navigateDown: return "Navigate Down"
        case .navigateLeft: return "Navigate Left"
        case .navigateRight: return "Navigate Right"
        case .select: return "Select"
        case .back: return "Back"
        case .menu: return "Menu"
        case .home: return "Home"
        case .steerLeft: return "Steer Left"
        case .steerRight: return "Steer Right"
        case .brake: return "Brake"
        case .steeringAngle: return "Steering Angle"
        case .emote: return "Emote"
        case .pushToTalk: return "Push to Talk"
        case .screenshot: return "Screenshot"
        case .increaseDifficulty: return "Increase Difficulty"
        case .decreaseDifficulty: return "Decrease Difficulty"
        case .skipInterval: return "Skip Interval"
        case .pause: return "Pause"
        case .resume: return "Resume"
        case .lap: return "Lap"
        case .previousInterval: return "Previous Interval"
        case .uTurn: return "U-Turn"
        case .changeMode: return "Change Mode"
        case .takeABreak: return "Take a Break"
        case .joinAnotherRider: return "Join Another Rider"
        case .changeRoute: return "Change Route"
        case .cruiseControl: return "Cruise Control"
        case .cameraView: return "Camera View"
        case .hudToggle: return "HUD Toggle"
        case .mapToggle: return "Map Toggle"
        case .spectateRider: return "Spectate Rider"
        case .powerUp1: return "Power-up 1"
        case .powerUp2: return "Power-up 2"
        case .powerUp3: return "Power-up 3"
        }
    }

    public static func name(for id: UInt8) -> String {
        OpenBikeButton(rawValue: id)?.name ?? String(format: "Unknown (0x%02X)", id)
    }
}

public struct OpenBikeButtonState: Equatable {
    public let buttonID: UInt8
    public let value: UInt8

    public init(buttonID: UInt8, value: UInt8) {
        self.buttonID = buttonID
        self.value = value
    }

    public init(_ button: OpenBikeButton, value: UInt8) {
        self.init(buttonID: button.rawValue, value: value)
    }

    public var isPressed: Bool { value != 0x00 }
    public var buttonName: String { OpenBikeButton.name(for: buttonID) }
}

public struct OpenBikeAppInfo: Equatable {
    public let appID: String
    public let appVersion: String
    /// `nil` means the app supports every button (button count == 0).
    public let supportedButtons: [UInt8]?

    public init(appID: String, appVersion: String, supportedButtons: [UInt8]?) {
        self.appID = appID
        self.appVersion = appVersion
        self.supportedButtons = supportedButtons
    }

    public var supportedButtonNames: [String] {
        guard let supportedButtons else { return ["All buttons"] }
        return supportedButtons.map { OpenBikeButton.name(for: $0) }
    }
}

public enum OpenBikeIncoming: Equatable {
    case buttonState([OpenBikeButtonState])
    case deviceStatus(battery: UInt8?, connected: Bool)
    case haptic(pattern: UInt8, duration: UInt8, intensity: UInt8)
    case appInfo(OpenBikeAppInfo)
    case unknown(type: UInt8, payload: [UInt8])
}

/// Encodes and decodes the OpenBikeControl wire format.
///
/// The same bytes are used over BLE and over the mDNS/TCP transport, so this
/// type is transport-agnostic on purpose.
public enum OpenBikeCodec {

    // MARK: - Encoding (controller -> app)

    /// Encodes a button state notification.
    ///
    /// Layout: `[0x01] [buttonID] [value] [buttonID] [value] ...`
    public static func encodeButtonState(_ states: [OpenBikeButtonState]) -> [UInt8] {
        var bytes: [UInt8] = [OpenBikeMessageType.buttonState.rawValue]
        for state in states {
            bytes.append(state.buttonID)
            bytes.append(state.value)
        }
        return bytes
    }

    /// Convenience for a single button transition.
    public static func encodeButton(_ button: OpenBikeButton, pressed: Bool) -> [UInt8] {
        encodeButtonState([OpenBikeButtonState(button, value: pressed ? 0x01 : 0x00)])
    }

    /// Press followed by release, as two separate notifications.
    ///
    /// MyWhoosh (and the protocol in general) expects every physical press as
    /// its own transition, so a tap is two messages rather than one combined
    /// state.
    public static func encodeButtonTap(_ button: OpenBikeButton) -> [[UInt8]] {
        [encodeButton(button, pressed: true), encodeButton(button, pressed: false)]
    }

    /// Encodes a device status message: `[0x02] [battery] [connected]`.
    public static func encodeDeviceStatus(battery: UInt8?, connected: Bool) -> [UInt8] {
        [
            OpenBikeMessageType.deviceStatus.rawValue,
            battery ?? 0xFF,
            connected ? 0x01 : 0x00,
        ]
    }

    /// Encodes a steering-angle update for button `0x1B`.
    ///
    /// - Parameter value: protocol-encoded angle in 0.5° steps, with `0x80`
    ///   meaning straight ahead.
    public static func encodeSteeringAngle(_ value: UInt8) -> [UInt8] {
        encodeButtonState([OpenBikeButtonState(buttonID: OpenBikeButton.steeringAngle.rawValue, value: value)])
    }

    // MARK: - Decoding (app -> controller)

    public static func decodeAppInfo(_ bytes: [UInt8]) -> OpenBikeAppInfo? {
        guard bytes.count >= 4, bytes[0] == OpenBikeMessageType.appInfo.rawValue else { return nil }
        var index = 1
        let version = bytes[index]
        index += 1
        guard version == 0x01 else { return nil }

        guard let appIDLength = readLength(bytes, &index) else { return nil }
        guard index + appIDLength <= bytes.count else { return nil }
        let appID = String(decoding: bytes[index..<(index + appIDLength)], as: UTF8.self)
        index += appIDLength

        guard let appVersionLength = readLength(bytes, &index) else { return nil }
        guard index + appVersionLength <= bytes.count else { return nil }
        let appVersion = String(decoding: bytes[index..<(index + appVersionLength)], as: UTF8.self)
        index += appVersionLength

        guard let buttonCount = readLength(bytes, &index) else { return nil }
        if buttonCount == 0 {
            return OpenBikeAppInfo(appID: appID, appVersion: appVersion, supportedButtons: nil)
        }
        guard index + buttonCount <= bytes.count else { return nil }
        let buttons = Array(bytes[index..<(index + buttonCount)])
        return OpenBikeAppInfo(appID: appID, appVersion: appVersion, supportedButtons: buttons)
    }

    public static func decodeHaptic(_ bytes: [UInt8]) -> OpenBikeIncoming? {
        guard bytes.count >= 4, bytes[0] == OpenBikeMessageType.haptic.rawValue else { return nil }
        return .haptic(pattern: bytes[1], duration: bytes[2], intensity: bytes[3])
    }

    public static func decodeButtonState(_ bytes: [UInt8]) -> [OpenBikeButtonState]? {
        guard let first = bytes.first, first == OpenBikeMessageType.buttonState.rawValue else { return nil }
        guard (bytes.count - 1) % 2 == 0 else { return nil }
        var states: [OpenBikeButtonState] = []
        var index = 1
        while index + 1 < bytes.count {
            states.append(OpenBikeButtonState(buttonID: bytes[index], value: bytes[index + 1]))
            index += 2
        }
        return states
    }

    /// Decodes a complete message that is already in memory (as opposed to a
    /// streamed TCP payload, see `OpenBikeStreamDecoder`).
    public static func decode(_ bytes: [UInt8]) -> OpenBikeIncoming? {
        guard let type = bytes.first else { return nil }
        switch type {
        case OpenBikeMessageType.buttonState.rawValue:
            guard let states = decodeButtonState(bytes) else { return nil }
            return .buttonState(states)
        case OpenBikeMessageType.deviceStatus.rawValue:
            guard bytes.count >= 3 else { return nil }
            let battery = bytes[1] == 0xFF ? nil : bytes[1]
            return .deviceStatus(battery: battery, connected: bytes[2] == 0x01)
        case OpenBikeMessageType.haptic.rawValue:
            return decodeHaptic(bytes)
        case OpenBikeMessageType.appInfo.rawValue:
            guard let info = decodeAppInfo(bytes) else { return nil }
            return .appInfo(info)
        default:
            return .unknown(type: type, payload: Array(bytes.dropFirst()))
        }
    }

    // MARK: - Stream framing

    /// Total length of the app-info message at the start of `bytes`, or `nil`
    /// while the header field it stops at has not arrived yet.
    ///
    /// The protocol has no length prefix, so a stream consumer has to walk the
    /// self-describing fields of an app-info message to find where it ends.
    public static func appInfoMessageLength(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4, bytes[0] == OpenBikeMessageType.appInfo.rawValue else { return nil }
        var index = 2 // type + version
        guard let appIDLength = readLength(bytes, &index) else { return nil }
        index += appIDLength
        guard index < bytes.count else { return nil }
        guard let appVersionLength = readLength(bytes, &index) else { return nil }
        index += appVersionLength
        guard index < bytes.count else { return nil }
        guard let buttonCount = readLength(bytes, &index) else { return nil }
        index += buttonCount
        guard index <= bytes.count else { return nil }
        return index
    }

    /// Reassembles OpenBikeControl messages from a TCP byte stream.
    ///
    /// The protocol has no explicit length prefix. Message types that an app
    /// sends to a controller are either fixed-size (`0x03`) or self-describing
    /// (`0x04`, whose length fields are parsed here). Button-state messages
    /// from an app are not expected, so they are surfaced once the buffer has
    /// settled.
    public struct StreamDecoder {
        private var buffer: [UInt8] = []

        public init() {}

        public mutating func append(_ bytes: [UInt8]) -> [OpenBikeIncoming] {
            buffer.append(contentsOf: bytes)
            var messages: [OpenBikeIncoming] = []

            while true {
                guard let type = buffer.first else { break }

                switch type {
                case OpenBikeMessageType.haptic.rawValue:
                    guard buffer.count >= 4 else { return messages }
                    let message = Array(buffer.prefix(4))
                    buffer.removeFirst(4)
                    if let decoded = OpenBikeCodec.decodeHaptic(message) {
                        messages.append(decoded)
                    }

                case OpenBikeMessageType.appInfo.rawValue:
                    guard let total = OpenBikeCodec.appInfoMessageLength(buffer) else {
                        // Not enough bytes yet, or malformed. A malformed
                        // message cannot be resynchronised safely; drop the
                        // leading byte and let the next loop try again.
                        if buffer.count > 512 {
                            buffer.removeFirst()
                            continue
                        }
                        return messages
                    }
                    guard buffer.count >= total else { return messages }
                    let message = Array(buffer.prefix(total))
                    buffer.removeFirst(total)
                    if let info = OpenBikeCodec.decodeAppInfo(message) {
                        messages.append(.appInfo(info))
                    }

                case OpenBikeMessageType.deviceStatus.rawValue:
                    guard buffer.count >= 3 else { return messages }
                    let message = Array(buffer.prefix(3))
                    buffer.removeFirst(3)
                    if let decoded = OpenBikeCodec.decode(message) {
                        messages.append(decoded)
                    }

                case OpenBikeMessageType.buttonState.rawValue:
                    // Button states are variable-length and only meaningful as
                    // a complete notification. Without a length prefix there is
                    // no safe way to split them in a stream; treat the whole
                    // buffer as one message once the peer pauses.
                    let message = buffer
                    buffer.removeAll()
                    if let states = OpenBikeCodec.decodeButtonState(message) {
                        messages.append(.buttonState(states))
                    }

                default:
                    buffer.removeFirst()
                    messages.append(.unknown(type: type, payload: []))
                }
            }

            return messages
        }

        public mutating func reset() {
            buffer.removeAll()
        }
    }

    // MARK: - Private helpers

    private static func readLength(_ bytes: [UInt8], _ index: inout Int) -> Int? {
        guard index < bytes.count else { return nil }
        let value = Int(bytes[index])
        index += 1
        return value
    }
}
