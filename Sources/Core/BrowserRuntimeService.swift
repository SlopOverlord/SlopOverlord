import Foundation
import Logging
import Protocols
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct BrowserLaunchOptions: Sendable, Equatable {
    let browserPath: String
    let headless: Bool
    let userDataDir: String
    let profileDirectory: String
}

struct BrowserLaunchedProcess: Sendable {
    let controller: any BrowserProcessControlling
    let debuggerBaseURL: URL
}

protocol BrowserProcessControlling: Sendable {
    func terminate() async
}

protocol BrowserProcessLaunching: Sendable {
    func launch(options: BrowserLaunchOptions) async throws -> BrowserLaunchedProcess
}

protocol BrowserPageDiscovering: Sendable {
    func pageWebSocketURL(debuggerBaseURL: URL) async throws -> URL
}

protocol BrowserCDPSession: Sendable {
    func call(method: String, params: [String: JSONValue]) async throws -> [String: JSONValue]
    func close() async
}

protocol BrowserCDPConnecting: Sendable {
    func connect(webSocketURL: URL) async throws -> any BrowserCDPSession
}

enum BrowserRuntimeError: Error, Sendable {
    case missingAction
    case invalidURL
    case browserNotStarted
    case profileRequired
    case unknownProfile
    case javaScriptEvaluationDisabled
    case missingElementId
    case staleElementReference
    case invalidTextInput
    case screenshotEncodingFailed
    case browserLaunchFailed(String)
    case cdpFailure(String)

    var toolError: ToolErrorPayload {
        switch self {
        case .missingAction:
            return .init(code: "invalid_arguments", message: "`action` is required for browser tool.", retryable: false)
        case .invalidURL:
            return .init(code: "invalid_arguments", message: "`url` must be a valid absolute URL.", retryable: false)
        case .browserNotStarted:
            return .init(code: "browser_not_started", message: "No active browser session. Call browser navigate first.", retryable: false)
        case .profileRequired:
            return .init(code: "profile_required", message: "Multiple browser profiles are configured. Provide `profileId`.", retryable: false)
        case .unknownProfile:
            return .init(code: "unknown_profile", message: "Requested browser profile was not found.", retryable: false)
        case .javaScriptEvaluationDisabled:
            return .init(code: "javascript_evaluation_disabled", message: "JavaScript evaluation is disabled by browser config.", retryable: false)
        case .missingElementId:
            return .init(code: "invalid_arguments", message: "`elementId` is required for this browser action.", retryable: false)
        case .staleElementReference:
            return .init(code: "stale_element", message: "Element reference is stale or unknown. Run browser snapshot again.", retryable: false)
        case .invalidTextInput:
            return .init(code: "invalid_element", message: "Element is not a text input or editable field.", retryable: false)
        case .screenshotEncodingFailed:
            return .init(code: "screenshot_failed", message: "Browser returned an invalid screenshot payload.", retryable: true)
        case .browserLaunchFailed(let message):
            return .init(code: "browser_launch_failed", message: message, retryable: true)
        case .cdpFailure(let message):
            return .init(code: "browser_failed", message: message, retryable: true)
        }
    }
}

actor BrowserRuntimeService {
    private struct ActiveBrowserSession {
        let controller: any BrowserProcessControlling
        let cdpSession: any BrowserCDPSession
        let selectionKey: String
        let userDataDir: URL
        let isEphemeral: Bool
        var currentRefs: Set<String>
    }

    private let launcher: any BrowserProcessLaunching
    private let pageDiscoverer: any BrowserPageDiscovering
    private let cdpConnector: any BrowserCDPConnecting
    private let logger: Logger
    private var browserConfig: CoreConfig.Browser
    private var workspaceRootURL: URL
    private var sessions: [String: ActiveBrowserSession] = [:]

    init(
        browserConfig: CoreConfig.Browser,
        workspaceRootURL: URL,
        launcher: any BrowserProcessLaunching = ChromiumBrowserProcessLauncher(),
        pageDiscoverer: any BrowserPageDiscovering = ChromiumBrowserPageDiscoverer(),
        cdpConnector: any BrowserCDPConnecting = ChromiumCDPConnector(),
        logger: Logger = Logger(label: "sloppy.core.browser")
    ) {
        self.browserConfig = browserConfig
        self.workspaceRootURL = workspaceRootURL
        self.launcher = launcher
        self.pageDiscoverer = pageDiscoverer
        self.cdpConnector = cdpConnector
        self.logger = logger
    }

    func updateConfiguration(browserConfig: CoreConfig.Browser, workspaceRootURL: URL) {
        self.browserConfig = browserConfig
        self.workspaceRootURL = workspaceRootURL
    }

    func cleanupSession(_ sessionID: String) async {
        await closeSession(sessionID)
    }

    func shutdown() async {
        let activeSessionIDs = Array(sessions.keys)
        for sessionID in activeSessionIDs {
            await closeSession(sessionID)
        }
    }

    func invoke(sessionID: String, request: ToolInvocationRequest) async -> ToolInvocationResult {
        let action = request.arguments["action"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !action.isEmpty else {
            return .init(tool: request.tool, ok: false, error: BrowserRuntimeError.missingAction.toolError)
        }

        do {
            switch action {
            case "navigate":
                return try await navigate(sessionID: sessionID, request: request)
            case "snapshot":
                return try await snapshot(sessionID: sessionID, request: request.tool)
            case "click":
                return try await click(sessionID: sessionID, request: request)
            case "type":
                return try await type(sessionID: sessionID, request: request)
            case "press":
                return try await press(sessionID: sessionID, request: request)
            case "wait":
                return try await wait(request: request)
            case "screenshot":
                return try await screenshot(sessionID: sessionID, request: request.tool)
            case "evaluate":
                return try await evaluate(sessionID: sessionID, request: request)
            case "close":
                await closeSession(sessionID)
                return .init(tool: request.tool, ok: true, data: .object(["status": .string("closed")]))
            default:
                return .init(
                    tool: request.tool,
                    ok: false,
                    error: .init(code: "invalid_arguments", message: "Unsupported browser action '\(action)'.", retryable: false)
                )
            }
        } catch let error as BrowserRuntimeError {
            return .init(tool: request.tool, ok: false, error: error.toolError)
        } catch {
            return .init(
                tool: request.tool,
                ok: false,
                error: BrowserRuntimeError.cdpFailure("Browser action failed.").toolError
            )
        }
    }

    private func navigate(sessionID: String, request: ToolInvocationRequest) async throws -> ToolInvocationResult {
        let urlString = request.arguments["url"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw BrowserRuntimeError.invalidURL
        }

        let selection = try resolveProfileSelection(sessionID: sessionID, profileID: request.arguments["profileId"]?.asString)
        let session = try await ensureSession(sessionID: sessionID, selection: selection)
        _ = try await session.cdpSession.call(method: "Page.navigate", params: ["url": .string(url.absoluteString)])
        try await waitForDocumentReady(cdpSession: session.cdpSession, timeoutMs: 10_000)

        return .init(
            tool: request.tool,
            ok: true,
            data: .object([
                "status": .string("navigated"),
                "url": .string(url.absoluteString),
                "profileId": selection.profileID.map(JSONValue.string) ?? .null,
                "ephemeral": .bool(selection.isEphemeral)
            ])
        )
    }

    private func snapshot(sessionID: String, request tool: String) async throws -> ToolInvocationResult {
        guard var session = sessions[sessionID] else {
            throw BrowserRuntimeError.browserNotStarted
        }

        let payload = try await evaluateJSON(
            cdpSession: session.cdpSession,
            expression: browserSnapshotScript(),
            awaitPromise: true
        )
        guard let object = payload.asObject else {
            throw BrowserRuntimeError.cdpFailure("Browser snapshot returned invalid payload.")
        }

        session.currentRefs = Set(
            object["elements"]?.asArray?.compactMap { $0.asObject?["elementId"]?.asString } ?? []
        )
        sessions[sessionID] = session
        return .init(tool: tool, ok: true, data: .object(object))
    }

    private func click(sessionID: String, request: ToolInvocationRequest) async throws -> ToolInvocationResult {
        let elementID = try requireElementID(request: request, sessionID: sessionID)
        let session = try activeSession(sessionID: sessionID)
        let payload = try await evaluateJSON(
            cdpSession: session.cdpSession,
            expression: browserClickScript(elementID: elementID),
            awaitPromise: true
        )
        return .init(tool: request.tool, ok: true, data: payload)
    }

    private func type(sessionID: String, request: ToolInvocationRequest) async throws -> ToolInvocationResult {
        let elementID = try requireElementID(request: request, sessionID: sessionID)
        let text = request.arguments["text"]?.asString ?? ""
        let session = try activeSession(sessionID: sessionID)
        let payload = try await evaluateJSON(
            cdpSession: session.cdpSession,
            expression: browserTypeScript(elementID: elementID, text: text),
            awaitPromise: true
        )
        if payload.asObject?["ok"]?.asBool == false {
            throw BrowserRuntimeError.invalidTextInput
        }
        return .init(tool: request.tool, ok: true, data: payload)
    }

    private func press(sessionID: String, request: ToolInvocationRequest) async throws -> ToolInvocationResult {
        let key = request.arguments["key"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else {
            return .init(tool: request.tool, ok: false, error: .init(code: "invalid_arguments", message: "`key` is required.", retryable: false))
        }
        let session = try activeSession(sessionID: sessionID)
        let payload = try await evaluateJSON(
            cdpSession: session.cdpSession,
            expression: browserPressScript(key: key),
            awaitPromise: true
        )
        return .init(tool: request.tool, ok: true, data: payload)
    }

    private func wait(request: ToolInvocationRequest) async throws -> ToolInvocationResult {
        let ms = max(0, request.arguments["ms"]?.asInt ?? 0)
        try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
        return .init(tool: request.tool, ok: true, data: .object(["waitedMs": .number(Double(ms))]))
    }

    private func screenshot(sessionID: String, request tool: String) async throws -> ToolInvocationResult {
        let session = try activeSession(sessionID: sessionID)
        let result = try await session.cdpSession.call(method: "Page.captureScreenshot", params: [:])
        let dataString = result["data"]?.asString ?? ""
        guard let data = Data(base64Encoded: dataString) else {
            throw BrowserRuntimeError.screenshotEncodingFailed
        }

        let artifactID = UUID().uuidString
        let relativePath = "artifacts/browser/\(sessionID)-\(artifactID).png"
        let destinationURL = workspaceRootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destinationURL, options: .atomic)

        return .init(
            tool: tool,
            ok: true,
            data: .object([
                "artifactId": .string(artifactID),
                "path": .string(destinationURL.path),
                "relativePath": .string(relativePath),
                "mimeType": .string("image/png"),
                "sizeBytes": .number(Double(data.count))
            ])
        )
    }

    private func evaluate(sessionID: String, request: ToolInvocationRequest) async throws -> ToolInvocationResult {
        guard browserConfig.allowJavaScriptEvaluation else {
            throw BrowserRuntimeError.javaScriptEvaluationDisabled
        }
        let expression = request.arguments["expression"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !expression.isEmpty else {
            return .init(tool: request.tool, ok: false, error: .init(code: "invalid_arguments", message: "`expression` is required.", retryable: false))
        }
        let session = try activeSession(sessionID: sessionID)
        let payload = try await evaluateJSON(cdpSession: session.cdpSession, expression: expression, awaitPromise: true)
        return .init(tool: request.tool, ok: true, data: .object(["result": payload]))
    }

    private func requireElementID(request: ToolInvocationRequest, sessionID: String) throws -> String {
        let elementID = request.arguments["elementId"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !elementID.isEmpty else {
            throw BrowserRuntimeError.missingElementId
        }
        guard let session = sessions[sessionID], session.currentRefs.contains(elementID) else {
            throw BrowserRuntimeError.staleElementReference
        }
        return elementID
    }

    private func activeSession(sessionID: String) throws -> ActiveBrowserSession {
        guard let session = sessions[sessionID] else {
            throw BrowserRuntimeError.browserNotStarted
        }
        return session
    }

    private func ensureSession(
        sessionID: String,
        selection: BrowserProfileSelection
    ) async throws -> ActiveBrowserSession {
        if let current = sessions[sessionID], current.selectionKey == selection.selectionKey {
            return current
        }

        if sessions[sessionID] != nil {
            await closeSession(sessionID)
        }

        let userDataDir = selection.userDataDir
        try FileManager.default.createDirectory(at: userDataDir, withIntermediateDirectories: true)
        let launched = try await launcher.launch(
            options: BrowserLaunchOptions(
                browserPath: browserConfig.browserPath,
                headless: browserConfig.headless,
                userDataDir: userDataDir.path,
                profileDirectory: selection.profileDirectory
            )
        )
        let pageWebSocketURL = try await pageDiscoverer.pageWebSocketURL(debuggerBaseURL: launched.debuggerBaseURL)
        let cdpSession = try await cdpConnector.connect(webSocketURL: pageWebSocketURL)
        _ = try await cdpSession.call(method: "Page.enable", params: [:])
        _ = try await cdpSession.call(method: "Runtime.enable", params: [:])

        let active = ActiveBrowserSession(
            controller: launched.controller,
            cdpSession: cdpSession,
            selectionKey: selection.selectionKey,
            userDataDir: userDataDir,
            isEphemeral: selection.isEphemeral,
            currentRefs: []
        )
        sessions[sessionID] = active
        return active
    }

    private func closeSession(_ sessionID: String) async {
        guard let session = sessions.removeValue(forKey: sessionID) else {
            return
        }

        await session.cdpSession.close()
        await session.controller.terminate()
        if session.isEphemeral {
            try? FileManager.default.removeItem(at: session.userDataDir)
        }
    }

    private struct BrowserProfileSelection {
        let profileID: String?
        let selectionKey: String
        let userDataDir: URL
        let profileDirectory: String
        let isEphemeral: Bool
    }

    private func resolveProfileSelection(sessionID: String, profileID rawProfileID: String?) throws -> BrowserProfileSelection {
        let profileID = rawProfileID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let profiles = browserConfig.profiles
        let currentDirectory = FileManager.default.currentDirectoryPath

        if profiles.isEmpty {
            if let profileID, !profileID.isEmpty {
                throw BrowserRuntimeError.unknownProfile
            }
            let root = workspaceRootURL
                .appendingPathComponent("tmp", isDirectory: true)
                .appendingPathComponent("browser", isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
            return BrowserProfileSelection(
                profileID: nil,
                selectionKey: "ephemeral",
                userDataDir: root,
                profileDirectory: "Default",
                isEphemeral: true
            )
        }

        let profile: CoreConfig.Browser.Profile
        if let profileID, !profileID.isEmpty {
            guard let matched = profiles.first(where: { $0.id == profileID }) else {
                throw BrowserRuntimeError.unknownProfile
            }
            profile = matched
        } else if profiles.count == 1, let single = profiles.first {
            profile = single
        } else {
            throw BrowserRuntimeError.profileRequired
        }

        let resolvedDir = CoreConfig.default.resolvedBrowserUserDataDir(profile.userDataDir, currentDirectory: currentDirectory)
        return BrowserProfileSelection(
            profileID: profile.id,
            selectionKey: "profile:\(profile.id)",
            userDataDir: resolvedDir,
            profileDirectory: profile.profileDirectory,
            isEphemeral: false
        )
    }

    private func waitForDocumentReady(
        cdpSession: any BrowserCDPSession,
        timeoutMs: Int
    ) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            let readyState = try await evaluateJSON(
                cdpSession: cdpSession,
                expression: "document.readyState",
                awaitPromise: false
            )
            let state = readyState.asString ?? ""
            if state == "complete" || state == "interactive" {
                return
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private func evaluateJSON(
        cdpSession: any BrowserCDPSession,
        expression: String,
        awaitPromise: Bool
    ) async throws -> JSONValue {
        let response = try await cdpSession.call(
            method: "Runtime.evaluate",
            params: [
                "expression": .string(expression),
                "returnByValue": .bool(true),
                "awaitPromise": .bool(awaitPromise)
            ]
        )

        if let details = response["exceptionDetails"] {
            throw BrowserRuntimeError.cdpFailure("Browser evaluation failed: \(details)")
        }

        if let object = response["result"]?.asObject,
           let value = object["value"] {
            return value
        }
        return .null
    }

    private func jsStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return string
    }

    private func browserSnapshotScript() -> String {
        """
        (() => {
          const selector = 'a, button, input, textarea, select, option, [role="button"], [contenteditable="true"], [tabindex]';
          const visible = (element) => {
            if (!element || !element.isConnected) return false;
            const style = window.getComputedStyle(element);
            if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) return false;
            const rect = element.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          };
          document.querySelectorAll('[data-sloppy-ref]').forEach((element) => element.removeAttribute('data-sloppy-ref'));
          const elements = [];
          let index = 1;
          for (const element of document.querySelectorAll(selector)) {
            if (!visible(element)) continue;
            const ref = `e${index++}`;
            element.setAttribute('data-sloppy-ref', ref);
            const rect = element.getBoundingClientRect();
            elements.push({
              elementId: ref,
              tagName: String(element.tagName || '').toLowerCase(),
              role: element.getAttribute('role') || '',
              type: 'type' in element ? String(element.type || '') : '',
              text: (element.innerText || element.textContent || '').trim().slice(0, 200),
              ariaLabel: element.getAttribute('aria-label') || '',
              placeholder: element.getAttribute('placeholder') || '',
              href: element.href || '',
              value: 'value' in element ? String(element.value || '').slice(0, 120) : '',
              boundingBox: {
                x: Math.round(rect.x),
                y: Math.round(rect.y),
                width: Math.round(rect.width),
                height: Math.round(rect.height)
              }
            });
            if (elements.length >= 200) break;
          }
          return {
            title: document.title || '',
            url: window.location.href,
            elementCount: elements.length,
            elements
          };
        })()
        """
    }

    private func browserClickScript(elementID: String) -> String {
        """
        (() => {
          const element = document.querySelector(`[data-sloppy-ref=\(jsStringLiteral(elementID))]`);
          if (!element) return { ok: false, error: 'not_found' };
          element.scrollIntoView({ block: 'center', inline: 'center' });
          element.click();
          return { ok: true, elementId: \(jsStringLiteral(elementID)) };
        })()
        """
    }

    private func browserTypeScript(elementID: String, text: String) -> String {
        """
        (() => {
          const element = document.querySelector(`[data-sloppy-ref=\(jsStringLiteral(elementID))]`);
          if (!element) return { ok: false, error: 'not_found' };
          element.scrollIntoView({ block: 'center', inline: 'center' });
          element.focus();
          const value = \(jsStringLiteral(text));
          if ('value' in element) {
            element.value = value;
            element.dispatchEvent(new Event('input', { bubbles: true }));
            element.dispatchEvent(new Event('change', { bubbles: true }));
            return { ok: true, elementId: \(jsStringLiteral(elementID)), length: value.length };
          }
          if (element.isContentEditable) {
            element.textContent = value;
            element.dispatchEvent(new Event('input', { bubbles: true }));
            return { ok: true, elementId: \(jsStringLiteral(elementID)), length: value.length };
          }
          return { ok: false, error: 'not_text_input' };
        })()
        """
    }

    private func browserPressScript(key: String) -> String {
        """
        (() => {
          const key = \(jsStringLiteral(key));
          const target = document.activeElement || document.body;
          const init = { key, bubbles: true, cancelable: true };
          target.dispatchEvent(new KeyboardEvent('keydown', init));
          target.dispatchEvent(new KeyboardEvent('keypress', init));
          target.dispatchEvent(new KeyboardEvent('keyup', init));
          if (key === 'Enter' && typeof target.click === 'function' && target.tagName === 'BUTTON') {
            target.click();
          }
          return {
            ok: true,
            key,
            targetTag: String(target?.tagName || '').toLowerCase()
          };
        })()
        """
    }
}

private struct ChromiumInspectorTarget: Decodable {
    let type: String
    let webSocketDebuggerUrl: String?
}

struct ChromiumBrowserPageDiscoverer: BrowserPageDiscovering {
    func pageWebSocketURL(debuggerBaseURL: URL) async throws -> URL {
        let decoder = JSONDecoder()
        let deadline = Date().addingTimeInterval(8)
        var lastError: Error?

        while Date() < deadline {
            do {
                let url = debuggerBaseURL.appendingPathComponent("json/list")
                let (data, _) = try await URLSession.shared.data(from: url)
                let targets = try decoder.decode([ChromiumInspectorTarget].self, from: data)
                if let value = targets.first(where: { $0.type == "page" })?.webSocketDebuggerUrl,
                   let pageURL = URL(string: value) {
                    return pageURL
                }
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }

        throw BrowserRuntimeError.browserLaunchFailed(
            "Chromium did not expose a debuggable page\(lastError.map { ": \($0.localizedDescription)" } ?? ".")"
        )
    }
}

private final class ChromiumBrowserProcessController: @unchecked Sendable, BrowserProcessControlling {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    func terminate() async {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
}

struct ChromiumBrowserProcessLauncher: BrowserProcessLaunching {
    func launch(options: BrowserLaunchOptions) async throws -> BrowserLaunchedProcess {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: options.browserPath)
        process.arguments = buildArguments(options: options)
        process.standardOutput = stdout
        process.standardError = stderr

        let controller = ChromiumBrowserProcessController(process: process)
        let debuggerBaseURL = try await withCheckedThrowingContinuation { continuation in
            let state = LaunchState(continuation: continuation, process: process)

            stdout.fileHandleForReading.readabilityHandler = { handle in
                _ = handle.availableData
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    return
                }
                state.append(stderrChunk: data)
            }

            process.terminationHandler = { terminatedProcess in
                state.failIfNeeded(message: "Chromium exited before DevTools became available (exit \(terminatedProcess.terminationStatus)).")
            }

            do {
                try process.run()
            } catch {
                state.failIfNeeded(message: "Failed to start Chromium: \(error.localizedDescription)")
                return
            }

            Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                state.failIfNeeded(message: "Timed out waiting for Chromium DevTools endpoint.")
            }
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        return BrowserLaunchedProcess(controller: controller, debuggerBaseURL: debuggerBaseURL)
    }

    private func buildArguments(options: BrowserLaunchOptions) -> [String] {
        var arguments = [
            "--remote-debugging-port=0",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-dev-shm-usage",
            "--disable-background-networking",
            "--disable-background-timer-throttling",
            "--disable-renderer-backgrounding",
            "--disable-sync",
            "--disable-features=Translate",
            "--no-sandbox",
            "--user-data-dir=\(options.userDataDir)",
            "--profile-directory=\(options.profileDirectory)",
            "about:blank"
        ]
        if options.headless {
            arguments.insert("--headless=new", at: 0)
        }
        return arguments
    }

    private final class LaunchState: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        private var didResume = false
        private let continuation: CheckedContinuation<URL, Error>
        private weak var process: Process?

        init(continuation: CheckedContinuation<URL, Error>, process: Process) {
            self.continuation = continuation
            self.process = process
        }

        func append(stderrChunk: Data) {
            guard let chunk = String(data: stderrChunk, encoding: .utf8) else {
                return
            }

            lock.lock()
            defer { lock.unlock() }
            guard !didResume else {
                return
            }
            buffer += chunk

            let pattern = #"DevTools listening on (ws://[^\s]+)"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return
            }
            let range = NSRange(buffer.startIndex..<buffer.endIndex, in: buffer)
            guard let match = regex.firstMatch(in: buffer, range: range),
                  let valueRange = Range(match.range(at: 1), in: buffer),
                  let wsURL = URL(string: String(buffer[valueRange])),
                  var components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) else {
                return
            }

            components.scheme = wsURL.scheme == "wss" ? "https" : "http"
            components.path = ""
            components.query = nil
            components.fragment = nil

            guard let debuggerBaseURL = components.url else {
                return
            }

            didResume = true
            continuation.resume(returning: debuggerBaseURL)
        }

        func failIfNeeded(message: String) {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume else {
                return
            }
            didResume = true
            if process?.isRunning == true {
                process?.terminate()
            }
            continuation.resume(throwing: BrowserRuntimeError.browserLaunchFailed(message))
        }
    }
}

private struct ChromiumCDPEnvelope: Codable {
    struct Failure: Codable {
        let code: Int?
        let message: String
    }

    let id: Int?
    let method: String?
    let params: [String: JSONValue]?
    let result: [String: JSONValue]?
    let error: Failure?
}

private struct ChromiumCDPRequestEnvelope: Codable {
    let id: Int
    let method: String
    let params: [String: JSONValue]
}

actor ChromiumBrowserCDPSession: BrowserCDPSession {
    private let urlSession: URLSession
    private let webSocketTask: URLSessionWebSocketTask
    private var nextID: Int = 1

    init(webSocketURL: URL) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        self.urlSession = URLSession(configuration: configuration)
        self.webSocketTask = urlSession.webSocketTask(with: webSocketURL)
        self.webSocketTask.resume()
    }

    func call(method: String, params: [String: JSONValue]) async throws -> [String: JSONValue] {
        let requestID = nextID
        nextID += 1

        let payload = ChromiumCDPRequestEnvelope(id: requestID, method: method, params: params)
        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)
        try await webSocketTask.send(.data(data))

        while true {
            let message = try await webSocketTask.receive()
            let responseData: Data
            switch message {
            case .string(let text):
                responseData = Data(text.utf8)
            case .data(let data):
                responseData = data
            @unknown default:
                continue
            }

            let envelope = try JSONDecoder().decode(ChromiumCDPEnvelope.self, from: responseData)
            if envelope.method != nil {
                continue
            }
            guard envelope.id == requestID else {
                continue
            }
            if let error = envelope.error {
                throw BrowserRuntimeError.cdpFailure(error.message)
            }
            return envelope.result ?? [:]
        }
    }

    func close() async {
        webSocketTask.cancel(with: .normalClosure, reason: nil)
        urlSession.invalidateAndCancel()
    }
}

struct ChromiumCDPConnector: BrowserCDPConnecting {
    func connect(webSocketURL: URL) async throws -> any BrowserCDPSession {
        ChromiumBrowserCDPSession(webSocketURL: webSocketURL)
    }
}
