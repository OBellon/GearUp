import Foundation

/// Everything the rider can configure, in one value type.
///
/// A struct (rather than a store object) keeps SwiftUI bindings trivial:
/// `$controller.settings.gearCount` just works, and the controller persists the
/// whole value whenever it changes.
public struct GearUpSettings: Equatable, Codable {
    /// Gears in the local readout. MyWhoosh owns the trainer's resistance and
    /// shows its own gear, so this only drives GearUp's display.
    public var gearCount: Int
    /// Which OpenBikeControl transports to offer MyWhoosh.
    public var transportMode: TransportMode
    public var showInMenuBar: Bool
    public var shiftUpButton: RideButtonMask
    public var shiftDownButton: RideButtonMask

    public init(
        gearCount: Int = 12,
        transportMode: TransportMode = .both,
        showInMenuBar: Bool = true,
        shiftUpButton: RideButtonMask = .shiftUpRight,
        shiftDownButton: RideButtonMask = .b
    ) {
        self.gearCount = min(max(gearCount, 1), 30)
        self.transportMode = transportMode
        self.showInMenuBar = showInMenuBar
        self.shiftUpButton = shiftUpButton
        self.shiftDownButton = shiftDownButton
    }

    public var buttonMap: ButtonMap {
        ButtonMap(shiftUp: shiftUpButton, shiftDown: shiftDownButton)
    }

    public static let `default` = GearUpSettings()
}

/// Persists `GearUpSettings` in `UserDefaults` as JSON.
///
/// JSON rather than individual keys so the shape can change in a later phase
/// without stranding half of the old values behind.
public struct SettingsStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "gearup.settings") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> GearUpSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(GearUpSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    public func save(_ settings: GearUpSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
