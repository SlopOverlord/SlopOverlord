import Foundation
import Logging

struct DesktopNotificationRequest: Sendable, Equatable {
    var category: String
    var title: String
    var body: String
    var metadata: [String: String]

    init(
        category: String,
        title: String,
        body: String = "",
        metadata: [String: String] = [:]
    ) {
        self.category = category
        self.title = title
        self.body = body
        self.metadata = metadata
    }
}

protocol DesktopNotificationDelivering: Sendable {
    func deliver(_ request: DesktopNotificationRequest) async throws
}

actor DesktopNotificationService {
    private let driver: any DesktopNotificationDelivering
    private let dedupeWindow: TimeInterval
    private let logger: Logger
    private var deliveredAtByKey: [String: Date] = [:]

    init(
        driver: any DesktopNotificationDelivering,
        dedupeWindow: TimeInterval = 3,
        logger: Logger = Logger(label: "sloppy.desktop-notifications")
    ) {
        self.driver = driver
        self.dedupeWindow = dedupeWindow
        self.logger = logger
    }

    static func live(logger: Logger = Logger(label: "sloppy.desktop-notifications")) -> DesktopNotificationService {
        #if os(macOS)
        return DesktopNotificationService(driver: MacOSDesktopNotificationDriver(), logger: logger)
        #else
        return DesktopNotificationService(driver: NoopDesktopNotificationDriver(), logger: logger)
        #endif
    }

    @discardableResult
    func notify(
        category: String,
        title: String,
        body: String = "",
        metadata: [String: String] = [:]
    ) async -> Bool {
        let request = DesktopNotificationRequest(category: category, title: title, body: body, metadata: metadata)
        let key = dedupeKey(for: request)
        let now = Date()
        if let deliveredAt = deliveredAtByKey[key], now.timeIntervalSince(deliveredAt) < dedupeWindow {
            return false
        }
        deliveredAtByKey[key] = now
        pruneDeliveredKeys(now: now)

        do {
            try await driver.deliver(request)
            return true
        } catch {
            logger.warning(
                "desktop_notification.failed",
                metadata: [
                    "category": .string(category),
                    "error": .string(error.localizedDescription)
                ]
            )
            return false
        }
    }

    private func dedupeKey(for request: DesktopNotificationRequest) -> String {
        let identity = request.metadata["approvalId"]
            ?? request.metadata["requestId"]
            ?? request.metadata["taskId"]
            ?? request.metadata["sessionId"]
            ?? request.metadata["cronTaskId"]
            ?? request.title
        return "\(request.category):\(identity)"
    }

    private func pruneDeliveredKeys(now: Date) {
        let cutoff = now.addingTimeInterval(-dedupeWindow * 4)
        deliveredAtByKey = deliveredAtByKey.filter { $0.value >= cutoff }
    }
}

struct NoopDesktopNotificationDriver: DesktopNotificationDelivering {
    func deliver(_ request: DesktopNotificationRequest) async throws {
        _ = request
    }
}

#if os(macOS)
struct MacOSDesktopNotificationDriver: DesktopNotificationDelivering {
    var osascriptPath: String = "/usr/bin/osascript"

    func deliver(_ request: DesktopNotificationRequest) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: osascriptPath)
        process.arguments = Self.arguments(for: request)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }

    static func arguments(for request: DesktopNotificationRequest) -> [String] {
        ["-e", script(for: request)]
    }

    static func script(for request: DesktopNotificationRequest) -> String {
        let body = appleScriptStringLiteral(request.body)
        let title = appleScriptStringLiteral(request.title)
        return "display notification \(body) with title \(title)"
    }

    static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
#endif
