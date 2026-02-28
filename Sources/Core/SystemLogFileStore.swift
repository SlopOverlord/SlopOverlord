import Foundation
import Protocols

final class SystemLogFileStore {
    enum StoreError: Error {
        case storageFailure
    }

    private let fileManager: FileManager
    private var workspaceRootURL: URL
    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(workspaceRootURL: URL, fileManager: FileManager = .default) {
        self.workspaceRootURL = workspaceRootURL
        self.fileManager = fileManager
    }

    func updateWorkspaceRootURL(_ url: URL) {
        self.workspaceRootURL = url
    }

    func currentLogFileURL(now: Date = Date()) -> URL {
        let day = Self.fileDateFormatter.string(from: now)
        return logsDirectoryURL().appendingPathComponent("core-\(day).log")
    }

    func readRecentEntries(limit: Int = 1500) throws -> SystemLogsResponse {
        let normalizedLimit = min(max(limit, 1), 5_000)
        let targetURL = latestLogFileURL() ?? currentLogFileURL()
        guard fileManager.fileExists(atPath: targetURL.path) else {
            return SystemLogsResponse(filePath: targetURL.path, entries: [])
        }

        do {
            let data = try Data(contentsOf: targetURL)
            guard let content = String(data: data, encoding: .utf8) else {
                return SystemLogsResponse(filePath: targetURL.path, entries: [])
            }

            let lines = content
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            let scanCount = min(lines.count, normalizedLimit * 12)
            let tailLines = lines.suffix(scanCount)
            let entries = tailLines.compactMap(parseEntry).suffix(normalizedLimit)
            return SystemLogsResponse(filePath: targetURL.path, entries: Array(entries))
        } catch {
            throw StoreError.storageFailure
        }
    }

    private func logsDirectoryURL() -> URL {
        workspaceRootURL.appendingPathComponent("logs", isDirectory: true)
    }

    private func latestLogFileURL() -> URL? {
        let logsDirectory = logsDirectoryURL()
        guard fileManager.fileExists(atPath: logsDirectory.path) else {
            return nil
        }

        let items: [URL]
        do {
            items = try fileManager.contentsOfDirectory(
                at: logsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return nil
        }

        let logFiles = items.filter { $0.pathExtension == "log" }
        guard !logFiles.isEmpty else {
            return nil
        }

        return logFiles.max(by: { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return leftDate < rightDate
        })
    }

    private func parseEntry(line: String) -> SystemLogEntry? {
        guard let data = line.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else {
            return nil
        }

        guard let timestampRaw = payload["timestamp"] as? String,
              let timestamp = parseTimestamp(timestampRaw)
        else {
            return nil
        }

        let levelRaw = String(describing: payload["level"] ?? "").lowercased()
        guard let level = parseLevel(levelRaw) else {
            return nil
        }

        let label = String(describing: payload["label"] ?? "")
        let message = String(describing: payload["message"] ?? "")
        let source = String(describing: payload["source"] ?? "")

        var metadata: [String: String] = [:]
        if let rawMetadata = payload["metadata"] as? [String: Any] {
            for (key, value) in rawMetadata {
                metadata[key] = String(describing: value)
            }
        }

        return SystemLogEntry(
            timestamp: timestamp,
            level: level,
            label: label,
            message: message,
            source: source,
            metadata: metadata
        )
    }

    private func parseLevel(_ value: String) -> SystemLogLevel? {
        if let mapped = SystemLogLevel(rawValue: value) {
            return mapped
        }

        switch value {
        case "warn":
            return .warning
        case "critical":
            return .fatal
        default:
            return nil
        }
    }

    private func parseTimestamp(_ value: String) -> Date? {
        let formatterWithFractional = ISO8601DateFormatter()
        formatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatterWithFractional.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
