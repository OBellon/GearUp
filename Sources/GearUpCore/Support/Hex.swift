import Foundation

public extension Data {
    /// Lowercase, space-separated hex, e.g. `01 0a ff`.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// Uppercase, contiguous hex, e.g. `010AFF`.
    var compactHexString: String {
        map { String(format: "%02X", $0) }.joined()
    }
}

public extension Array where Element == UInt8 {
    var hexString: String {
        Data(self).hexString
    }

    var compactHexString: String {
        Data(self).compactHexString
    }

    /// Parses `01 0a ff`, `010aff` or `0x01,0x0a` into bytes. Returns nil on
    /// malformed input.
    static func fromHex(_ string: String) -> [UInt8]? {
        let cleaned = string
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        let tokens = cleaned.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        if tokens.count > 1 {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(tokens.count)
            for token in tokens {
                guard token.count <= 2, let byte = UInt8(token, radix: 16) else { return nil }
                bytes.append(byte)
            }
            return bytes
        }

        guard cleaned.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
