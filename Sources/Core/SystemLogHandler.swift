import Foundation
import Logging
import Protocols

final class SystemLogFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let fileHandle: FileHandle
    let fileURL: URL

    init(fileURL: URL, fileManager: FileManager = .default) throws {
        self.fileURL = fileURL
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: Data())
        }
        self.fileHandle = try FileHandle(forWritingTo: fileURL)
        try self.fileHandle.seekToEnd()
    }

    deinit {
        try? fileHandle.close()
    }

    func append(_ payload: Data) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: payload)
        } catch {
            // Best-effort logging: never crash app because log file write failed.
        }
    }
}

struct SystemJSONLLogHandler: LogHandler {
    private static let configurationLock = NSLock()
    private nonisolated(unsafe) static var sharedWriter: SystemLogFileWriter?

    static func configure(fileURL: URL) {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        sharedWriter = try? SystemLogFileWriter(fileURL: fileURL)
    }

    let label: String
    private let writer: SystemLogFileWriter?
    var logLevel: Logger.Level
    var metadata: Logger.Metadata

    init(label: String) {
        self.label = label
        Self.configurationLock.lock()
        self.writer = Self.sharedWriter
        Self.configurationLock.unlock()
        self.logLevel = .trace
        self.metadata = [:]
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata callMetadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        guard level >= logLevel, let writer else {
            return
        }

        var mergedMetadata = metadata
        if let callMetadata {
            for (key, value) in callMetadata {
                mergedMetadata[key] = value
            }
        }

        let record = SystemLogEntry(
            timestamp: Date(),
            level: mappedLevel(level),
            label: label,
            message: message.description,
            source: source,
            metadata: flattenMetadata(mergedMetadata)
        )

        let payload = serialize(entry: record)
        writer.append(payload)
    }

    private func mappedLevel(_ level: Logger.Level) -> SystemLogLevel {
        switch level {
        case .trace:
            return .trace
        case .debug:
            return .debug
        case .info, .notice:
            return .info
        case .warning:
            return .warning
        case .error:
            return .error
        case .critical:
            return .fatal
        }
    }

    private func flattenMetadata(_ metadata: Logger.Metadata) -> [String: String] {
        var flattened: [String: String] = [:]
        for (key, value) in metadata {
            flattened[key] = string(from: value)
        }
        return flattened
    }

    private func string(from value: Logger.Metadata.Value) -> String {
        switch value {
        case .string(let scalar):
            return scalar
        case .stringConvertible(let scalar):
            return scalar.description
        case .array(let items):
            let rendered = items.map(string(from:)).joined(separator: ",")
            return "[\(rendered)]"
        case .dictionary(let map):
            let rendered = map
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key):\(string(from: $0.value))" }
                .joined(separator: ",")
            return "{\(rendered)}"
        }
    }

    private func serialize(entry: SystemLogEntry) -> Data {
        let object: [String: Any] = [
            "timestamp": ISO8601DateFormatter.string(
                from: entry.timestamp,
                timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt,
                formatOptions: [.withInternetDateTime, .withFractionalSeconds]
            ),
            "level": entry.level.rawValue,
            "label": entry.label,
            "message": entry.message,
            "source": entry.source,
            "metadata": entry.metadata
        ]

        guard var payload = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return Data()
        }
        payload.append(0x0A)
        return payload
    }
}
