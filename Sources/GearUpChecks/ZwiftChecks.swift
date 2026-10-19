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
        // The keep-alive is the Info-Request, not the `RideOn` header: bare
        // headers every 20 s were answered three times on real hardware and the
        // link still died 61 s after the last press, so the write has to be this
        // one.
        checks.equal(
            ClickCentral.keepAliveCommand,
            ZwiftClickCodec.infoRequest,
            "the keep-alive writes the Info-Request"
        )
        checks.expect(
            ClickCentral.keepAliveCommand != ZwiftClickCodec.rideOn,
            "the bare RideOn header is not the keep-alive: the puck echoes it, then sleeps anyway"
        )

        // Two implementations bracket the cadence: one warns that at 15 s its
        // Clicks slept, the other writes every 5 s. GearUp's own log agrees that
        // the puck stops answering well before the link drops at ~60 s.
        checks.expect(
            ClickCentral.defaultKeepAliveInterval * 2 <= 15,
            "two keep-alives fit inside the ~15 s window (\(Int(ClickCentral.defaultKeepAliveInterval)) s apart)"
        )
        checks.expect(
            ClickCentral.defaultKeepAliveInterval < 60,
            "the keep-alive lands long before the puck's ~60 s link drop"
        )
        checks.expect(
            ClickCentral.reconnectInterval < ClickCentral.defaultKeepAliveInterval,
            "a dropped link is retried sooner than the keep-alive is written"
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
