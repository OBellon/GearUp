import AppKit
import ApplicationServices
import CoreAudio

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

    /// What one button action does, and what to say about it in the log.
    ///
    /// Returns `nil` for actions that are not the Mac's business.
    @discardableResult
    public static func perform(_ action: ButtonAction) -> String? {
        switch action {
        case .volumeUp:
            return adjustVolume(by: volumeStep)
        case .volumeDown:
            return adjustVolume(by: -volumeStep)
        case .mute:
            return toggleMute()
        case .nextSpace:
            return switchSpace(forward: true)
        case .previousSpace:
            return switchSpace(forward: false)
        case .toggleRideApp:
            return RideAppSwitcher.shared.toggle()
        case .shiftUp, .shiftDown:
            return nil
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

    private static func switchSpace(forward: Bool) -> String? {
        guard hasAccessibility else {
            // The prompt is the only way to tell a rider what is missing, and it
            // opens the pane they need.
            askForAccessibilityOnce()
            return "changing desktops needs Accessibility permission "
                + "(System Settings → Privacy & Security → Accessibility)."
        }

        // Mission Control's own defaults: Control with the arrow keys.
        let key: CGKeyCode = forward ? 124 : 123
        guard let source = CGEventSource(stateID: .hidSystemState) else { return nil }
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown) else {
                return nil
            }
            event.flags = .maskControl
            event.post(tap: .cghidEventTap)
        }
        return forward ? "next desktop." : "previous desktop."
    }
}

/// Swaps between the trainer app and whatever else was in front.
///
/// `NSRunningApplication.activate` brings an app's windows forward, and macOS
/// takes the desktop with them, so this needs no Accessibility grant. What it
/// does need is a memory of where the rider was before MyWhoosh, because macOS
/// has no public API for "the previous app" either: the workspace notification
/// is observed instead, which is why the switcher starts when the app does rather
/// than on the first press.
public final class RideAppSwitcher {
    public static let shared = RideAppSwitcher()

    /// MyWhoosh, by bundle identifier. Kept as a set so a rename of the app on
    /// disk does not break the button.
    public var rideAppBundleIDs: Set<String> = ["com.whoosh.whooshgame"]

    /// Our own identifier, so pressing the button on GearUp does not "go back" to
    /// GearUp.
    private let ownBundleID = Bundle.main.bundleIdentifier ?? "com.oscar.gearup"

    private var lastOther: NSRunningApplication?
    private var observer: NSObjectProtocol?
    private var started = false

    private init() {}

    /// Starts remembering, and seeds the memory with whatever is in front now.
    ///
    /// Seeding matters because the common case is launching GearUp from MyWhoosh:
    /// without it the first press would have nothing to go back to.
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

        if let front = NSWorkspace.shared.frontmostApplication {
            remember(front)
        }
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

    public func toggle() -> String? {
        let front = NSWorkspace.shared.frontmostApplication
        let frontIsRideApp = front?.bundleIdentifier.map(rideAppBundleIDs.contains) ?? false

        if frontIsRideApp {
            guard let other = lastOther, !other.isTerminated else {
                return "no app to go back to yet; visit one and this will remember it."
            }
            other.activate()
            return "back to \(other.localizedName ?? "the other app")."
        }

        guard let ride = NSWorkspace.shared.runningApplications.first(where: {
            guard let bundleID = $0.bundleIdentifier else { return false }
            return rideAppBundleIDs.contains(bundleID) && !$0.isTerminated
        }) else {
            return "MyWhoosh is not running."
        }
        ride.activate()
        return "back to \(ride.localizedName ?? "MyWhoosh")."
    }
}
