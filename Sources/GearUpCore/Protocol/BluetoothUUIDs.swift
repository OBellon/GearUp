import Foundation

/// Bluetooth identifiers used by the Zwift Click V2 and by OpenBikeControl.
///
/// Zwift shipped two variants of the custom service:
/// - `00000001-19CA-4651-86E5-FA29DCDD09D1` on older firmware.
/// - `0000FC82-0000-1000-8000-00805F9B34FB` on newer firmware (Ride V2 era).
///
/// A Click V2 can expose either depending on its firmware, so the app always
/// checks both instead of assuming one.
public enum ZwiftUUID {
    public static let customServiceLegacy = "00000001-19CA-4651-86E5-FA29DCDD09D1"
    public static let customServiceModern = "0000FC82-0000-1000-8000-00805F9B34FB"

    public static let asyncCharacteristic = "00000002-19CA-4651-86E5-FA29DCDD09D1"
    public static let syncRxCharacteristic = "00000003-19CA-4651-86E5-FA29DCDD09D1"
    public static let syncTxCharacteristic = "00000004-19CA-4651-86E5-FA29DCDD09D1"

    /// Bluetooth SIG manufacturer identifier for Zwift, Inc. (0x094A).
    public static let manufacturerID: UInt16 = 2378

    public static let customServices = [customServiceLegacy, customServiceModern]

    /// Expands a Bluetooth SIG short UUID to its 128-bit base form.
    ///
    /// CoreBluetooth reports SIG-assigned UUIDs in their short form — a service
    /// created from `0000FC82-0000-1000-8000-00805F9B34FB` comes back as
    /// `FC82` — so both sides are canonicalised before comparing.
    public static func canonical(_ uuid: String) -> String {
        let upper = uuid.uppercased()
        switch upper.count {
        case 4: return "0000\(upper)-0000-1000-8000-00805F9B34FB"
        case 8: return "\(upper)-0000-1000-8000-00805F9B34FB"
        default: return upper
        }
    }

    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        canonical(lhs) == canonical(rhs)
    }

    public static func isCustomService(_ uuid: String) -> Bool {
        customServices.contains { matches($0, uuid) }
    }

    public static func isCustomService(_ uuid: UUID) -> Bool {
        isCustomService(uuid.uuidString)
    }

    public static func isCharacteristic(_ uuid: String, _ expected: String) -> Bool {
        matches(uuid, expected)
    }
}

/// OpenBikeControl GATT identifiers.
///
/// The protocol is deliberately tiny: one service and three characteristics.
/// MyWhoosh subscribes to `buttonState` and optionally writes `appInfo` and
/// `haptic` back to the controller.
public enum OpenBikeUUID {
    public static let service = "D273F680-D548-419D-B9D1-FA0472345229"
    public static let buttonState = "D273F681-D548-419D-B9D1-FA0472345229"
    public static let haptic = "D273F682-D548-419D-B9D1-FA0472345229"
    public static let appInfo = "D273F683-D548-419D-B9D1-FA0472345229"

    public static let deviceInformationService = "180A"
    public static let batteryService = "180F"
    public static let batteryLevelCharacteristic = "2A19"
}
