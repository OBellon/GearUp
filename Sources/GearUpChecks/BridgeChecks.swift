import Foundation
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
        var shifts: [ShiftAction] = []
        var edges: [(RideButtonMask, Bool)] = []
        var repeats = 0

        func attach(to router: ShiftRouter) {
            router.onShift = { [weak self] action, _ in self?.shifts.append(action) }
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
        checks.equal(map.shiftUp, .shiftUpRight, "the + button shifts up by default")
        checks.equal(map.shiftDown, .b, "the B button shifts down by default")
        checks.equal(map.action(for: .shiftUpRight), .shiftUp, "+ maps to shift up")
        checks.equal(map.action(for: .b), .shiftDown, "B maps to shift down")
        checks.equal(map.action(for: .y), .none, "Y is unassigned")
        checks.equal(map.action(for: .z), .none, "Z is unassigned")
        checks.equal(map.action(for: .a), .none, "A is unassigned")

        let swapped = ButtonMap(shiftUp: .y, shiftDown: .z)
        checks.equal(swapped.action(for: .y), .shiftUp, "a remapped Y shifts up")
        checks.equal(swapped.action(for: .z), .shiftDown, "a remapped Z shifts down")
        checks.equal(swapped.action(for: .shiftUpRight), .none, "the old + assignment is gone")
        checks.equal(swapped.assignments.count, 2, "two assignments are listed")

        let doubled = ButtonMap(shiftUp: .b, shiftDown: .b)
        checks.equal(doubled.button(for: .shiftDown), nil, "one button cannot do both actions")
        checks.equal(doubled.assignments.count, 1, "a doubled assignment is listed once")
    }

    checks.group("Shift router edges") {
        let clock = Clock()
        let router = ShiftRouter(now: { clock.now })
        let recorder = Recorder()
        recorder.attach(to: router)

        // The captured + press, then the repeats and the release flood the puck
        // sends afterwards.
        router.handle(status(plusPress))
        clock.advance(0.09)
        router.handle(status(plusPress))
        clock.advance(0.12)
        router.handle(status(released))

        checks.equal(recorder.shifts, [.shiftUp], "a tap on + shifts up exactly once")
        checks.equal(recorder.edges.count, 2, "the tap is one press and one release edge")
        checks.equal(recorder.repeats, 1, "the repeated pressed report is counted, not acted on")

        // The release flood is harmless.
        for _ in 0..<8 {
            clock.advance(0.1)
            router.handle(status(released))
        }

        checks.equal(recorder.shifts, [.shiftUp], "the release flood adds no shifts")
        checks.equal(router.heldButtons, [], "nothing is held after the release")

        // Two taps in a row are two shifts.
        clock.advance(1)
        router.handle(status(bPress))
        clock.advance(0.2)
        router.handle(status(released))
        checks.equal(recorder.shifts, [.shiftUp, .shiftDown], "B shifts down")
    }

    checks.group("Shift router reads the real bits") {
        func actions(for bytes: [UInt8]) -> [ShiftAction] {
            let clock = Clock()
            let router = ShiftRouter(now: { clock.now })
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
        let router = ShiftRouter(now: { clock.now })
        let recorder = Recorder()
        recorder.attach(to: router)

        // The release notification is lost: the puck never reports it. The same
        // pressed state arriving much later must count as a new press rather
        // than a stuck button.
        router.handle(status(plusPress))
        clock.advance(0.9)
        router.handle(status(plusPress))
        checks.equal(recorder.shifts, [.shiftUp], "a repeat inside the window is still ignored")

        clock.advance(1.6)
        router.handle(status(plusPress))
        checks.equal(recorder.shifts, [.shiftUp, .shiftUp], "a repeat after the window counts as a new press")

        router.reset()
        checks.equal(router.heldButtons, [], "reset clears the held state")
    }

    checks.group("Shift router unassigned buttons") {
        let clock = Clock()
        let router = ShiftRouter(now: { clock.now })
        let recorder = Recorder()
        recorder.attach(to: router)

        router.handle(status(zPress))
        clock.advance(0.3)
        router.handle(status(released))

        checks.equal(recorder.shifts, [], "Z produces no shift")
        checks.equal(recorder.edges.count, 2, "Z is still reported as a press and release")
        checks.equal(recorder.edges.first?.0, .z, "the reported button is Z")
        checks.equal(recorder.edges.first?.1, true, "the first edge is a press")
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
        checks.equal(settings.shiftUpButton, .shiftUpRight, "the default shift-up button is +")
        checks.equal(settings.shiftDownButton, .b, "the default shift-down button is B")
        checks.equal(settings.buttonMap.shiftUp, .shiftUpRight, "the button map comes from the settings")
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
        settings.shiftUpButton = .y
        store.save(settings)

        let reloaded = SettingsStore(defaults: defaults).load()
        checks.equal(reloaded, settings, "settings survive a round trip through UserDefaults")
        checks.equal(reloaded.shiftUpButton, .y, "a remapped shift-up button survives")

        // A blob written before the readout moved to MyWhoosh's 30 gears has no
        // `startingGear` key at all. Its gear count must move to the new default
        // while every other preference survives.
        var beforeThirtyGears = GearUpSettings.default
        beforeThirtyGears.transportMode = .network
        beforeThirtyGears.showInMenuBar = false
        beforeThirtyGears.shiftUpButton = .y

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
                checks.equal(migrated.shiftUpButton, .y, "a migrated blob keeps its button map")
            } else {
                checks.expect(false, "could not re-encode a pre-30-gear settings blob")
            }
        } else {
            checks.expect(false, "could not build a pre-30-gear settings blob")
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
