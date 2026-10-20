import Foundation
import ApplicationServices
import AppKit
import GearUpCore

// MARK: - Shift router

/// The shifting logic, driven by the reports captured from a real Click V2.
func runShiftRouterChecks(_ checks: Checks) {

    /// A clock the checks can move by hand, so press timing is deterministic.
    final class Clock {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    /// Records everything a router reports.
    final class Recorder {
        var actions: [ButtonAction] = []
        var edges: [(RideButtonMask, Bool)] = []
        var repeats = 0

        func attach(to router: ButtonRouter) {
            router.onAction = { [weak self] action, _ in self?.actions.append(action) }
            router.onButtonChange = { [weak self] button, pressed in self?.edges.append((button, pressed)) }
            router.onRepeatedReport = { [weak self] in self?.repeats += 1 }
        }
    }

    /// Raw notifications captured from the right puck, one per button.
    let yPress: [UInt8] = [0x23, 0x08, 0xBF, 0xFF, 0xFF, 0xFF, 0x0F]
    let zPress: [UInt8] = [0x23, 0x08, 0xFF, 0xFE, 0xFF, 0xFF, 0x0F]
    let bPress: [UInt8] = [0x23, 0x08, 0xDF, 0xFF, 0xFF, 0xFF, 0x0F]
    let aPress: [UInt8] = [0x23, 0x08, 0xEF, 0xFF, 0xFF, 0xFF, 0x0F]
    let plusPress: [UInt8] = [0x23, 0x08, 0xFF, 0xDF, 0xFF, 0xFF, 0x0F]
    let released: [UInt8] = [0x23, 0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F]

    func status(_ bytes: [UInt8]) -> RideKeyPadStatus {
        guard case .rideKeyPad(let status)? = ZwiftClickCodec.decode(bytes) else {
            fatalError("captured packet \(bytes.hexString) is not a keypad report")
        }
        return status
    }

    checks.group("Button map") {
        let map = ButtonMap.default
        checks.equal(map.button(for: .shiftUp), .shiftUpRight, "the + button shifts up by default")
        checks.equal(map.button(for: .shiftDown), .b, "the B button shifts down by default")
        checks.equal(map.action(for: .shiftUpRight), .shiftUp, "+ maps to shift up")
        checks.equal(map.action(for: .b), .shiftDown, "B maps to shift down")
        checks.isNil(map.action(for: .y), "Y is unassigned")
        checks.isNil(map.action(for: .z), "Z is unassigned")
        checks.isNil(map.action(for: .a), "A is unassigned")

        let remapped = ButtonMap(assignments: [.y: .shiftUp, .z: .shiftDown])
        checks.equal(remapped.action(for: .y), .shiftUp, "a remapped Y shifts up")
        checks.equal(remapped.action(for: .z), .shiftDown, "a remapped Z shifts down")
        checks.isNil(remapped.action(for: .shiftUpRight), "the old + assignment is gone")
        checks.equal(remapped.assignments.count, 2, "two assignments are listed")

        // Two buttons claiming one action, e.g. a hand-edited blob: the first in
        // puck order keeps it and the map stays a bijection.
        let doubled = ButtonMap(assignments: [.b: .shiftUp, .a: .shiftUp])
        checks.equal(doubled.button(for: .shiftUp), .a, "a repeated action keeps the first button in puck order")
        checks.equal(doubled.assignments.count, 1, "a doubled action is listed once")

        checks.equal(
            RideButtonMask.clickV2RightPuck,
            [.y, .z, .a, .b, .shiftUpRight],
            "the right puck's five buttons are the mappable ones"
        )
        checks.equal(
            RideButtonMask.clickV2RightPuck.map(\.displayName),
            ["Y", "Z", "A", "B", "+"],
            "they are labelled the way the hardware prints them"
        )
    }

    checks.group("Button actions") {
        checks.equal(ButtonAction.allCases.count, 8, "there are eight things a button can do")
        checks.equal(
            ButtonAction.allCases.filter(\.isShift),
            [.shiftUp, .shiftDown],
            "only the two shifts travel to MyWhoosh"
        )
        checks.equal(ButtonAction.volumeUp.title, "Volume Up", "the volume-up title")
        checks.equal(ButtonAction.nextSpace.title, "Next Desktop", "the next-desktop title")
        checks.equal(ButtonAction.toggleRideApp.title, "MyWhoosh ⇄ Away", "the ride-app title")
        checks.expect(
            ButtonAction.allCases.allSatisfy { !$0.title.isEmpty },
            "every action has a title for the settings screen"
        )
        checks.equal(
            ButtonAction.allCases.filter(\.needsAccessibility),
            [.nextSpace, .previousSpace, .toggleRideApp],
            "the desktop actions are the ones that need Accessibility"
        )
        checks.expect(
            ButtonAction.toggleRideApp.detail?.contains("desktop") == true,
            "the ride-app action says it can change desktop when there is nowhere else to go"
        )
        checks.expect(
            RideAppSwitcher.explanation(activated: false, accessibility: nil, hasAccessibility: true)
                .contains("refused"),
            "a refused activation says so"
        )
        checks.expect(
            RideAppSwitcher.explanation(activated: false, accessibility: .success, hasAccessibility: true)
                .contains("nothing came forward"),
            "an accepted request that changed nothing says so"
        )
        checks.expect(
            RideAppSwitcher.explanation(activated: false, accessibility: nil, hasAccessibility: false)
                .contains("Accessibility"),
            "a missing Accessibility grant is named"
        )
        checks.expect(
            ButtonAction.allCases.filter { !$0.isShift }.allSatisfy { $0.detail != nil },
            "every Mac action explains itself in the settings screen"
        )
    }

    checks.group("Away from the ride") {
        // Workspace notifications are posted on the workspace's own centre, not
        // on NotificationCenter.default. Listening on the wrong one is why the ⇄
        // button always went back to the app GearUp was launched from.
        let switcher = RideAppSwitcher.shared
        switcher.start()

        let candidate = NSWorkspace.shared.runningApplications.first { app in
            guard let id = app.bundleIdentifier else { return false }
            return app.activationPolicy == .regular
                && id != Bundle.main.bundleIdentifier
                && !switcher.rideAppBundleIDs.contains(id)
                && !app.isTerminated
        }

        if let candidate {
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                userInfo: [NSWorkspace.applicationUserInfoKey: candidate]
            )
            // The switcher listens on the main queue, so let it drain before
            // asking what it learnt.
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            checks.equal(
                switcher.awayDestinationName,
                candidate.localizedName,
                "the workspace's activation notice teaches the switcher where away is"
            )
        } else {
            checks.expect(true, "no other regular app is running, so the workspace notice is not checked")
        }
    }

    checks.group("Button map assignment") {
        var map = ButtonMap.default
        checks.equal(map.assign(.y, to: .shiftUp), .assigned, "a free button is assigned")
        checks.equal(map.button(for: .shiftUp), .y, "the new button shifts up")
        checks.equal(map.button(for: .shiftDown), .b, "the other action is left alone")
        checks.isNil(map.action(for: .shiftUpRight), "the button it moved off is freed")
        checks.equal(map.assign(.y, to: .shiftUp), .unchanged, "re-assigning the same button changes nothing")

        // A button that already drives another action swaps over, so the map can
        // never be left with two actions on one button or a button doing two.
        checks.equal(map.assign(.b, to: .shiftUp), .swapped(freed: .y), "a button in use swaps over")
        checks.equal(map.button(for: .shiftUp), .b, "the button now shifts up")
        checks.equal(map.button(for: .shiftDown), .y, "and the freed button takes the other action")
        checks.equal(map.action(for: .b), .shiftUp, "the map agrees for the new button")
        checks.equal(map.action(for: .y), .shiftDown, "the map agrees for the swapped button")

        // A Mac action can take over a button that shifts, and the shift it
        // displaced is gone rather than remembered somewhere.
        checks.equal(map.assign(.y, to: .volumeUp), .assigned, "a Mac action can take a shift button")
        checks.equal(map.action(for: .y), .volumeUp, "the button changes the volume now")
        checks.isNil(map.button(for: .shiftDown), "and it no longer shifts down")

        checks.equal(map.assign(.y, to: nil), .cleared, "an action can be taken away")
        checks.isNil(map.action(for: .y), "a cleared button does nothing")
        checks.equal(map.assign(.y, to: nil), .unchanged, "clearing an unassigned button changes nothing")

        var settings = GearUpSettings.default
        settings.assign(.z, to: .shiftDown)
        checks.equal(settings.button(for: .shiftDown), .z, "the settings take the new button")
        checks.isNil(settings.buttonMap.action(for: .b), "the button it was on is freed")
        checks.equal(settings.button(for: .shiftUp), .shiftUpRight, "the other action stays put")
        checks.equal(settings.buttonMap.action(for: .z), .shiftDown, "the derived map agrees")
        settings.restoreDefaultButtonMap()
        checks.equal(settings.buttonMap, .default, "the shipped map can be restored")
    }

    checks.group("Button capture") {
        let clock = Clock()
        let router = ButtonRouter(now: { clock.now })
        let recorder = Recorder()
        recorder.attach(to: router)

        router.isCapturingButtons = true
        router.handle(status(plusPress))
        clock.advance(0.3)
        router.handle(status(released))

        checks.equal(recorder.actions, [], "capturing a button runs no action")
        checks.equal(recorder.edges.map(\.0), [.shiftUpRight, .shiftUpRight], "the press and release are still reported")
        checks.equal(recorder.edges.map(\.1), [true, false], "with the press first")

        router.isCapturingButtons = false
        clock.advance(0.3)
        router.handle(status(plusPress))

        checks.equal(recorder.actions, [.shiftUp], "shifting works again once capture stops")
    }

    checks.group("Shift router edges") {
        let clock = Clock()
        let router = ButtonRouter(now: { clock.now })
        let recorder = Recorder()
        recorder.attach(to: router)

        // The captured + press, then the repeats and the release flood the puck
        // sends afterwards.
        router.handle(status(plusPress))
        clock.advance(0.09)
        router.handle(status(plusPress))
        clock.advance(0.12)
        router.handle(status(released))

        checks.equal(recorder.actions, [.shiftUp], "a tap on + shifts up exactly once")
        checks.equal(recorder.edges.count, 2, "the tap is one press and one release edge")
        checks.equal(recorder.repeats, 1, "the repeated pressed report is counted, not acted on")

        // The release flood is harmless.
        for _ in 0..<8 {
            clock.advance(0.1)
            router.handle(status(released))
        }

        checks.equal(recorder.actions, [.shiftUp], "the release flood adds no shifts")
        checks.equal(router.heldButtons, [], "nothing is held after the release")

        // Two taps in a row are two shifts.
        clock.advance(1)
        router.handle(status(bPress))
        clock.advance(0.2)
        router.handle(status(released))
        checks.equal(recorder.actions, [.shiftUp, .shiftDown], "B shifts down")
    }

    checks.group("Shift router reads the real bits") {
        func actions(for bytes: [UInt8]) -> [ButtonAction] {
            let clock = Clock()
            let router = ButtonRouter(now: { clock.now })
            return router.handle(status(bytes))
        }

        checks.equal(actions(for: plusPress), [.shiftUp], "+ shifts up")
        checks.equal(actions(for: bPress), [.shiftDown], "B shifts down")
        checks.equal(actions(for: yPress), [], "Y is ignored while unassigned")
        checks.equal(actions(for: zPress), [], "Z is ignored while unassigned")
        checks.equal(actions(for: aPress), [], "A is ignored while unassigned")
        checks.equal(actions(for: released), [], "a released report shifts nothing")
    }

    checks.group("Shift router recovery") {
        let clock = Clock()
        let router = ButtonRouter(now: { clock.now })
        let recorder = Recorder()
        recorder.attach(to: router)

        // The release notification is lost: the puck never reports it. The same
        // pressed state arriving much later must count as a new press rather
        // than a stuck button.
        router.handle(status(plusPress))
        clock.advance(0.9)
        router.handle(status(plusPress))
        checks.equal(recorder.actions, [.shiftUp], "a repeat inside the window is still ignored")

        clock.advance(1.6)
        router.handle(status(plusPress))
        checks.equal(recorder.actions, [.shiftUp, .shiftUp], "a repeat after the window counts as a new press")

        router.reset()
        checks.equal(router.heldButtons, [], "reset clears the held state")
    }

    checks.group("Shift router unassigned buttons") {
        let clock = Clock()
        let router = ButtonRouter(now: { clock.now })
        let recorder = Recorder()
        recorder.attach(to: router)

        router.handle(status(zPress))
        clock.advance(0.3)
        router.handle(status(released))

        checks.equal(recorder.actions, [], "Z produces no action")
        checks.equal(recorder.edges.count, 2, "Z is still reported as a press and release")
        checks.equal(recorder.edges.first?.0, .z, "the reported button is Z")
        checks.equal(recorder.edges.first?.1, true, "the first edge is a press")
    }

    checks.group("Mac action arithmetic") {
        // The one piece of the Mac actions that can be checked without a Mac's
        // audio device in the loop: the volume step and its clamps.
        checks.equal(MacControl.volumeStep, 0.0625, "a volume press is one sixteenth, like the volume keys")
        checks.equal(MacControl.steppedVolume(from: 0.5, by: MacControl.volumeStep), 0.5625, "up moves by one step")
        checks.equal(MacControl.steppedVolume(from: 0.5, by: -MacControl.volumeStep), 0.4375, "down moves by one step")
        checks.equal(MacControl.steppedVolume(from: 0.98, by: MacControl.volumeStep), 1, "the top is clamped")
        checks.equal(MacControl.steppedVolume(from: 0.02, by: -MacControl.volumeStep), 0, "the bottom is clamped")
    }
}

// MARK: - Settings

func runSettingsChecks(_ checks: Checks) {
    checks.group("Settings defaults") {
        let settings = GearUpSettings.default
        checks.equal(settings.gearCount, 30, "the default readout matches MyWhoosh at 30 gears")
        checks.equal(settings.startingGear, 15, "the default starting gear is 15")
        checks.equal(settings.transportMode, .both, "both transports are offered by default")
        checks.equal(settings.showInMenuBar, true, "the menu bar extra is on by default")
        checks.equal(settings.button(for: .shiftUp), .shiftUpRight, "the default shift-up button is +")
        checks.equal(settings.button(for: .shiftDown), .b, "the default shift-down button is B")
        checks.isNil(settings.button(for: .volumeUp), "the volume buttons start unassigned")
        checks.equal(settings.usesDesktopSwitching, false, "changing desktops is off until a button asks for it")
        checks.equal(settings.buttonMap, .default, "the button map comes from the settings")
    }

    checks.group("Settings clamping") {
        checks.equal(GearUpSettings(gearCount: 0).gearCount, 1, "gear count cannot go below 1")
        checks.equal(GearUpSettings(gearCount: 99).gearCount, 30, "gear count cannot go above 30")
        checks.equal(
            GearUpSettings(gearCount: 5, startingGear: 15).startingGear,
            5,
            "the starting gear cannot sit above the gear count"
        )

        var narrowing = GearUpSettings()
        narrowing.gearCount = 10
        checks.equal(narrowing.startingGear, 10, "narrowing the range brings the starting gear down with it")
    }

    checks.group("Settings persistence") {
        let suite = "gearup.checks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return checks.expect(false, "could not create a UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        checks.equal(store.load(), .default, "an empty store loads the defaults")

        var settings = GearUpSettings.default
        settings.gearCount = 24
        settings.transportMode = .network
        settings.showInMenuBar = false
        settings.assign(.y, to: .shiftUp)
        settings.assign(.z, to: .volumeUp)
        store.save(settings)

        let reloaded = SettingsStore(defaults: defaults).load()
        checks.equal(reloaded, settings, "settings survive a round trip through UserDefaults")
        checks.equal(reloaded.button(for: .shiftUp), .y, "a remapped shift-up button survives")
        checks.equal(reloaded.button(for: .volumeUp), .z, "a Mac action survives")
        checks.equal(reloaded.usesDesktopSwitching, false, "no desktop action was assigned")

        // A blob written before the readout moved to MyWhoosh's 30 gears has no
        // `startingGear` key at all. Its gear count must move to the new default
        // while every other preference survives.
        var beforeThirtyGears = GearUpSettings.default
        beforeThirtyGears.transportMode = .network
        beforeThirtyGears.showInMenuBar = false
        beforeThirtyGears.assign(.y, to: .shiftUp)

        if let encoded = try? JSONEncoder().encode(beforeThirtyGears),
           let parsed = try? JSONSerialization.jsonObject(with: encoded),
           var object = parsed as? [String: Any] {
            object["gearCount"] = 12
            object.removeValue(forKey: "startingGear")

            if let legacyBlob = try? JSONSerialization.data(withJSONObject: object) {
                defaults.set(legacyBlob, forKey: "gearup.settings")
                let migrated = store.load()
                checks.equal(migrated.gearCount, 30, "a 12-gear blob moves to the new 30-gear default")
                checks.equal(migrated.startingGear, 15, "a migrated blob starts in gear 15")
                checks.equal(migrated.transportMode, .network, "a migrated blob keeps its transport")
                checks.equal(migrated.showInMenuBar, false, "a migrated blob keeps its menu bar choice")
                checks.equal(migrated.button(for: .shiftUp), .y, "a migrated blob keeps its button map")
            } else {
                checks.expect(false, "could not re-encode a pre-30-gear settings blob")
            }
        } else {
            checks.expect(false, "could not build a pre-30-gear settings blob")
        }

        // A blob from when a button could only shift: the two old keys and no
        // assignment list. They are exactly the map to carry over, and they must
        // not be lost on the next save.
        let shiftOnlyBlob: [String: Any] = [
            "gearCount": 30,
            "startingGear": 15,
            "transportMode": "network",
            "showInMenuBar": false,
            "shiftUpButton": RideButtonMask.y.rawValue,
            "shiftDownButton": RideButtonMask.z.rawValue,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: shiftOnlyBlob) {
            defaults.set(data, forKey: "gearup.settings")
            let migrated = store.load()
            checks.equal(migrated.button(for: .shiftUp), .y, "an old shift-only blob keeps its shift-up button")
            checks.equal(migrated.button(for: .shiftDown), .z, "an old shift-only blob keeps its shift-down button")
            checks.equal(migrated.buttonAssignments.count, 2, "and nothing else is invented")

            store.save(migrated)
            let resaved = store.load()
            checks.equal(resaved.buttonMap, migrated.buttonMap, "the migrated map survives the next save")
        } else {
            checks.expect(false, "could not build a shift-only settings blob")
        }

        defaults.set(Data("not json".utf8), forKey: "gearup.settings")
        checks.equal(store.load(), .default, "corrupt settings fall back to the defaults")
    }

    checks.group("Transport modes") {
        checks.equal(TransportMode.both.kinds, [.bluetooth, .network], "both means both")
        checks.equal(TransportMode.network.kinds, [.network], "network only means network")
        checks.equal(TransportMode.bluetooth.includesNetwork, false, "Bluetooth only excludes the network")
        checks.equal(TransportMode.network.includesNetwork, true, "network only includes the network")
        checks.equal(TransportMode.allCases.count, 3, "there are three transport modes")
    }
}

// MARK: - OpenBikeControl

func runOpenBikeBridgeChecks(_ checks: Checks) {
    let appInfo: [UInt8] = {
        var bytes: [UInt8] = [0x04, 0x01]
        let id = Array("MyWhoosh".utf8)
        bytes.append(UInt8(id.count))
        bytes.append(contentsOf: id)
        let version = Array("1.2.3".utf8)
        bytes.append(UInt8(version.count))
        bytes.append(contentsOf: version)
        bytes.append(0x02)
        bytes.append(contentsOf: [0x01, 0x02])
        return bytes
    }()

    checks.group("App info reassembly") {
        var assembler = OpenBikeAppInfoReassembler()
        let info = assembler.offer(appInfo)
        checks.equal(info?.appID, "MyWhoosh", "a whole app-info write parses")
        checks.equal(info?.appVersion, "1.2.3", "the version is read")
        checks.equal(info?.supportedButtons, [0x01, 0x02], "the supported buttons are read")
        checks.isNil(assembler.lastProblem, "a clean write reports no problem")
    }

    checks.group("App info split across writes") {
        // TrainingPeaks on macOS writes the message in fragments.
        var assembler = OpenBikeAppInfoReassembler()
        var parsed: OpenBikeAppInfo?
        for (index, byte) in appInfo.enumerated() {
            if let info = assembler.offer([byte]) {
                parsed = info
                checks.equal(index, appInfo.count - 1, "the message completes on its last byte")
            }
        }
        checks.equal(parsed?.appID, "MyWhoosh", "a byte-at-a-time write reassembles")
        checks.equal(parsed?.supportedButtons, [0x01, 0x02], "the reassembled buttons are right")

        var chunked = OpenBikeAppInfoReassembler()
        let first = Array(appInfo.prefix(5))
        let second = Array(appInfo.dropFirst(5).prefix(3))
        let third = Array(appInfo.dropFirst(8))
        checks.isNil(chunked.offer(first), "the first fragment is not enough")
        checks.isNil(chunked.lastProblem, "an incomplete message is not reported as a problem")
        checks.isNil(chunked.offer(second), "the second fragment is not enough")
        checks.equal(chunked.offer(third)?.appID, "MyWhoosh", "three fragments reassemble")
    }

    checks.group("App info resynchronisation") {
        var assembler = OpenBikeAppInfoReassembler()
        // A stray byte in front of a valid message must not poison the parse.
        checks.isNil(assembler.offer([0x00]), "the stray byte alone yields nothing")
        checks.expect(assembler.lastProblem != nil, "the stray byte is reported as a problem")
        checks.equal(assembler.offer(appInfo)?.appID, "MyWhoosh", "the message after it still parses")

        // A disconnecting central must not leave half a message behind.
        var reset = OpenBikeAppInfoReassembler()
        _ = reset.offer(Array(appInfo.prefix(4)))
        reset.reset()
        checks.equal(reset.pendingByteCount, 0, "reset drops the buffered fragment")
        checks.equal(reset.offer(appInfo)?.appID, "MyWhoosh", "a fresh message parses after a reset")
    }

    checks.group("OpenBikeControl button messages") {
        checks.equal(
            OpenBikeCodec.encodeButton(.shiftUp, pressed: true),
            [0x01, 0x01, 0x01],
            "shift up as pressed is 01 01 01"
        )
        checks.equal(
            OpenBikeCodec.encodeButton(.shiftDown, pressed: false),
            [0x01, 0x02, 0x00],
            "shift down as released is 01 02 00"
        )

        let tap = OpenBikeCodec.encodeButtonTap(.shiftUp)
        checks.equal(tap.count, 2, "a tap is two messages")
        checks.equal(tap.first, [0x01, 0x01, 0x01], "the tap presses first")
        checks.equal(tap.last, [0x01, 0x01, 0x00], "the tap releases second")
    }

    checks.group("mDNS TXT record") {
        let data = OpenBikeNetworkServer.txtRecordData(["version": "1", "name": "GearUp"])
        // Entries are a length byte followed by "key=value", sorted by key.
        checks.equal(Array(data.prefix(1)), [0x0B], "the first entry is 11 bytes: name=GearUp")
        checks.equal(
            String(decoding: data.prefix(12).dropFirst(), as: UTF8.self),
            "name=GearUp",
            "the first entry is name=GearUp"
        )
        let text = String(decoding: data, as: UTF8.self)
        checks.expect(text.contains("name=GearUp"), "the record carries the instance name")
        checks.expect(text.contains("version=1"), "the record carries the protocol version")

        let entries = OpenBikeNetworkServer.txtRecordEntries
        checks.equal(
            entries["service-uuids"],
            OpenBikeUUID.service.lowercased(),
            "the record advertises the OpenBikeControl service UUID"
        )
        checks.equal(OpenBikeNetworkServer.preferredPort, 36867, "the preferred port matches the reference")
        checks.equal(OpenBikeNetworkServer.serviceType, "_openbikecontrol._tcp", "the service type matches")
    }
}
