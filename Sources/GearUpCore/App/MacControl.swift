import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics

/// The things a button can do to the Mac itself.
///
/// These are here because a rider's hands are already on the puck: volume and
/// desktops are the two things worth reaching for mid-effort without taking a
/// hand off the bars. macOS gates them very differently, which is why they are
/// not one mechanism:
///
/// * Volume is CoreAudio and needs no permission at all.
/// * Desktops have no public "go next" API — Mission Control is driven by a key
///   combination — so GearUp posts Ctrl+←/→, and posting keys is exactly what
///   Accessibility permission is for. Granted once, it survives rebuilds because
///   the app is signed with a stable identity.
/// * Switching between MyWhoosh and whatever else was in front needs neither:
///   activating an app brings its window forward, and that takes the desktop with
///   it.
public enum MacControl {

    /// One press of a volume button: the same sixteenth the volume keys use.
    public static let volumeStep: Float = 1.0 / 16.0

    /// What one button action does, reporting what happened through `note`.
    ///
    /// Most of it can be said at once. The desktop actions cannot: only the
    /// system knows whether a switch moved anything, so they answer a moment
    /// later. What is noted ends up in the log, so it has to be what happened
    /// rather than what was asked for.
    public static func perform(_ action: ButtonAction, note: @escaping (String) -> Void) {
        switch action {
        case .volumeUp:
            if let said = adjustVolume(by: volumeStep) { note(said) }
        case .volumeDown:
            if let said = adjustVolume(by: -volumeStep) { note(said) }
        case .mute:
            if let said = toggleMute() { note(said) }
        case .nextSpace:
            moveDesktop(forward: true, note: note)
        case .previousSpace:
            moveDesktop(forward: false, note: note)
        case .toggleRideApp:
            RideAppSwitcher.shared.toggle(note: note)
        case .shiftUp, .shiftDown:
            break
        }
    }

    // MARK: - Volume

    /// The arithmetic, kept separate so it can be checked without an audio device.
    public static func steppedVolume(from current: Float, by delta: Float) -> Float {
        min(max(current + delta, 0), 1)
    }

    private static func adjustVolume(by delta: Float) -> String? {
        guard let device = defaultOutputDevice() else { return "no output device to change." }
        guard let current = volume(of: device) else { return "this output reports no volume." }
        let target = steppedVolume(from: current, by: delta)
        guard setVolume(target, of: device) else { return "this output does not take a volume change." }
        return "volume \(Int((target * 100).rounded()))%."
    }

    private static func toggleMute() -> String? {
        guard let device = defaultOutputDevice() else { return "no output device to mute." }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return "this output has no mute switch." }

        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { return nil }
        var wanted: UInt32 = muted == 0 ? 1 : 0
        guard AudioObjectSetPropertyData(device, &address, 0, nil, size, &wanted) == noErr else { return nil }
        return wanted == 1 ? "muted." : "unmuted."
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// The master element when the device has one that is settable, otherwise
    /// the first output channel — which is how most interfaces expose it.
    private static func volumeElement(of device: AudioObjectID) -> AudioObjectPropertyElement? {
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var settable = DarwinBoolean(false)
            guard AudioObjectHasProperty(device, &address) else { continue }
            guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
                  settable.boolValue else { continue }
            return element
        }
        return nil
    }

    private static func volume(of device: AudioObjectID) -> Float? {
        guard let element = volumeElement(of: device) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func setVolume(_ value: Float, of device: AudioObjectID) -> Bool {
        // A device with no master element reports its channels separately, so a
        // change that only moved the left one would sound like a fault.
        let elements: [AudioObjectPropertyElement]
        if let element = volumeElement(of: device) {
            elements = element == kAudioObjectPropertyElementMain ? [element] : [1, 2]
        } else {
            return false
        }

        var changed = false
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var value = value
            if AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &value) == noErr {
                changed = true
            }
        }
        return changed
    }

    // MARK: - Desktops

    /// The wording the settings screen and the log share for a missing grant.
    public static let accessibilityHint = "changing desktops needs Accessibility permission "
        + "(System Settings → Privacy & Security → Accessibility)."

    public static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Asks the system for the permission desktops need, showing its own prompt.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// Asks at most once per run, for the places that are not the rider
    /// explicitly asking: a press on a desktop button, or binding one. Being
    /// asked once is help; being asked again mid-ride is noise.
    ///
    /// Everything here runs on the main queue — CoreBluetooth is created with a
    /// nil queue — so the flag needs no lock.
    @discardableResult
    public static func askForAccessibilityOnce() -> Bool {
        guard !hasAccessibility else { return true }
        guard !hasAskedForAccessibility else { return false }
        hasAskedForAccessibility = true
        return requestAccessibility()
    }

    private static var hasAskedForAccessibility = false

    /// How long the system gets to finish a desktop switch before GearUp decides
    /// that nothing moved. The switch itself is quick; this is slack for the
    /// animation and for the new desktop's windows to be reported.
    static let desktopSettleTime: TimeInterval = 0.45

    /// Where the away/back toggle last left the rider, and which way it went.
    ///
    /// Only the main queue touches these — CoreBluetooth is created with a nil
    /// queue and every note is posted on main — so they need no lock.
    private static var isAwayFromRide = false
    private static var awayWasForward: Bool?

    /// Called when the ride was reached by activating it rather than by moving
    /// back to its desktop, so the next away press starts from the ride again.
    static func noteReturnedToRide() {
        isAwayFromRide = false
    }

    /// What the current desktop looks like from outside: which processes own the
    /// windows on screen, and which app is in front.
    ///
    /// Window owners are readable without Screen Recording — only titles and
    /// pixels need that — so this costs no permission. The frontmost app is part
    /// of the picture because two desktops can hold windows of the same app.
    private struct VisibleDesktop: Equatable {
        var owners: Set<pid_t>
        var frontmost: String?
    }

    private static func visibleDesktop() -> VisibleDesktop {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        var owners: Set<pid_t> = []
        if let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            for window in list {
                guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                      let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
                owners.insert(pid)
            }
        }
        return VisibleDesktop(
            owners: owners,
            frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
    }

    /// Posts one Ctrl+arrow. Returns false when the key could not be posted.
    private static func postControlArrow(forward: Bool) -> Bool {
        // Mission Control's own defaults: Control with the arrow keys.
        let key: CGKeyCode = forward ? 124 : 123
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown) else {
                return false
            }
            event.flags = .maskControl
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    /// One desktop move, telling the caller whether it really moved.
    private static func attemptDesktop(forward: Bool, then: @escaping (Bool) -> Void) {
        let before = visibleDesktop()
        guard postControlArrow(forward: forward) else {
            then(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + desktopSettleTime) {
            then(visibleDesktop() != before)
        }
    }

    /// A one-way desktop button, with the truth in the log: a key that was
    /// posted is not the same thing as a desktop that changed.
    private static func moveDesktop(forward: Bool, note: @escaping (String) -> Void) {
        guard hasAccessibility else {
            // The prompt is the only way to tell a rider what is missing, and it
            // opens the pane they need.
            askForAccessibilityOnce()
            note(accessibilityHint)
            return
        }
        attemptDesktop(forward: forward) { moved in
            note(moved
                 ? (forward ? "next desktop." : "previous desktop.")
                 : "the desktop did not move, so there is no desktop that way.")
        }
    }

    /// "Leave the ride and come back", for when there is no app to name.
    ///
    /// MyWhoosh goes fullscreen on a desktop of its own, so the rider's other
    /// windows are a desktop away rather than behind it, and macOS has no public
    /// "go to desktop N". This is therefore a two-state toggle: the press that
    /// leaves tries forward first — the ride's desktop is usually the first — and
    /// falls back to backward when nothing moves, which is the ride-on-the-last-
    /// desktop case. Whichever direction worked is remembered, so the press that
    /// comes back goes the other way and lands where the rider left off.
    static func toggleDesktop(note: @escaping (String) -> Void) {
        guard hasAccessibility else {
            askForAccessibilityOnce()
            note(accessibilityHint)
            return
        }

        let goingAway = !isAwayFromRide
        let forward = goingAway ? (awayWasForward ?? true) : !(awayWasForward ?? true)

        attemptDesktop(forward: forward) { moved in
            guard !moved else {
                record(goingAway: goingAway, forward: forward, note: note)
                return
            }
            // Nothing moved: this was the last desktop that way, or the rider
            // moved by hand. One try the other way, then say so rather than keep
            // guessing at the rider's layout.
            attemptDesktop(forward: !forward) { movedTheOtherWay in
                guard movedTheOtherWay else {
                    awayWasForward = nil
                    isAwayFromRide = false
                    note("the desktop did not move either way, so there may be only one.")
                    return
                }
                record(goingAway: goingAway, forward: !forward, note: note)
            }
        }
    }

    private static func record(goingAway: Bool, forward: Bool, note: @escaping (String) -> Void) {
        if goingAway { awayWasForward = forward }
        isAwayFromRide = goingAway
        if goingAway {
            note("away from the ride, on the \(forward ? "next" : "previous") desktop.")
        } else {
            note("back on the ride's desktop.")
        }
    }
}

/// Swaps between the trainer app and whatever else was in front.
///
/// `NSRunningApplication.activate` brings an app's windows forward, and macOS
/// takes the desktop with them, so the app-to-app half needs no Accessibility
/// grant. What it does need is a memory of where the rider was before MyWhoosh,
/// because macOS has no public API for "the previous app" either: the workspace
/// notification is observed from launch, and the app that was in front before
/// GearUp is seeded as early as the app can look.
///
/// MyWhoosh usually runs fullscreen on a desktop of its own, and nothing
/// guarantees that another app was visited while GearUp was running — launching
/// GearUp straight into a ride is the normal case. When nothing is remembered the
/// press changes desktop instead, which is what leaving a fullscreen ride takes.
public final class RideAppSwitcher {
    public static let shared = RideAppSwitcher()

    /// MyWhoosh, by bundle identifier. Kept as a set so a rename of the app on
    /// disk does not break the button.
    public var rideAppBundleIDs: Set<String> = ["com.whoosh.whooshgame"]

    /// Our own identifier, so pressing the button on GearUp does not "go back" to
    /// GearUp.
    private let ownBundleID = Bundle.main.bundleIdentifier ?? "com.oscar.gearup"

    /// How long activation is given to show up in `isActive` before the log says
    /// it did not work.
    static let activationSettleTime: TimeInterval = 0.4

    private var lastOther: NSRunningApplication?
    private var observer: NSObjectProtocol?
    private var started = false

    private init() {}

    /// Starts watching which app is in front.
    ///
    /// The seed cannot come from here: by the time the controller exists, GearUp
    /// itself is frontmost, so the app that was in front before it is handed over
    /// by `seed(_:)`.
    public func start() {
        guard !started else { return }
        started = true

        observer = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self?.remember(app)
        }
    }

    /// Remembers the app that was in front before GearUp took the screen.
    ///
    /// Read at launch, because that is the last moment macOS will still say: a
    /// moment later GearUp is the frontmost app and the answer is GearUp.
    public func seed(_ app: NSRunningApplication) {
        remember(app)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func remember(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier,
              !rideAppBundleIDs.contains(bundleID),
              bundleID != ownBundleID,
              !app.isTerminated else { return }
        lastOther = app
    }

    private func runningRideApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return rideAppBundleIDs.contains(bundleID) && !app.isTerminated
        }
    }

    /// What the away half of the ⇄ button would do right now: the app it would
    /// go to, or nil when it would change desktop instead. For the log, so a
    /// launch that happened too late to see the rider's app says so out loud.
    public var awayDestinationName: String? {
        guard let other = lastOther, !other.isTerminated else { return nil }
        return other.localizedName
    }

    /// One press: out of the ride, or back into it.
    ///
    /// Out means the app the rider came from when that is known — macOS brings
    /// its desktop with it — and the next desktop otherwise.
    public func toggle(note: @escaping (String) -> Void) {
        let inRide = NSWorkspace.shared.frontmostApplication?
            .bundleIdentifier.map(rideAppBundleIDs.contains) ?? false

        if inRide {
            if let other = lastOther, !other.isTerminated {
                leave(to: other, note: note)
            } else {
                MacControl.toggleDesktop(note: note)
            }
            return
        }

        guard let ride = runningRideApp() else {
            note("MyWhoosh is not running.")
            return
        }
        returnTo(ride, note: note)
    }

    /// Leaves the ride for the app the rider was in before.
    ///
    /// If that app does not take the screen, leaving is still possible the other
    /// way — a desktop — rather than the press doing nothing.
    private func leave(to app: NSRunningApplication, note: @escaping (String) -> Void) {
        let name = app.localizedName ?? "the app"
        askToComeForward(app) { refusal in
            guard let refusal else {
                note("\(name) is in front.")
                return
            }
            note("could not bring \(name) forward (\(refusal)). Changing desktop instead.")
            MacControl.toggleDesktop(note: note)
        }
    }

    private func returnTo(_ ride: NSRunningApplication, note: @escaping (String) -> Void) {
        let name = ride.localizedName ?? "MyWhoosh"
        askToComeForward(ride) { refusal in
            if let refusal {
                note("could not bring \(name) forward (\(refusal)).")
            } else {
                // Reaching the ride by activating it also puts the desktop toggle
                // back on the ride's desktop, so the next press leaves again.
                MacControl.noteReturnedToRide()
                note("\(name) is in front.")
            }
        }
    }

    /// Asks an app to come forward and waits to see whether it did.
    ///
    /// `activate()` is the ordinary route, but macOS ignores it when the caller is
    /// not itself the frontmost app — which is GearUp's situation during a ride —
    /// so the Accessibility route is asked at the same time. Both are only
    /// requests; the answer comes from the workspace a moment later.
    ///
    /// Calls back with nil when the app is in front, or a sentence saying why not.
    private func askToComeForward(
        _ app: NSRunningApplication,
        then: @escaping (String?) -> Void
    ) {
        let activated = app.activate()
        let accessibility = raiseViaAccessibility(app)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.activationSettleTime) { [weak self] in
            guard let self else { return }
            guard !self.isInFront(app) else {
                then(nil)
                return
            }
            then(Self.explanation(
                activated: activated,
                accessibility: accessibility,
                hasAccessibility: MacControl.hasAccessibility
            ))
        }
    }

    /// The honest why, for the log. Pure, so every branch can be checked.
    public static func explanation(
        activated: Bool,
        accessibility: AXError?,
        hasAccessibility: Bool
    ) -> String {
        guard hasAccessibility else {
            return "macOS refused the request and Accessibility permission is not granted"
        }
        if accessibility == .success {
            return "the system accepted the request but nothing came forward"
        }
        if let accessibility {
            let route = activated ? "activation accepted" : "activation refused"
            return "\(route), Accessibility error \(accessibility.rawValue)"
        }
        return "macOS refused the request"
    }

    /// Raises an app through Accessibility, which works from the background where
    /// activation is refused. Returns the system's answer, or nil without the
    /// grant.
    private func raiseViaAccessibility(_ app: NSRunningApplication) -> AXError? {
        guard MacControl.hasAccessibility else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        return AXUIElementSetAttributeValue(
            element,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
    }

    private func isInFront(_ app: NSRunningApplication) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }
}
