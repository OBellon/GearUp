import Foundation

/// Reassembles an OpenBikeControl app-info message that a central splits across
/// several BLE writes.
///
/// Some apps (TrainingPeaks on macOS is the documented one) write the app-info
/// message in fragments. Each write is offered here; the parsed value comes back
/// once enough bytes have accumulated, and `nil` while it is still incomplete.
///
/// Every fragment is kept, not just the last one: a message split across three
/// or more writes would never reassemble if the middle fragment were dropped.
/// Bytes that cannot begin an app-info message are discarded so a corrupt write
/// cannot poison every later one.
public struct OpenBikeAppInfoReassembler {
    /// A valid app-info is roughly 100 bytes (32-byte app id + 32-byte version
    /// + headers + a handful of button ids). Anything past this is a stuck
    /// stream rather than a big message.
    public static let maximumBufferedBytes = 512

    private var buffer: [UInt8] = []

    /// A description of the last real problem — a dropped byte or an
    /// unparsable message. `nil` while the message is merely incomplete, which
    /// is the normal state for the first fragment of a split write.
    public private(set) var lastProblem: String?

    /// Bytes currently waiting for the rest of the message.
    public var pendingByteCount: Int { buffer.count }

    public init() {}

    /// Drops any half-received message. Call when a central disconnects so an
    /// incomplete write cannot bleed into the next connection.
    public mutating func reset() {
        buffer.removeAll()
        lastProblem = nil
    }

    /// Offers the next write payload.
    ///
    /// - Returns: the app info once the accumulated bytes parse, otherwise
    ///   `nil` while the message is still incomplete.
    public mutating func offer(_ fragment: [UInt8]) -> OpenBikeAppInfo? {
        buffer.append(contentsOf: fragment)
        lastProblem = nil

        while let first = buffer.first {
            guard first == OpenBikeMessageType.appInfo.rawValue else {
                lastProblem = String(
                    format: "Dropped a stray byte 0x%02X from the app-info stream.", first
                )
                buffer.removeFirst()
                continue
            }

            guard let total = OpenBikeCodec.appInfoMessageLength(buffer) else {
                guard buffer.count > Self.maximumBufferedBytes else {
                    // Still waiting for the rest of the header.
                    return nil
                }
                lastProblem = "Dropped a byte: the app-info message is longer than \(Self.maximumBufferedBytes) bytes."
                buffer.removeFirst()
                continue
            }

            guard buffer.count >= total else {
                // The length is known, the bytes have not all arrived.
                return nil
            }

            let message = Array(buffer.prefix(total))
            guard let info = OpenBikeCodec.decodeAppInfo(message) else {
                lastProblem = "Dropped a byte: \(message.hexString) did not decode as app info."
                buffer.removeFirst()
                continue
            }

            buffer.removeAll()
            return info
        }

        return nil
    }
}
