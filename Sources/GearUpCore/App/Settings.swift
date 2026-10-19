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
    /// Which button does what, in the puck's own button order.
    public var buttonAssignments: [ButtonAssignment]

    public init(
        gearCount: Int = Drivetrain.defaultGearCount,
        startingGear: Int = Drivetrain.defaultStartingGear,
        transportMode: TransportMode = .both,
        showInMenuBar: Bool = true,
        buttonAssignments: [ButtonAssignment] = ButtonAssignment.defaults
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
        self.buttonAssignments = GearUpSettings.normalised(buttonAssignments)
    }

    /// Decoding is deliberately tolerant, with one migration per shape change.
    ///
    /// The gear shape changed when the readout moved from 12 gears to MyWhoosh's
    /// 30, so a blob written before that has no `startingGear` key: its
    /// `gearCount` was almost always the old default rather than a deliberate
    /// choice, so the two gear fields take the new defaults while every other
    /// preference is kept.
    ///
    /// The button shape changed when buttons stopped being only shifts: the old
    /// blob has `shiftUpButton` and `shiftDownButton`, which are exactly the two
    /// assignments to carry over. Anything unreadable falls back to its own
    /// default rather than discarding the whole blob.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedGearCount = try container.decodeIfPresent(Int.self, forKey: .gearCount)
        let storedStartingGear = try container.decodeIfPresent(Int.self, forKey: .startingGear)
        let transportMode = try container.decodeIfPresent(TransportMode.self, forKey: .transportMode)
        let showInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .showInMenuBar)
        let storedAssignments = try container.decodeIfPresent([ButtonAssignment].self, forKey: .buttonAssignments)
        let storedShiftUp = try container.decodeIfPresent(RideButtonMask.self, forKey: .shiftUpButton)
        let storedShiftDown = try container.decodeIfPresent(RideButtonMask.self, forKey: .shiftDownButton)
        let writtenBeforeThirtyGears = storedStartingGear == nil

        let assignments: [ButtonAssignment]
        if let storedAssignments {
            assignments = storedAssignments
        } else if storedShiftUp != nil || storedShiftDown != nil {
            assignments = [
                ButtonAssignment(button: storedShiftUp ?? .shiftUpRight, action: .shiftUp),
                ButtonAssignment(button: storedShiftDown ?? .b, action: .shiftDown),
            ]
        } else {
            assignments = ButtonAssignment.defaults
        }

        self.init(
            gearCount: writtenBeforeThirtyGears
                ? Drivetrain.defaultGearCount
                : (storedGearCount ?? Drivetrain.defaultGearCount),
            startingGear: storedStartingGear ?? Drivetrain.defaultStartingGear,
            transportMode: transportMode ?? .both,
            showInMenuBar: showInMenuBar ?? true,
            buttonAssignments: assignments
        )
    }

    /// Writes the current shape only. The two legacy button keys are read-only,
    /// so a saved blob never carries both the old and the new map.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(gearCount, forKey: .gearCount)
        try container.encode(startingGear, forKey: .startingGear)
        try container.encode(transportMode, forKey: .transportMode)
        try container.encode(showInMenuBar, forKey: .showInMenuBar)
        try container.encode(buttonAssignments, forKey: .buttonAssignments)
    }

    public var buttonMap: ButtonMap {
        var map: [RideButtonMask: ButtonAction] = [:]
        for pair in buttonAssignments {
            map[pair.button] = pair.action
        }
        return ButtonMap(assignments: map)
    }

    /// The button carrying an action, if any.
    public func button(for action: ButtonAction) -> RideButtonMask? {
        buttonMap.button(for: action)
    }

    /// True when a button changes desktops, which is the only action that needs
    /// the Accessibility grant, so the settings screen only offers it then.
    public var usesDesktopSwitching: Bool {
        buttonAssignments.contains { $0.action == .nextSpace || $0.action == .previousSpace }
    }

    /// Points a puck button at an action, through `ButtonMap.assign` so actions
    /// swap rather than collide. Reports what happened.
    @discardableResult
    public mutating func assign(
        _ button: RideButtonMask,
        to action: ButtonAction?
    ) -> ButtonMap.Assignment {
        var map = buttonMap
        let result = map.assign(button, to: action)
        guard result != .unchanged else { return result }
        buttonAssignments = GearUpSettings.normalised(map.all)
        return result
    }

    /// Puts the button map back to the shipped `+` and `B`.
    public mutating func restoreDefaultButtonMap() {
        buttonAssignments = ButtonAssignment.defaults
    }

    public static let `default` = GearUpSettings()

    /// One assignment per button, one action per assignment, in puck order.
    private static func normalised(_ pairs: [ButtonAssignment]) -> [ButtonAssignment] {
        var map: [RideButtonMask: ButtonAction] = [:]
        for pair in pairs {
            map[pair.button] = pair.action
        }
        return ButtonMap(assignments: map).all
    }

    private enum CodingKeys: String, CodingKey {
        case gearCount
        case startingGear
        case transportMode
        case showInMenuBar
        case buttonAssignments
        /// Written by versions where a button could only shift.
        case shiftUpButton
        case shiftDownButton
    }
}

extension ButtonAssignment {
    /// What the puck ships with: `+` shifts up, `B` shifts down, the other three
    /// buttons wait for the rider to give them something to do.
    public static let defaults: [ButtonAssignment] = [
        ButtonAssignment(button: .shiftUpRight, action: .shiftUp),
        ButtonAssignment(button: .b, action: .shiftDown),
    ]
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
