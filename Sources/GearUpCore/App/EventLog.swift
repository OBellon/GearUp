import Foundation
import Combine
import OSLog

/// One line in the in-app diagnostics log.
public struct LogEntry: Identifiable, Equatable {
    public enum Level: String, Equatable, CaseIterable {
        case info
        case success
        case warning
        case error

        /// SF Symbol shown next to the entry in the Diagnostics tab.
        public var symbolName: String {
            switch self {
            case .info: return "circle"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }

        public var title: String {
            switch self {
            case .info: return "Info"
            case .success: return "OK"
            case .warning: return "Warning"
            case .error: return "Error"
            }
        }
    }

    public let id: UUID
    public let date: Date
    public let level: Level
    public let message: String

    public init(date: Date = Date(), level: Level = .info, message: String) {
        self.id = UUID()
        self.date = date
        self.level = level
        self.message = message
    }
}

/// A bounded, observable log that every part of GearUp writes to.
///
/// Everything runs on the main queue (CoreBluetooth and Network are both given
/// the main queue), so the log needs no locking of its own. Entries also go to
/// `OSLog` and to a plain file, because the Diagnostics tab is no help when the
/// problem is that the window never came up.
public final class EventLog: ObservableObject {
    @Published public private(set) var entries: [LogEntry] = []

    /// `~/Library/Logs/GearUp/GearUp.log`, the conventional place for a macOS
    /// app's own log file.
    public static var defaultFileURL: URL? {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/GearUp/GearUp.log")
    }

    private let limit: Int
    private let fileURL: URL?
    private var fileHandle: FileHandle?
    private let logger = Logger(subsystem: "com.oscar.gearup", category: "events")

    public convenience init(limit: Int = 400) {
        self.init(limit: limit, fileURL: EventLog.defaultFileURL)
    }

    public init(limit: Int = 400, fileURL: URL?) {
        self.limit = limit
        self.fileURL = fileURL
        openFile()
    }

    deinit {
        try? fileHandle?.close()
    }

    public func add(_ message: String, level: LogEntry.Level = .info) {
        let entry = LogEntry(level: level, message: message)
        if entries.count >= limit {
            entries.removeFirst(entries.count - limit + 1)
        }
        entries.append(entry)
        write(entry)

        switch level {
        case .info: logger.notice("\(message, privacy: .public)")
        case .success: logger.notice("✓ \(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }

    public func clear() {
        entries.removeAll()
    }

    /// The whole log as plain text, for the Copy button.
    public var plainText: String {
        entries.map(Self.line(for:)).joined(separator: "\n")
    }

    // MARK: - File

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static func line(for entry: LogEntry) -> String {
        "[\(timestampFormatter.string(from: entry.date))] \(entry.level.rawValue.uppercased()) \(entry.message)"
    }

    private func openFile() {
        guard let fileURL else { return }
        let manager = FileManager.default
        try? manager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Start a fresh file when the previous session grew large, so the log
        // cannot fill the disk over time.
        if let size = try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > 1_000_000 {
            try? manager.removeItem(at: fileURL)
        }
        if !manager.fileExists(atPath: fileURL.path) {
            manager.createFile(atPath: fileURL.path, contents: nil)
        }

        fileHandle = try? FileHandle(forWritingTo: fileURL)
        try? fileHandle?.seekToEnd()
        write(LogEntry(message: "── GearUp \(Bundle.main.shortVersion) launched ────"))
    }

    private func write(_ entry: LogEntry) {
        guard let fileHandle, let data = (Self.line(for: entry) + "\n").data(using: .utf8) else { return }
        try? fileHandle.write(contentsOf: data)
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
