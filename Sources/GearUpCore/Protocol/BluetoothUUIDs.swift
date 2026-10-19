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

    public static func isCustomService(_ uuid: String) -> Bool {
        customServices.contains { $0.caseInsensitiveCompare(uuid) == .orderedSame }
    }

    public static func isCustomService(_ uuid: UUID) -> Bool {
        isCustomService(uuid.uuidString)
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
