import Foundation

/// Writes the probe transcript to stdout and to a log file, so the output can
/// be shared even when the terminal scrollback is lost.
final class ProbeLog {
    let fileURL: URL

    private let handle: FileHandle?
    private let queue = DispatchQueue(label: "com.oscar.gearup.probe.log")
    private let lineFormatter: DateFormatter

    /// Writes to an explicit file, creating the containing directory if needed.
    init(fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let lineFormatter = DateFormatter()
        lineFormatter.dateFormat = "HH:mm:ss.SSS"
        lineFormatter.locale = Locale(identifier: "en_US_POSIX")
        self.lineFormatter = lineFormatter

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        self.fileURL = fileURL
        self.handle = try FileHandle(forWritingTo: fileURL)
    }

    /// Writes to `probe-<timestamp>.log` inside a directory.
    convenience init(directory: URL) throws {
        let stampFormatter = DateFormatter()
        stampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")

        let name = "probe-\(stampFormatter.string(from: Date())).log"
        try self.init(fileURL: directory.appendingPathComponent(name))
    }

    func line(_ message: String) {
        let text = "[\(lineFormatter.string(from: Date()))] \(message)"
        print(text)
        queue.async { [handle] in
            guard let handle else { return }
            try? handle.write(contentsOf: Data((text + "\n").utf8))
        }
    }

    func rule(_ title: String = "") {
        let line = title.isEmpty ? String(repeating: "─", count: 64) : "── \(title) " + String(repeating: "─", count: max(0, 58 - title.count))
        self.line(line)
    }

    func close() {
        queue.sync { [handle] in
            try? handle?.close()
        }
    }
}
