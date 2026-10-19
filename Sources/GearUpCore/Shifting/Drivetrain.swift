import Foundation

/// Virtual drivetrain state: how many gears the rider has configured and which
/// one is currently selected.
///
/// GearUp is not the source of truth for the gear a trainer app is actually in
/// (the app owns that), so this is a display-side model. It is intentionally
/// simple and fully unit-tested.
///
/// The defaults mirror MyWhoosh's own shifting (MyShift), which offers 30 gears
/// and starts a ride in gear 15, so the number here agrees with the readout on
/// the ride HUD instead of drifting away from it.
public struct Drivetrain: Equatable {
    public static let supportedGearRange = 1...30

    /// MyWhoosh's MyShift gear count, and so GearUp's default readout.
    public static let defaultGearCount = 30
    /// MyWhoosh starts every ride in the middle of the cassette.
    public static let defaultStartingGear = 15

    public private(set) var gearCount: Int
    public private(set) var currentGear: Int

    public init(
        gearCount: Int = Drivetrain.defaultGearCount,
        currentGear: Int = Drivetrain.defaultStartingGear
    ) {
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

    public mutating func reset(to gear: Int = Drivetrain.defaultStartingGear) {
        currentGear = min(max(gear, 1), gearCount)
    }
}

