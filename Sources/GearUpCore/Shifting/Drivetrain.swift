import Foundation

/// Virtual drivetrain state: how many gears the rider has configured and which
/// one is currently selected.
///
/// GearUp is not the source of truth for the gear a trainer app is actually in
/// (the app owns that), so this is a display-side model. It is intentionally
/// simple and fully unit-tested.
public struct Drivetrain: Equatable {
    public static let supportedGearRange = 1...30

    public private(set) var gearCount: Int
    public private(set) var currentGear: Int

    public init(gearCount: Int = 12, currentGear: Int = 1) {
        let clampedCount = min(max(gearCount, Self.supportedGearRange.lowerBound), Self.supportedGearRange.upperBound)
        self.gearCount = clampedCount
        self.currentGear = min(max(currentGear, 1), clampedCount)
    }

    public var isAtTopGear: Bool { currentGear >= gearCount }
    public var isAtBottomGear: Bool { currentGear <= 1 }

    /// Moves one gear up (harder) and returns the resulting gear.
    @discardableResult
    public mutating func shiftUp() -> Int {
        currentGear = min(currentGear + 1, gearCount)
        return currentGear
    }

    /// Moves one gear down (easier) and returns the resulting gear.
    @discardableResult
    public mutating func shiftDown() -> Int {
        currentGear = max(currentGear - 1, 1)
        return currentGear
    }

    public mutating func setGearCount(_ count: Int) {
        self = Drivetrain(gearCount: count, currentGear: currentGear)
    }

    public mutating func reset(to gear: Int = 1) {
        currentGear = min(max(gear, 1), gearCount)
    }
}

/// Semantic actions GearUp can emit. Kept separate from the OpenBikeControl
/// button IDs so the mapping layer stays explicit.
public enum ShiftAction: String, CaseIterable {
    case shiftUp
    case shiftDown
    case none

    public var title: String {
        switch self {
        case .shiftUp: return "Shift Up"
        case .shiftDown: return "Shift Down"
        case .none: return "Unassigned"
        }
    }
}
