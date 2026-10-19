import Foundation

/// Which Click V2 button triggers which shifting action.
///
/// v1 ships with the two defaults confirmed against real hardware: the `+`
/// button (mask `0x1000`, bit 12) shifts up and `B` (mask `0x0020`, bit 5)
/// shifts down. `Y`, `Z` and `A` are deliberately left unassigned so they can
/// be given to power-ups or steering later without changing the shifting path.
public struct ButtonMap: Equatable {
    public var shiftUp: RideButtonMask
    public var shiftDown: RideButtonMask

    public init(shiftUp: RideButtonMask = .shiftUpRight, shiftDown: RideButtonMask = .b) {
        self.shiftUp = shiftUp
        self.shiftDown = shiftDown
    }

    public static let `default` = ButtonMap()

    /// The action a button triggers, or `.none` when it is unassigned.
    public func action(for button: RideButtonMask) -> ShiftAction {
        if button == shiftUp { return .shiftUp }
        if button == shiftDown { return .shiftDown }
        return .none
    }

    /// The button assigned to an action, if any. When both actions would map to
    /// the same button the shift-up assignment wins, which keeps a
    /// misconfiguration visible instead of silently dropping shifts.
    public func button(for action: ShiftAction) -> RideButtonMask? {
        switch action {
        case .shiftUp: return shiftUp
        case .shiftDown: return shiftDown == shiftUp ? nil : shiftDown
        case .none: return nil
        }
    }

    /// Every assigned button, for the settings UI.
    public var assignments: [(button: RideButtonMask, action: ShiftAction)] {
        var result: [(RideButtonMask, ShiftAction)] = [(shiftUp, .shiftUp)]
        if shiftDown != shiftUp { result.append((shiftDown, .shiftDown)) }
        return result.map { (button: $0.0, action: $0.1) }
    }

    /// What `assign` did, so the caller can say so in the log.
    public enum Assignment: Equatable {
        case assigned
        case swapped(freed: RideButtonMask)
        case unchanged
    }

    /// Points an action at a button.
    ///
    /// The two actions never share a button: assigning one that already drives
    /// the other action swaps them over. That is what a remap screen is expected
    /// to do, and it leaves the map consistent — the guard in `button(for:)`
    /// above is only a safety net for a map that was edited by hand.
    @discardableResult
    public mutating func assign(_ button: RideButtonMask, to action: ShiftAction) -> Assignment {
        switch action {
        case .none:
            return .unchanged
        case .shiftUp:
            guard shiftUp != button else { return .unchanged }
            if shiftDown == button {
                shiftDown = shiftUp
                shiftUp = button
                return .swapped(freed: shiftDown)
            }
            shiftUp = button
            return .assigned
        case .shiftDown:
            guard shiftDown != button else { return .unchanged }
            if shiftUp == button {
                shiftUp = shiftDown
                shiftDown = button
                return .swapped(freed: shiftUp)
            }
            shiftDown = button
            return .assigned
        }
    }
}

/// Turns keypad reports into shift actions.
///
/// The Click V2 is a chatty device: it repeats every report a few times and then
/// repeats the released state for about a second. Acting on each report would
/// shift several gears per tap, so this router only emits an action on the
/// *transition* into pressed. The release is tracked solely so the next press of
/// the same button is recognised as a new one.
///
/// A release notification that never arrives (the puck went out of range
/// mid-press) would otherwise leave a button stuck as held and swallow the next
/// press, so a report that repeats the held state long after the press is
/// treated as a fresh press instead.
public final class ShiftRouter {
    public var buttonMap: ButtonMap

    /// While true, presses are still reported through `onButtonChange` but no
    /// shift is emitted, so the settings screen can read a button off the puck
    /// without moving the gear.
    public var isCapturingButtons = false

    /// How long a press is considered held before an identical repeated report
    /// is treated as a new press. The puck's own release flood lasts about a
    /// second, so this has to be comfortably longer than that.
    public var stuckPressTimeout: TimeInterval = 1.5

    public private(set) var heldButtons: Set<RideButtonMask> = []
    private var heldSince: Date?

    /// Called for every shift that should be sent to the trainer app.
    public var onShift: ((ShiftAction, RideButtonMask) -> Void)?
    /// Called for every press/release edge, including unassigned buttons, so the
    /// UI can show that the puck is being read.
    public var onButtonChange: ((RideButtonMask, Bool) -> Void)?
    /// Called when a repeated report was ignored because the state did not
    /// change (the common case, several times per press).
    public var onRepeatedReport: (() -> Void)?

    private let now: () -> Date

    public init(buttonMap: ButtonMap = .default, now: @escaping () -> Date = Date.init) {
        self.buttonMap = buttonMap
        self.now = now
    }

    /// Feeds one keypad report in and returns the shifts it implies.
    ///
    /// Returns an empty array for the repeats that make up most of the traffic.
    @discardableResult
    public func handle(_ status: RideKeyPadStatus) -> [ShiftAction] {
        let pressed = Set(status.pressedButtons)
        let timestamp = now()
        let isRepeat = pressed == heldButtons
        let heldFor = heldSince.map { timestamp.timeIntervalSince($0) } ?? 0

        if isRepeat, heldFor <= stuckPressTimeout {
            onRepeatedReport?()
            return []
        }

        if isRepeat {
            // The release report never arrived: treat the stale press as
            // released so this report counts as a new press.
            for button in heldButtons { onButtonChange?(button, false) }
            heldButtons = []
            heldSince = nil
        }

        let newlyPressed = pressed.subtracting(heldButtons)
        let released = heldButtons.subtracting(pressed)

        for button in released { onButtonChange?(button, false) }
        for button in newlyPressed { onButtonChange?(button, true) }

        heldButtons = pressed
        heldSince = pressed.isEmpty ? nil : timestamp

        var actions: [ShiftAction] = []
        // Sorted so a two-button report always behaves the same way.
        for button in newlyPressed.sorted(by: { $0.rawValue < $1.rawValue }) {
            let action = buttonMap.action(for: button)
            guard action != .none, !isCapturingButtons else { continue }
            actions.append(action)
            onShift?(action, button)
        }
        return actions
    }

    /// Forgets the held state, e.g. when the puck disconnects mid-press.
    public func reset() {
        for button in heldButtons { onButtonChange?(button, false) }
        heldButtons = []
        heldSince = nil
    }

    public func isHeld(_ button: RideButtonMask) -> Bool {
        heldButtons.contains(button)
    }
}
