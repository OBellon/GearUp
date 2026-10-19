import GearUpCore

func runOpenBikeChecks(_ checks: Checks) {
    checks.group("OpenBikeControl codec") {
        checks.equal(
            OpenBikeCodec.encodeButton(.shiftUp, pressed: true),
            [0x01, 0x01, 0x01],
            "encode a Shift Up press"
        )
        checks.equal(
            OpenBikeCodec.encodeButton(.shiftUp, pressed: false),
            [0x01, 0x01, 0x00],
            "encode a Shift Up release"
        )
        checks.equal(
            OpenBikeCodec.encodeButtonState([
                OpenBikeButtonState(.shiftUp, value: 0x01),
                OpenBikeButtonState(.shiftDown, value: 0x00),
            ]),
            [0x01, 0x01, 0x01, 0x02, 0x00],
            "encode several buttons in one notification"
        )

        let tap = OpenBikeCodec.encodeButtonTap(.shiftDown)
        checks.equal(tap.count, 2, "a tap is two notifications")
        checks.equal(tap.first ?? [], [0x01, 0x02, 0x01], "a tap starts with a press")
        checks.equal(tap.last ?? [], [0x01, 0x02, 0x00], "a tap ends with a release")

        checks.equal(
            OpenBikeCodec.encodeDeviceStatus(battery: 85, connected: true),
            [0x02, 85, 0x01],
            "encode device status with a battery level"
        )
        checks.equal(
            OpenBikeCodec.encodeDeviceStatus(battery: nil, connected: true),
            [0x02, 0xFF, 0x01],
            "encode device status without a battery level"
        )

        checks.equal(
            OpenBikeCodec.decodeButtonState([0x01, 0x01, 0x01, 0x02, 0x00]),
            [
                OpenBikeButtonState(buttonID: 0x01, value: 0x01),
                OpenBikeButtonState(buttonID: 0x02, value: 0x00),
            ],
            "decode a button state notification"
        )
        checks.equal(
            OpenBikeCodec.decodeHaptic([0x03, 0x02, 0x14, 0x80]),
            .haptic(pattern: 0x02, duration: 0x14, intensity: 0x80),
            "decode a haptic message"
        )

        checks.equal(OpenBikeButton.name(for: 0x01), "Shift Up", "Shift Up is button 0x01")
        checks.equal(OpenBikeButton.name(for: 0x02), "Shift Down", "Shift Down is button 0x02")
        checks.equal(OpenBikeButton.name(for: 0x99), "Unknown (0x99)", "unknown buttons are labelled")
    }

    checks.group("OpenBikeControl app info") {
        var bytes: [UInt8] = [0x04, 0x01]
        let appID = Array("mywhoosh".utf8)
        bytes.append(UInt8(appID.count))
        bytes.append(contentsOf: appID)
        let version = Array("1.0.0".utf8)
        bytes.append(UInt8(version.count))
        bytes.append(contentsOf: version)
        bytes.append(2)
        bytes.append(contentsOf: [0x01, 0x02])

        let info = OpenBikeCodec.decodeAppInfo(bytes)
        checks.equal(info?.appID, "mywhoosh", "app identifier is decoded")
        checks.equal(info?.appVersion, "1.0.0", "app version is decoded")
        checks.equal(info?.supportedButtons, [0x01, 0x02], "supported buttons are decoded")

        var allButtons: [UInt8] = [0x04, 0x01, 0x05]
        allButtons.append(contentsOf: Array("rouvy".utf8))
        allButtons.append(0)
        allButtons.append(0)

        let unlimited = OpenBikeCodec.decodeAppInfo(allButtons)
        checks.equal(unlimited?.appID, "rouvy", "app identifier without buttons is decoded")
        checks.isNil(unlimited?.supportedButtons, "a button count of zero means every button")
        checks.equal(unlimited?.supportedButtonNames, ["All buttons"], "button names fall back to All")

        checks.isNil(
            OpenBikeCodec.decodeAppInfo([0x04, 0x01, 0x20, 0x61]),
            "a truncated app info message is rejected"
        )
    }

    checks.group("OpenBikeControl stream framing") {
        var decoder = OpenBikeCodec.StreamDecoder()
        checks.equal(decoder.append([0x03, 0x02]), [], "a partial haptic message yields nothing")
        checks.equal(
            decoder.append([0x14, 0x80]),
            [.haptic(pattern: 0x02, duration: 0x14, intensity: 0x80)],
            "the remainder of the haptic message is framed"
        )

        var message: [UInt8] = [0x04, 0x01, 0x08]
        message.append(contentsOf: Array("mywhoosh".utf8))
        message.append(0x01)
        message.append(0x39) // "9"
        message.append(0x02)
        message.append(contentsOf: [0x01, 0x02])

        var stream = OpenBikeCodec.StreamDecoder()
        checks.equal(stream.append(Array(message.prefix(5))), [], "a partial app info message yields nothing")

        let framed = stream.append(Array(message.dropFirst(5)))
        checks.equal(framed.count, 1, "the app info message is emitted once complete")
        guard case .appInfo(let decoded)? = framed.first else {
            checks.expect(false, "the framed message is app info, got \(framed)")
            return
        }
        checks.equal(decoded.appID, "mywhoosh", "framed app identifier")
        checks.equal(decoded.appVersion, "9", "framed app version")
        checks.equal(decoded.supportedButtons, [0x01, 0x02], "framed supported buttons")
    }
}
