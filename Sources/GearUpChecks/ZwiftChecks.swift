import GearUpCore

func runZwiftChecks(_ checks: Checks) {
    // Sample keypad report from the public reverse-engineering write-up for the
    // Zwift Ride: left-arrow pressed, paddles centred.
    let rideSample: [UInt8] = [
        0x23,
        0x08, 0xFE, 0xFF, 0xFF, 0xFF, 0x0F,
        0x12, 0x18,
        0x0A, 0x04, 0x08, 0x00, 0x10, 0x00,
        0x0A, 0x04, 0x08, 0x01, 0x10, 0x00,
        0x0A, 0x04, 0x08, 0x02, 0x10, 0x00,
        0x0A, 0x04, 0x08, 0x03, 0x10, 0x00,
    ]

    checks.group("Zwift keypad decoding") {
        guard let notification = ZwiftClickCodec.decode(rideSample),
              case .rideKeyPad(let status) = notification else {
            checks.expect(false, "the sample report decodes to a RideKeyPadStatus")
            return
        }
        checks.equal(status.buttonMap, 0xFFFF_FFFE, "the button map is decoded")
        checks.equal(status.pressedBitIndices, [0], "only bit 0 is cleared")
        checks.equal(status.pressedButtons, [.left], "bit 0 maps to the left button")
        checks.equal(status.analogPaddles.count, 4, "all four analog paddles are decoded")
        checks.equal(status.analogPaddles.first, RideAnalogKeyPress(location: 0, value: 0), "first paddle")
        checks.equal(status.analogPaddles.dropFirst().first, RideAnalogKeyPress(location: 1, value: 0), "second paddle")
    }

    checks.group("Zwift keypad inversion") {
        // 0x0FFFFFFF has every defined bit set, which means released.
        let idle: [UInt8] = [0x08] + varint(0x0FFF_FFFF)
        guard let status = RideKeyPadStatus.decode(idle) else {
            checks.expect(false, "the idle report decodes")
            return
        }
        checks.equal(status.buttonMap, 0x0FFF_FFFF, "the idle button map is 0x0FFFFFFF")
        checks.equal(status.pressedButtons, [], "an idle controller has nothing pressed")

        let bPressed = UInt32(0x0FFF_FFFF) & ~UInt32(RideButtonMask.b.rawValue)
        let payload: [UInt8] = [0x08] + varint(UInt64(bPressed))
        guard let pressed = RideKeyPadStatus.decode(payload) else {
            checks.expect(false, "a report with B pressed decodes")
            return
        }
        checks.equal(pressed.pressedButtons, [.b], "clearing the B bit means B is pressed")
    }

    checks.group("Zwift analog paddles") {
        // Analog groups nest their entries as repeated field-1, e.g.
        //   12 06  0A 04 08 00 10 53
        // where `0A 04` wraps one entry: location 0, value -42 (sint32).
        let zigZag = UInt64(bitPattern: (Int64(-42) << 1) ^ (Int64(-42) >> 63))
        let inner: [UInt8] = [0x08, 0x00, 0x10] + varint(zigZag)
        let group: [UInt8] = [0x0A, UInt8(inner.count)] + inner
        var payload: [UInt8] = [0x08] + varint(0x0FFF_FFFF)
        payload.append(0x12)
        payload.append(UInt8(group.count))
        payload.append(contentsOf: group)

        guard let status = RideKeyPadStatus.decode(payload) else {
            checks.expect(false, "a report with an analog value decodes")
            return
        }
        checks.equal(status.analogPaddles, [RideAnalogKeyPress(location: 0, value: -42)], "negative paddles are zig-zag decoded")
    }

    checks.group("Zwift Click V1 keypad") {
        let notification = ZwiftClickCodec.decode(type: 0x37, payload: [0x08, 0x00])
        guard case .clickKeyPad(let status) = notification else {
            checks.expect(false, "payload 08 00 decodes to a ClickKeyPadStatus")
            return
        }
        checks.equal(status.plusPressed, true, "field 1 set to ON means plus is pressed")
        checks.isNil(status.minusPressed, "an omitted field is not reported as pressed")

        guard let released = ClickKeyPadStatus.decode([0x10, 0x01]) else {
            checks.expect(false, "payload 10 01 decodes")
            return
        }
        checks.isNil(released.plusPressed, "field 1 omitted is not reported as pressed")
        checks.equal(released.minusPressed, false, "field 2 set to OFF means minus is released")
    }

    checks.group("Zwift message envelope") {
        // BatteryNotification: field 1 = charging state (0), field 2 = 90%.
        checks.equal(
            ZwiftClickCodec.decode(type: 0x19, payload: [0x08, 0x00, 0x10, 0x5A]),
            .battery(level: 90, chargingState: 0, raw: [0x08, 0x00, 0x10, 0x5A]),
            "battery notification decodes the percentage from field 2"
        )
        checks.equal(
            ZwiftClickCodec.decode(type: 0x1A, payload: [0x08, 0x01, 0x10, 0x64]),
            .battery(level: 100, chargingState: 1, raw: [0x08, 0x01, 0x10, 0x64]),
            "battery status decodes the percentage from field 2"
        )
        checks.equal(ZwiftClickCodec.decode(type: 0x15, payload: []), .empty, "empty keep-alive")
        checks.equal(ZwiftClickCodec.decode(type: 0xFE, payload: []), .disconnect, "disconnect")
        checks.equal(
            ZwiftClickCodec.clickV2StartCommand.hexString,
            "52 69 64 65 4f 6e 02 03",
            "the Click V2 start command is RideOn plus 0x02 0x03"
        )
        checks.equal(ZwiftClickCodec.rideOn.hexString, "52 69 64 65 4f 6e", "the plain handshake is RideOn")
    }

    checks.group("Zwift button bit values") {
        // Confirmed against a real Click V2 (right puck). Zwift's published
        // RideButtonMask enum is not the wire mask: it skips 0x80.
        checks.equal(RideButtonMask.a.rawValue, 0x10, "A is 0x10")
        checks.equal(RideButtonMask.b.rawValue, 0x20, "B is 0x20")
        checks.equal(RideButtonMask.y.rawValue, 0x40, "Y is 0x40")
        checks.equal(RideButtonMask.z.rawValue, 0x80, "Z is 0x80 (the enum skips this bit)")
        checks.equal(RideButtonMask.z.bit, 7, "Z is bit 7")
        checks.equal(RideButtonMask.shiftUpRight.rawValue, 0x1000, "+ is 0x1000")
        checks.equal(RideButtonMask.shiftUpRight.bit, 12, "+ is bit 12")
        checks.equal(RideButtonMask.shiftDownRight.rawValue, 0x2000, "shift down right is 0x2000")
        checks.equal(RideButtonMask.onOffRight.rawValue, 0x8000, "on/off right is 0x8000")

        // A right Click V2 idles at 0xFFFFFFFF, then clears the pressed bit.
        let idle = UInt32(0xFFFF_FFFF)
        let pressed = RideButtonMask.allCases.filter { idle & $0.rawValue == 0 }
        checks.equal(pressed, [], "an idle right puck reports no button as pressed")
    }

    checks.group("Zwift Click V2 hardware capture") {
        // Raw notifications recorded from the right puck while pressing each
        // button once, in order Y, Z, B, A, +.
        let captured: [(name: String, bytes: [UInt8], expected: RideButtonMask)] = [
            ("Y", [0x23, 0x08, 0xBF, 0xFF, 0xFF, 0xFF, 0x0F], .y),
            ("Z", [0x23, 0x08, 0xFF, 0xFE, 0xFF, 0xFF, 0x0F], .z),
            ("B", [0x23, 0x08, 0xDF, 0xFF, 0xFF, 0xFF, 0x0F], .b),
            ("A", [0x23, 0x08, 0xEF, 0xFF, 0xFF, 0xFF, 0x0F], .a),
            ("+", [0x23, 0x08, 0xFF, 0xDF, 0xFF, 0xFF, 0x0F], .shiftUpRight),
        ]

        for sample in captured {
            guard let notification = ZwiftClickCodec.decode(sample.bytes),
                  case .rideKeyPad(let status) = notification else {
                checks.expect(false, "\(sample.name) decodes to a keypad report")
                continue
            }
            checks.equal(status.pressedButtons, [sample.expected], "\(sample.name) decodes to \(sample.expected.name)")
        }

        // The release report the puck repeats while nothing is held.
        guard let idle = ZwiftClickCodec.decode([0x23, 0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F]),
              case .rideKeyPad(let idleStatus) = idle else {
            return checks.expect(false, "the idle report decodes")
        }
        checks.equal(idleStatus.pressedButtons, [], "the idle report has nothing pressed")
        checks.equal(idleStatus.buttonMap, 0xFFFF_FFFF, "the right puck idles at 0xFFFFFFFF")

        // The device answers the handshake by echoing RideOn back. Its first
        // byte is ASCII 'R' (0x52), which must not be read as an opcode.
        let handshake = ZwiftClickCodec.decode([0x52, 0x69, 0x64, 0x65, 0x4F, 0x6E, 0x02, 0x03])
        checks.equal(
            handshake,
            .handshake([0x52, 0x69, 0x64, 0x65, 0x4F, 0x6E, 0x02, 0x03]),
            "the RideOn echo is recognised as a handshake acknowledgement"
        )
    }

    checks.group("Click V2 keep-awake") {
        // The puck sleeps 60 seconds after the last press and comes back only on a
        // button press, so the hold resets it during quiet spells: the window is
        // the puck's own, and a press opens a fresh one.
        checks.expect(
            ClickCentral.defaultIdleResetThreshold < 60,
            "a quiet puck is reset before its ~60 s sleep (\(Int(ClickCentral.defaultIdleResetThreshold)) s)"
        )
        checks.expect(
            ClickCentral.defaultIdleResetThreshold >= 30,
            "and not before it needs to be: while the rider is shifting, GearUp writes nothing"
        )
        checks.expect(
            ClickCentral.watchInterval < ClickCentral.defaultIdleResetThreshold,
            "the clock is looked at more often than the threshold it watches"
        )

        // A reset is a reboot, which is why the hold needs both the retry and the
        // start command: measured, the link went 0.12 s after the reset and came
        // back when the retry asked for it.
        checks.equal(
            ZwiftClickCodec.resetCommand,
            [0x18],
            "RESET is opcode 24 with no payload"
        )
        checks.equal(
            ClickCentral.resetCommand,
            ZwiftClickCodec.resetCommand,
            "the hold resets the puck with that command"
        )
        checks.equal(
            ZwiftClickCodec.resetCommand(procedure: 1),
            [0x18, 0x08, 0x01],
            "a reset procedure is the same opcode with field 1"
        )
        checks.expect(
            ClickCentral.restartDelay > 0 && ClickCentral.restartDelay < ClickCentral.watchInterval,
            "the puck is started again \(ClickCentral.restartDelay) s after the reset, before the clock is next read"
        )
        checks.expect(
            ClickCentral.reconnectInterval <= 1,
            "the link is asked for within a second of a reset, so the ask is never the delay"
        )
        checks.expect(
            ClickCentral.resetDropWindow > ClickCentral.restartDelay,
            "the drop a reset causes is recognised as GearUp's own, not as the puck's"
        )

        // The reads ride on the connection that just came up, and each is a `Get`
        // for one data object. The Info-Request is not a keep-awake: sent every 5 s
        // for a whole minute, the puck answered and the link still died 61 s after
        // the last press.
        checks.equal(
            ZwiftClickCodec.getCommand(dataObjectID: ZwiftClickCodec.deviceInfoObjectID),
            [0x00, 0x08, 0x00],
            "a read is command 0 with the data object id in field 1"
        )
        checks.equal(
            ZwiftClickCodec.infoRequest,
            ZwiftClickCodec.getCommand(dataObjectID: ZwiftClickCodec.deviceInfoObjectID),
            "the info request is a read of the device info"
        )
        checks.equal(
            ZwiftClickCodec.batteryRequest,
            [0x00, 0x08, 0x83, 0x06],
            "the battery object 771 encodes as 83 06"
        )
        checks.equal(
            ZwiftClickCodec.securityRequest,
            [0x00, 0x08, 0x40],
            "the BLE security page 64 encodes as 40"
        )
        checks.expect(
            ClickCentral.batteryInterval >= 60 && ClickCentral.batteryInterval <= 900,
            "a held puck is asked about its battery, but only a few times an hour"
        )

        // The hold also has to end. A rider on a long descent or a steady stretch is
        // not shifting, so there is no shift for a reset to save and a reboot every
        // forty seconds would be spent on nothing. Past the release threshold GearUp
        // stops resetting and lets the puck sleep: measured, the retry then catches
        // the wake-up and the press that wakes it is not reported, which is the price
        // the rider accepted for the battery.
        checks.expect(
            ClickCentral.defaultIdleReleaseThreshold > ClickCentral.defaultIdleResetThreshold,
            "the hold gives up long after it would have started resetting"
        )
        checks.expect(
            ClickCentral.defaultIdleReleaseThreshold >= 120,
            "and only after minutes of silence, never a rider's pause between efforts"
        )
        checks.expect(
            ClickCentral.defaultIdleReleaseThreshold <= 600,
            "so a bike left parked sleeps within minutes rather than being rebooted all afternoon"
        )

        // A sleeping puck and a puck out of range report the same error, so the only
        // way to tell the mechanism working from a fault is the clock: the sleep
        // arrives a minute after the last sign of life and an ordinary drop does not.
        checks.expect(
            ClickCentral.sleepDropWindow > ClickCentral.resetDropWindow,
            "a drop is only read as the puck's sleep long after a reset could explain it"
        )
        checks.expect(
            ClickCentral.sleepDropWindow < 60,
            "and before the sleep itself, so a puck that really went missing is not excused"
        )

        // Getting a dropped puck back is not part of the hold. A pending connect
        // costs the puck nothing — it is the same radio silence as scanning, and a
        // puck in standby is powered down either way — so a link that dropped while
        // GearUp is running is always waited for. This is what an app left open all
        // evening needs: the press that wakes the puck is answered, and the press
        // after it does its job. The one exception is GearUp letting go on purpose,
        // where a stopped bridge must stay stopped.
        checks.expect(
            ClickCentral.shouldReconnectAfterDrop(bridgeIsRunning: true, deliberate: false),
            "a drop is retried even when nothing is held or connected"
        )
        checks.expect(
            ClickCentral.shouldReconnectAfterDrop(bridgeIsRunning: true, deliberate: true) == false,
            "a bridge that let the puck go on purpose does not grab it back"
        )
        checks.expect(
            ClickCentral.shouldReconnectAfterDrop(bridgeIsRunning: false, deliberate: false) == false,
            "and a stopped bridge does not retry at all"
        )
    }

    checks.group("Click V2 data objects") {
        // Neither of these two answers has been seen on hardware yet, so their
        // fixtures are built from the field numbers in Zwift's protocol rather than
        // captured: BatteryStatus { chgState, percLevel, timeToEmpty, timeToFull },
        // and the BleSecurityPage { secureConnectionStatus, windowStatus }.
        let battery = ZwiftDataObject.split(answer: [
            0x08, 0x83, 0x06, 0x12, 0x09, 0x0A, 0x07, 0x08, 0x00, 0x10, 0x4E, 0x18, 0xF0, 0x01,
        ]).flatMap(ZwiftBatteryStatus.decode)
        checks.equal(battery?.level, 78, "the battery level comes back")
        checks.equal(battery?.charging, "not charging", "so does the charging state")
        checks.equal(battery?.minutesToEmpty, 240, "and the minutes it thinks it has left")
        checks.expect(
            (battery?.summary ?? "").hasPrefix("78%"),
            "the summary leads with the level"
        )
        checks.equal(
            ZwiftBatteryStatus.duration(45),
            "45 min",
            "a forecast under the hour is quoted in minutes"
        )
        checks.equal(
            ZwiftBatteryStatus.duration(240),
            "4 h",
            "and above it in whole hours, so a forecast is not read as a countdown"
        )
        checks.equal(
            ZwiftBatteryStatus.duration(2773),
            "46 h",
            "which is what the puck's own reading on the bench reads as"
        )

        let security = ZwiftDataObject.split(answer: [
            0x08, 0x40, 0x12, 0x06, 0x0A, 0x04, 0x08, 0x02, 0x10, 0x01,
        ]).flatMap(ZwiftSecurityStatus.decode)
        checks.equal(security?.connection, "active", "the secure connection state comes back")
        checks.equal(security?.window, "open", "so does the pairing window")
        checks.expect(security?.isActive == true, "and it reads as paired")

        // What the puck here actually answered the security request with: the id
        // and nothing else, because every field is at its protocol default. It is a
        // real reading — not paired, no window — and not a missing answer.
        let unpaired = ZwiftDataObject.split(answer: [0x08, 0x40])
            .flatMap(ZwiftSecurityStatus.decode)
        checks.equal(unpaired?.connection, "none", "an empty security answer means the default: not paired")
        checks.equal(unpaired?.window, "closed", "and no pairing window open")
        checks.expect(unpaired?.isActive == false, "which is the flashing LED on the puck")

        checks.expect(
            !(battery?.summary ?? "").contains("to full"),
            "a puck that is not charging is not told how long a charge would take"
        )

        let notBattery = ZwiftDataObject.split(answer: [0x08, 0x00, 0x12, 0x02, 0x0A, 0x00])
        checks.expect(
            notBattery.flatMap(ZwiftBatteryStatus.decode) == nil,
            "the battery decoder refuses an object that is not the battery"
        )
        checks.expect(
            notBattery.flatMap(ZwiftSecurityStatus.decode) == nil,
            "and so does the security one"
        )
    }

    checks.group("Click V2 device info") {
        // The bytes the puck answered with on real hardware, so the decoder is
        // pinned to what a Click V2 actually sends rather than to a tidy guess.
        let payload: [UInt8] = [
            0x08, 0x00, 0x12, 0x46, 0x0A, 0x44, 0x08, 0x83, 0x04, 0x12, 0x04, 0x00, 0x00,
            0x02, 0x01, 0x1A, 0x0B, 0x5A, 0x77, 0x69, 0x66, 0x74, 0x20, 0x43, 0x6C, 0x69,
            0x63, 0x6B, 0x32, 0x0F, 0x30, 0x41, 0x2D, 0x44, 0x34, 0x30, 0x36, 0x30, 0x46,
            0x39, 0x33, 0x30, 0x45, 0x39, 0x35, 0x3A, 0x03, 0x42, 0x2E, 0x30, 0x42, 0x04,
            0x08, 0x02, 0x10, 0x01, 0x48, 0x01, 0x50, 0x0A, 0x5A, 0x0C, 0x44, 0x34, 0x30,
            0x36, 0x30, 0x46, 0x39, 0x33, 0x30, 0x45, 0x39, 0x35,
        ]
        let info = ZwiftDevInfoPage.decode(getResponse: payload)
        checks.equal(info?.objectID, 0, "the answer is for data object 0, the device info")
        checks.equal(info?.name, "Zwift Click", "the puck names itself")
        checks.equal(info?.protocolVersion, 515, "the protocol version is 515")
        checks.equal(info?.hardware, "B.0", "the hardware revision reads B.0")
        checks.equal(info?.firmwareVersion, "1.2.0", "the firmware word reads 1.2.0")
        checks.equal(info?.serial, "0A-D4060F930E95", "the serial number is carried whole")
        checks.equal(info?.uid, "D4060F930E95", "so is the device uid")
        checks.expect(
            ZwiftDevInfoPage.decode(getResponse: [0x08, 0x00]) == nil,
            "an answer with no page to it decodes as nothing rather than as empty strings"
        )
    }

    checks.group("Zwift UUID matching") {
        // CoreBluetooth reports SIG UUIDs in short form, which is what broke
        // service discovery against a real Click V2.
        checks.expect(
            ZwiftUUID.isCustomService("FC82"),
            "a short FC82 matches the modern Zwift custom service"
        )
        checks.expect(
            ZwiftUUID.isCustomService("0000FC82-0000-1000-8000-00805F9B34FB"),
            "the long form still matches"
        )
        checks.expect(
            !ZwiftUUID.isCustomService("180A"),
            "the device information service is not a Zwift service"
        )
        checks.expect(
            ZwiftUUID.isCharacteristic("00000002-19CA-4651-86E5-FA29DCDD09D1", ZwiftUUID.asyncCharacteristic),
            "the async characteristic matches itself"
        )
    }

    checks.group("Hex helpers") {
        checks.equal([0x01, 0x0A, 0xFF].hexString, "01 0a ff", "spaced lowercase hex")
        checks.equal([0x01, 0x0A, 0xFF].compactHexString, "010AFF", "compact uppercase hex")
        checks.equal([UInt8].fromHex("01 0a ff"), [0x01, 0x0A, 0xFF], "parse spaced hex")
        checks.equal([UInt8].fromHex("010aff"), [0x01, 0x0A, 0xFF], "parse compact hex")
        checks.equal([UInt8].fromHex("0a f"), [0x0A, 0x0F], "parse single-digit space-separated hex")
        checks.isNil([UInt8].fromHex("0a gg"), "reject non-hex tokens")
    }
}

/// Little-endian base-128 varint encoding, used to build test fixtures.
func varint(_ value: UInt64) -> [UInt8] {
    var value = value
    var bytes: [UInt8] = []
    repeat {
        var byte = UInt8(value & 0x7F)
        value >>= 7
        if value != 0 { byte |= 0x80 }
        bytes.append(byte)
    } while value != 0
    return bytes
}
