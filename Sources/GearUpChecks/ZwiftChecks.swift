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
        checks.equal(
            ZwiftClickCodec.decode(type: 0x19, payload: [0x00, 0x5A]),
            .battery(level: 90, raw: [0x00, 0x5A]),
            "legacy battery level"
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
