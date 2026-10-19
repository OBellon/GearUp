import Foundation

/// Everything the rider can configure, in one value type.
///
/// A struct (rather than a store object) keeps SwiftUI bindings trivial:
/// `$controller.settings.gearCount` just works, and the controller persists the
/// whole value whenever it changes.
public struct GearUpSettings: Equatable, Codable {
    /// Gears in the local readout. MyWhoosh owns the trainer's resistance and
    /// shows its own gear, so this only drives GearUp's display. The default is
    /// MyWhoosh's own gear count, so the two numbers agree.
    public var gearCount: Int {
        didSet {
            gearCount = min(max(gearCount, Drivetrain.supportedGearRange.lowerBound), Drivetrain.supportedGearRange.upperBound)
            startingGear = min(startingGear, gearCount)
        }
    }
    /// The gear the readout starts in, and the gear `resetGear()` returns to.
    /// MyWhoosh starts every ride in the middle of its cassette.
    public var startingGear: Int {
        didSet {
            startingGear = min(max(startingGear, 1), gearCount)
        }
    }
    /// Which OpenBikeControl transports to offer MyWhoosh.
    public var transportMode: TransportMode
    public var showInMenuBar: Bool
    public var shiftUpButton: RideButtonMask
    public var shiftDownButton: RideButtonMask

    public init(
        gearCount: Int = Drivetrain.defaultGearCount,
        startingGear: Int = Drivetrain.defaultStartingGear,
        transportMode: TransportMode = .both,
        showInMenuBar: Bool = true,
        shiftUpButton: RideButtonMask = .shiftUpRight,
        shiftDownButton: RideButtonMask = .b
    ) {
        // Property observers do not run during initialisation, so the same
        // clamping the observers do is applied here by hand.
        let clampedCount = min(
            max(gearCount, Drivetrain.supportedGearRange.lowerBound),
            Drivetrain.supportedGearRange.upperBound
        )
        self.gearCount = clampedCount
        self.startingGear = min(max(startingGear, 1), clampedCount)
        self.transportMode = transportMode
        self.showInMenuBar = showInMenuBar
        self.shiftUpButton = shiftUpButton
        self.shiftDownButton = shiftDownButton
    }

    /// Decoding is deliberately tolerant, with one migration.
    ///
    /// The shape changed when the readout moved from 12 gears to MyWhoosh's 30,
    /// so a blob written before that has no `startingGear` key. Its `gearCount`
    /// was almost always the old default rather than a deliberate choice, so the
    /// two gear fields take the new defaults while every other preference —
    /// transport, menu bar, button map — is kept. Anything unreadable falls back
    /// to its own default rather than discarding the whole blob.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedGearCount = try container.decodeIfPresent(Int.self, forKey: .gearCount)
        let storedStartingGear = try container.decodeIfPresent(Int.self, forKey: .startingGear)
        let transportMode = try container.decodeIfPresent(TransportMode.self, forKey: .transportMode)
        let showInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .showInMenuBar)
        let shiftUpButton = try container.decodeIfPresent(RideButtonMask.self, forKey: .shiftUpButton)
        let shiftDownButton = try container.decodeIfPresent(RideButtonMask.self, forKey: .shiftDownButton)
        let writtenBeforeThirtyGears = storedStartingGear == nil

        self.init(
            gearCount: writtenBeforeThirtyGears
                ? Drivetrain.defaultGearCount
                : (storedGearCount ?? Drivetrain.defaultGearCount),
            startingGear: storedStartingGear ?? Drivetrain.defaultStartingGear,
            transportMode: transportMode ?? .both,
            showInMenuBar: showInMenuBar ?? true,
            shiftUpButton: shiftUpButton ?? .shiftUpRight,
            shiftDownButton: shiftDownButton ?? .b
        )
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
