import Foundation

/// What a puck button can do.
///
/// The puck is a five-button remote that a rider's hands are already on, so two
/// kinds of action live here: the shifts that travel to MyWhoosh over
/// OpenBikeControl, and the things worth reaching for mid-effort without taking a
/// hand off the bars. The two kinds are kept distinguishable rather than being
/// separate enums because the map, the settings screen and the router all want to
/// treat "the job a button does" as one thing.
public enum ButtonAction: String, Codable, CaseIterable {
    case shiftUp
    case shiftDown
    case volumeUp
    case volumeDown
    case mute
    case nextSpace
    case previousSpace
    case toggleRideApp

    public var title: String {
        switch self {
        case .shiftUp: return "Shift Up"
        case .shiftDown: return "Shift Down"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .mute: return "Mute"
        case .nextSpace: return "Next Desktop"
        case .previousSpace: return "Previous Desktop"
        case .toggleRideApp: return "MyWhoosh ⇄ Last App"
        }
    }

    /// Shifts go to the trainer app; everything else happens on this Mac and
    /// needs no transport at all.
    public var isShift: Bool {
        self == .shiftUp || self == .shiftDown
    }

    /// What the settings screen says under the title, where it helps.
    public var detail: String? {
        switch self {
        case .volumeUp, .volumeDown, .mute:
            return "The Mac's output volume."
        case .nextSpace, .previousSpace:
            return "Uses Ctrl+←/→, so it needs Accessibility permission once."
        case .toggleRideApp:
            return "Switches between MyWhoosh and the app you were in before."
        case .shiftUp, .shiftDown:
            return "Sent to MyWhoosh over OpenBikeControl."
        }
    }
}

/// One button's job, as it is stored and shown.
///
/// Pairs rather than a dictionary so the JSON is readable, and so a puck with
/// more buttons than this one needs no change of shape.
public struct ButtonAssignment: Codable, Equatable, Identifiable {
    public var button: RideButtonMask
    public var action: ButtonAction

    /// A button carries at most one action, so it is the identifier.
    public var id: RideButtonMask { button }

    public init(button: RideButtonMask, action: ButtonAction) {
        self.button = button
        self.action = action
    }
}

/// Which Click V2 button does what.
///
/// v1 ships with the two defaults confirmed against real hardware: the `+`
/// button (mask `0x1000`, bit 12) shifts up and `B` (mask `0x0020`, bit 5)
/// shifts down. `Y`, `Z` and `A` are unassigned until the rider gives them
/// something to do.
///
/// The map is a bijection over whatever is assigned at all: one button, one
/// action, and no action twice. That is what makes the settings screen's
/// "assign this to that" unambiguous — it can always swap rather than collide.
public struct ButtonMap: Equatable {
    public private(set) var assignments: [RideButtonMask: ButtonAction]

    public init(assignments: [RideButtonMask: ButtonAction] = [:]) {
        self.assignments = ButtonMap.normalised(assignments)
    }

    public static let `default` = ButtonMap(assignments: [
        .shiftUpRight: .shiftUp,
        .b: .shiftDown,
    ])

    /// The action a button triggers, or `nil` when it is unassigned.
    public func action(for button: RideButtonMask) -> ButtonAction? {
        assignments[button]
    }

    /// The button assigned to an action, if any.
    public func button(for action: ButtonAction) -> RideButtonMask? {
        assignments.first { $0.value == action }?.key
    }

    /// Every assigned pair, in the puck's own button order, for the settings
    /// screen and the log.
    public var all: [ButtonAssignment] {
        RideButtonMask.clickV2RightPuck.compactMap { button in
            assignments[button].map { ButtonAssignment(button: button, action: $0) }
        }
    }

    /// What `assign` did, so the caller can say so in the log.
    public enum Assignment: Equatable {
        case assigned
        case swapped(freed: RideButtonMask)
        case cleared
        case unchanged
    }

    /// Points an action at a button, or clears the button with `nil`.
    ///
    /// Assigning an action another button already carries moves it there and
    /// swaps the two over when that button had a job of its own, which is what a
    /// remap screen is expected to do and what leaves the map consistent.
    /// Clearing is the one way a button ends up doing nothing.
    @discardableResult
    public mutating func assign(_ button: RideButtonMask, to action: ButtonAction?) -> Assignment {
        let current = assignments[button]
        guard current != action else { return .unchanged }

        guard let action else {
            assignments[button] = nil
            return .cleared
        }

        if let other = self.button(for: action), other != button {
            assignments[other] = current
            assignments[button] = action
            // A real trade is worth naming; a plain move — where the button the
            // action left has nothing to take over — is just an assignment.
            return current == nil ? .assigned : .swapped(freed: other)
        }

        assignments[button] = action
        return .assigned
    }

    /// Makes the invariant true for a map that arrived from storage or a hand
    /// edit: the first button in the puck's order keeps a duplicated action, and
    /// any button the puck does not have is dropped.
    private static func normalised(
        _ raw: [RideButtonMask: ButtonAction]
    ) -> [RideButtonMask: ButtonAction] {
        var taken = Set<ButtonAction>()
        var result: [RideButtonMask: ButtonAction] = [:]
        for button in RideButtonMask.clickV2RightPuck {
            guard let action = raw[button], !taken.contains(action) else { continue }
            taken.insert(action)
            result[button] = action
        }
        return result
    }
}

/// Turns keypad reports into button actions.
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
public final class ButtonRouter {
    public var buttonMap: ButtonMap

    /// While true, presses are still reported through `onButtonChange` but no
    /// action is emitted, so the settings screen can read a button off the puck
    /// without moving the gear or changing the volume.
    public var isCapturingButtons = false

    /// How long a press is considered held before an identical repeated report
    /// is treated as a new press. The puck's own release flood lasts about a
    /// second, so this has to be comfortably longer than that.
    public var stuckPressTimeout: TimeInterval = 1.5

    public private(set) var heldButtons: Set<RideButtonMask> = []
    private var heldSince: Date?

    /// Called for every action that should happen.
    public var onAction: ((ButtonAction, RideButtonMask) -> Void)?
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

    /// Feeds one keypad report in and returns the actions it implies.
    ///
    /// Returns an empty array for the repeats that make up most of the traffic.
    @discardableResult
    public func handle(_ status: RideKeyPadStatus) -> [ButtonAction] {
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

        var actions: [ButtonAction] = []
        // Sorted so a two-button report always behaves the same way.
        for button in newlyPressed.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard !isCapturingButtons, let action = buttonMap.action(for: button) else { continue }
            actions.append(action)
            onAction?(action, button)
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
