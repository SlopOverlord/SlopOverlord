import Foundation
import Testing
@testable import sloppy
import Protocols

// MARK: - CLIStyle tests

@Test
func cliStyleColorDisabledWhenNoColor() {
    // CLIStyle.isColor is computed at init time from env; we test the helper functions
    // by checking that non-color output equals input when colors are stripped.
    let raw = "hello"
    let colored = CLIStyle.green(raw)
    // If color is enabled the output contains ANSI codes; if not it equals raw.
    // Either way it must contain the original string.
    #expect(colored.contains(raw))
}

@Test
func cliStyleBoldContainsInput() {
    #expect(CLIStyle.bold("test").contains("test"))
}

@Test
func cliStyleDimContainsInput() {
    #expect(CLIStyle.dim("info").contains("info"))
}

@Test
func cliStyleCyanBoldContainsInput() {
    #expect(CLIStyle.cyanBold("cmd").contains("cmd"))
}

@Test
func cliStyleRedBoldContainsInput() {
    #expect(CLIStyle.redBold("err").contains("err"))
}

@Test
func cliStyleWhiteBoldContainsInput() {
    #expect(CLIStyle.whiteBold("id-123").contains("id-123"))
}

// MARK: - Service command tests

@Test
func serviceLaunchAgentPathCombinesInstallEnvironmentWithFallbacks() {
    let path = ServiceManager.launchAgentPATH(
        environment: ["PATH": "/custom/bin:/usr/bin:/custom/bin"]
    )
    let components = path.split(separator: ":").map(String.init)

    #expect(components.prefix(2) == ["/custom/bin", "/usr/bin"])
    #expect(components.contains("/opt/homebrew/bin"))
    #expect(components.contains("/usr/local/bin"))
    #expect(components.contains("/bin"))
    #expect(components.filter { $0 == "/custom/bin" }.count == 1)
    #expect(components.filter { $0 == "/usr/bin" }.count == 1)
}

@Test
func serviceLaunchAgentPlistIncludesPathEnvironmentOnly() throws {
    let plist = ServiceManager.makePlist(
        executablePath: "/tmp/sloppy&server",
        configPath: "/tmp/sloppy <config>.json",
        environment: [
            "PATH": "/custom/bin",
            "SLOPPY_TOKEN": "secret",
        ]
    )
    let data = try #require(plist.data(using: .utf8))
    let rootObject = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    let root = try #require(rootObject as? [String: Any])
    let environment = try #require(root["EnvironmentVariables"] as? [String: String])
    let programArguments = try #require(root["ProgramArguments"] as? [String])

    #expect(environment == ["PATH": ServiceManager.launchAgentPATH(environment: ["PATH": "/custom/bin"])])
    #expect(programArguments == ["/tmp/sloppy&server", "run", "--config-path", "/tmp/sloppy <config>.json"])
    #expect(!plist.contains("SLOPPY_TOKEN"))
    #expect(!plist.contains("secret"))
}

// MARK: - CLIFormatters tests

@Test
func cliFormattersResolvesKnownFormats() {
    #expect(CLIFormatters.resolveFormat("json") == .json)
    #expect(CLIFormatters.resolveFormat("table") == .table)
    #expect(CLIFormatters.resolveFormat("JSON") == .json)
}

@Test
func cliFormattersResolvesUnknownAsJSON() {
    #expect(CLIFormatters.resolveFormat("xml") == .json)
    #expect(CLIFormatters.resolveFormat("") == .json)
}

@Test
func cliFormattersOutputJSONParseable() {
    let json = #"{"key":"value"}"#.data(using: .utf8)!
    // printJSON should not crash on valid JSON data
    // We just verify it does not throw
    CLIFormatters.printJSON(json)
}

@Test
func cliFormattersPrintTableEmpty() {
    // Printing an empty table should produce "(no results)"  output without crashing
    CLIFormatters.printTable(
        rows: [String](),
        columns: [(header: "ID", value: { $0 })]
    )
}

@Test
func cliFormattersPrintTableNonEmpty() {
    let rows = ["alpha", "beta", "gamma"]
    CLIFormatters.printTable(
        rows: rows,
        columns: [
            (header: "Name", value: { $0 }),
            (header: "Length", value: { "\($0.count)" }),
        ]
    )
}

// MARK: - SloppyCLIClient resolve tests

@Test
func cliClientResolveUsesDefaultURL() {
    let client = SloppyCLIClient.resolve(url: nil, token: nil, verbose: false)
    // When no env or config is set falls back to the default
    #expect(client.baseURL.hasPrefix("http"))
    #expect(!client.baseURL.hasSuffix("/"))
}

@Test
func cliClientResolveUsesExplicitURL() {
    let client = SloppyCLIClient.resolve(url: "http://example.com:9999", token: "tok", verbose: false)
    #expect(client.baseURL == "http://example.com:9999")
    #expect(client.token == "tok")
}

@Test
func cliClientResolveStripsTrailingSlash() {
    let client = SloppyCLIClient.resolve(url: "http://localhost:8080/", token: nil, verbose: false)
    #expect(!client.baseURL.hasSuffix("/"))
}

@Test
func cliClientVerboseFlagPropagates() {
    let client = SloppyCLIClient.resolve(url: nil, token: nil, verbose: true)
    #expect(client.verbose == true)
}

// MARK: - CLIClientError descriptions

@Test
func cliClientErrorNotConnectedDescription() {
    let err = CLIClientError.notConnected("http://localhost:1234")
    #expect(err.errorDescription?.contains("http://localhost:1234") == true)
}

@Test
func cliClientErrorHTTPErrorDescription() {
    let err = CLIClientError.httpError(404, "not found")
    #expect(err.errorDescription?.contains("404") == true)
}

@Test
func cliClientErrorInvalidURLDescription() {
    let err = CLIClientError.invalidURL
    #expect(err.errorDescription != nil)
}

// MARK: - OpenAI device auth flow

@Test
func openAIDeviceAuthorizationFlowApprovesAfterPendingPoll() async throws {
    let clock = MutableTestClock(now: Date(timeIntervalSince1970: 0))
    let poller = PollResponseSequence(
        responses: [
            .init(status: "pending", ok: false, message: "Waiting"),
            .init(status: "approved", ok: true, message: "Connected", accountId: "acct_123", planType: "plus"),
        ]
    )
    let sleeps = SleepRecorder()

    let response = try await OpenAIDeviceAuthorizationFlow.pollUntilApproved(
        request: .init(deviceAuthId: "device_123", userCode: "ABCD-1234"),
        initialInterval: 5,
        timeoutSeconds: 30,
        poll: { _ in
            try poller.next()
        },
        sleep: { seconds in
            sleeps.append(seconds)
            clock.advance(by: seconds)
        },
        now: { clock.now }
    )

    #expect(response.status == "approved")
    #expect(response.ok == true)
    #expect(response.accountId == "acct_123")
    #expect(sleeps.values == [5])
}

@Test
func openAIDeviceAuthorizationFlowBacksOffWhenServerRequestsSlowDown() async throws {
    let clock = MutableTestClock(now: Date(timeIntervalSince1970: 0))
    let poller = PollResponseSequence(
        responses: [
            .init(status: "slow_down", ok: false, message: "Slow down"),
            .init(status: "approved", ok: true, message: "Connected"),
        ]
    )
    let sleeps = SleepRecorder()

    let response = try await OpenAIDeviceAuthorizationFlow.pollUntilApproved(
        request: .init(deviceAuthId: "device_123", userCode: "ABCD-1234"),
        initialInterval: 5,
        timeoutSeconds: 30,
        poll: { _ in
            try poller.next()
        },
        sleep: { seconds in
            sleeps.append(seconds)
            clock.advance(by: seconds)
        },
        now: { clock.now }
    )

    #expect(response.status == "approved")
    #expect(sleeps.values == [10])
}

@Test
func openAIDeviceAuthorizationFlowTimesOutAfterExpiration() async throws {
    let clock = MutableTestClock(now: Date(timeIntervalSince1970: 0))
    let poller = PollResponseSequence(
        responses: [
            .init(status: "pending", ok: false, message: "Waiting"),
            .init(status: "pending", ok: false, message: "Still waiting"),
        ]
    )
    let sleeps = SleepRecorder()

    do {
        _ = try await OpenAIDeviceAuthorizationFlow.pollUntilApproved(
            request: .init(deviceAuthId: "device_123", userCode: "ABCD-1234"),
            initialInterval: 5,
            timeoutSeconds: 5,
            poll: { _ in
                try poller.next()
            },
            sleep: { seconds in
                sleeps.append(seconds)
                clock.advance(by: seconds)
            },
            now: { clock.now }
        )
        Issue.record("Expected device authorization flow to time out.")
    } catch let error as OpenAIDeviceAuthorizationFlow.FlowError {
        switch error {
        case let .timedOut(seconds):
            #expect(seconds == 5)
        default:
            Issue.record("Expected timeout error, got \(error.localizedDescription)")
        }
    }

    #expect(sleeps.values == [5])
}

private final class MutableTestClock: @unchecked Sendable {
    var now: Date

    init(now: Date) {
        self.now = now
    }

    func advance(by seconds: Int) {
        now = now.addingTimeInterval(TimeInterval(seconds))
    }
}

private final class SleepRecorder: @unchecked Sendable {
    private(set) var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }
}

private final class PollResponseSequence: @unchecked Sendable {
    private var responses: [OpenAIDeviceCodePollResponse]

    init(responses: [OpenAIDeviceCodePollResponse]) {
        self.responses = responses
    }

    func next() throws -> OpenAIDeviceCodePollResponse {
        guard !responses.isEmpty else {
            throw CLIClientError.noData
        }
        return responses.removeFirst()
    }
}
