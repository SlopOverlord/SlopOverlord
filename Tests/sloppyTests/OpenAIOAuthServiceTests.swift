import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import sloppy
@testable import Protocols

private func makeOAuthHTTPResponse(url: URL, statusCode: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
}

private func makeJWT(claims: [String: Any]) throws -> String {
    let header = try JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"])
    let payload = try JSONSerialization.data(withJSONObject: claims)
    return "\(base64URLEncode(header)).\(base64URLEncode(payload)).signature"
}

private func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

@Test
func openAIOAuthStartLoginPersistsPendingSession() throws {
    let workspaceRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openai-oauth-start-\(UUID().uuidString)", isDirectory: true)
    let service = OpenAIOAuthService(workspaceRootURL: workspaceRootURL)

    let response = try service.startLogin(redirectURI: "http://127.0.0.1:4173/config")
    let authorizationURL = try #require(URL(string: response.authorizationURL))
    let components = try #require(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false))
    let queryItems = components.queryItems ?? []

    #expect(components.scheme == "https")
    #expect(components.host == "auth.openai.com")
    #expect(queryItems.first(where: { $0.name == "client_id" })?.value == "app_EMoamEEZ73f0CkXaXp7hrann")
    #expect(queryItems.first(where: { $0.name == "redirect_uri" })?.value == "http://127.0.0.1:4173/config")
    #expect(queryItems.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
    #expect(queryItems.first(where: { $0.name == "state" })?.value == response.state)

    let pendingURL = workspaceRootURL.appendingPathComponent("auth/openai-oauth-pending.json")
    #expect(FileManager.default.fileExists(atPath: pendingURL.path))
}

@Test
func openAIOAuthCompleteLoginStoresTokensAndStatus() async throws {
    let workspaceRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openai-oauth-complete-\(UUID().uuidString)", isDirectory: true)
    let accessToken = try makeJWT(
        claims: [
            "exp": NSNumber(value: 2_000_000_000),
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_test_123",
                "chatgpt_plan_type": "plus"
            ]
        ]
    )
    let service = OpenAIOAuthService(
        workspaceRootURL: workspaceRootURL,
        transport: { request in
            let body =
                """
                {
                  "access_token": "\(accessToken)",
                  "refresh_token": "refresh_test",
                  "id_token": "id_test"
                }
                """
            return (Data(body.utf8), makeOAuthHTTPResponse(url: request.url ?? URL(string: "https://auth.openai.com/oauth/token")!))
        }
    )

    let start = try service.startLogin(redirectURI: "http://127.0.0.1:4173/config")
    let completion = try await service.completeLogin(
        request: OpenAIOAuthCompleteRequest(
            callbackURL: "http://127.0.0.1:4173/config?code=test-code&state=\(start.state)"
        )
    )

    #expect(completion.ok == true)
    #expect(completion.accountId == "acct_test_123")
    #expect(completion.planType == "plus")

    let status = service.status()
    #expect(status.hasCredentials == true)
    #expect(status.accountId == "acct_test_123")
    #expect(status.planType == "plus")

    let authURL = workspaceRootURL.appendingPathComponent("auth/openai-oauth-auth.json")
    #expect(FileManager.default.fileExists(atPath: authURL.path))
}

@Test
func openAIOAuthFetchModelsAcceptsModelsArrayPayload() async throws {
    let workspaceRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openai-oauth-models-\(UUID().uuidString)", isDirectory: true)
    let codexRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openai-oauth-models-codex-\(UUID().uuidString)", isDirectory: true)
    let codexAuthURL = codexRootURL.appendingPathComponent("auth.json")
    let codexModelsCacheURL = codexRootURL.appendingPathComponent("models_cache.json")
    try FileManager.default.createDirectory(at: codexRootURL, withIntermediateDirectories: true)
    try Data(#"{"client_version":"0.128.0"}"#.utf8).write(to: codexModelsCacheURL)
    let requestedModelsURL = SendableStringBox()
    let accessToken = try makeJWT(
        claims: [
            "exp": NSNumber(value: 2_000_000_000),
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_test_123",
                "chatgpt_plan_type": "plus"
            ]
        ]
    )

    let service = OpenAIOAuthService(
        workspaceRootURL: workspaceRootURL,
        transport: { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/oauth/token") {
                let body =
                    """
                    {
                      "access_token": "\(accessToken)",
                      "refresh_token": "refresh_test",
                      "id_token": "id_test"
                    }
                    """
                return (Data(body.utf8), makeOAuthHTTPResponse(url: request.url ?? URL(string: "https://auth.openai.com/oauth/token")!))
            }

            requestedModelsURL.value = url
            let modelsBody =
                """
                {
                  "models": [
                    {
                      "id": "gpt-5.3-codex",
                      "display_name": "GPT-5.3 Codex",
                      "supported_reasoning_efforts": ["low", "medium", "high"],
                      "context_window": 1048576
                    }
                  ]
                }
            """
            return (Data(modelsBody.utf8), makeOAuthHTTPResponse(url: request.url ?? URL(string: "https://chatgpt.com/backend-api/codex/models")!))
        },
        codexCredentialsURL: codexAuthURL,
        codexModelsCacheURL: codexModelsCacheURL
    )

    let start = try service.startLogin(redirectURI: "http://127.0.0.1:4173/config")
    _ = try await service.completeLogin(
        request: OpenAIOAuthCompleteRequest(
            callbackURL: "http://127.0.0.1:4173/config?code=test-code&state=\(start.state)"
        )
    )

    let models = try await service.fetchModels()
    let codexModel = models.first(where: { $0.id == "gpt-5.3-codex" })
    #expect(codexModel != nil)
    #expect(codexModel?.contextWindow == "1.0M")
    #expect(codexModel?.capabilities.contains("reasoning") == true)
    #expect(requestedModelsURL.value.contains("client_version=0.128.0"))
}

@Test
func formatContextWindowFormatsTokenCounts() {
    #expect(OpenAIOAuthService.formatContextWindow(nil) == nil)
    #expect(OpenAIOAuthService.formatContextWindow(0) == nil)
    #expect(OpenAIOAuthService.formatContextWindow(512) == "512")
    #expect(OpenAIOAuthService.formatContextWindow(4096) == "4.1K")
    #expect(OpenAIOAuthService.formatContextWindow(4000) == "4K")
    #expect(OpenAIOAuthService.formatContextWindow(128_000) == "128K")
    #expect(OpenAIOAuthService.formatContextWindow(200_000) == "200K")
    #expect(OpenAIOAuthService.formatContextWindow(1_000_000) == "1M")
    #expect(OpenAIOAuthService.formatContextWindow(1_048_576) == "1.0M")
}

@Test
func openAIOAuthEnsureValidTokenRefreshesExpiredToken() async throws {
    let workspaceRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openai-oauth-refresh-\(UUID().uuidString)", isDirectory: true)

    let expiredToken = try makeJWT(
        claims: [
            "exp": NSNumber(value: 1_000_000),
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_test_123",
                "chatgpt_plan_type": "plus"
            ]
        ]
    )
    let freshToken = try makeJWT(
        claims: [
            "exp": NSNumber(value: 4_000_000_000),
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_test_123",
                "chatgpt_plan_type": "plus"
            ]
        ]
    )

    let tracker = SendableFlag()
    let service = OpenAIOAuthService(
        workspaceRootURL: workspaceRootURL,
        transport: { request in
            let url = request.url?.absoluteString ?? ""
            guard url.contains("/oauth/token") else { throw URLError(.badURL) }
            let bodyString = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let isRefresh = bodyString.contains("grant_type=refresh_token")
            if isRefresh {
                tracker.set()
                let body =
                    """
                    {
                      "access_token": "\(freshToken)",
                      "refresh_token": "refresh_new",
                      "id_token": "id_test"
                    }
                    """
                return (Data(body.utf8), makeOAuthHTTPResponse(url: request.url ?? URL(string: "https://auth.openai.com/oauth/token")!))
            }
            let body =
                """
                {
                  "access_token": "\(expiredToken)",
                  "refresh_token": "refresh_initial",
                  "id_token": "id_test"
                }
                """
            return (Data(body.utf8), makeOAuthHTTPResponse(url: request.url ?? URL(string: "https://auth.openai.com/oauth/token")!))
        }
    )

    let start = try service.startLogin(redirectURI: "http://127.0.0.1:4173/config")
    _ = try await service.completeLogin(
        request: OpenAIOAuthCompleteRequest(
            callbackURL: "http://127.0.0.1:4173/config?code=test-code&state=\(start.state)"
        )
    )

    let tokenBefore = service.currentAccessToken()
    #expect(tokenBefore == expiredToken)

    tracker.reset()
    try await service.ensureValidToken()
    #expect(tracker.value)

    let tokenAfter = service.currentAccessToken()
    #expect(tokenAfter == freshToken)
}

@Test
func openAIOAuthEnsureValidTokenCanForceRefreshUnexpiredToken() async throws {
    let workspaceRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openai-oauth-force-refresh-\(UUID().uuidString)", isDirectory: true)

    let initialToken = try makeJWT(
        claims: [
            "exp": NSNumber(value: 4_000_000_000),
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_test_123",
                "chatgpt_plan_type": "plus"
            ]
        ]
    )
    let freshToken = try makeJWT(
        claims: [
            "exp": NSNumber(value: 4_000_000_001),
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_test_123",
                "chatgpt_plan_type": "plus"
            ]
        ]
    )

    let tracker = SendableFlag()
    let service = OpenAIOAuthService(
        workspaceRootURL: workspaceRootURL,
        transport: { request in
            let bodyString = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if bodyString.contains("grant_type=refresh_token") {
                tracker.set()
                let body =
                    """
                    {
                      "access_token": "\(freshToken)",
                      "refresh_token": "refresh_new",
                      "id_token": "id_test"
                    }
                    """
                return (Data(body.utf8), makeOAuthHTTPResponse(url: request.url ?? URL(string: "https://auth.openai.com/oauth/token")!))
            }
            let body =
                """
                {
                  "access_token": "\(initialToken)",
                  "refresh_token": "refresh_initial",
                  "id_token": "id_test"
                }
                """
            return (Data(body.utf8), makeOAuthHTTPResponse(url: request.url ?? URL(string: "https://auth.openai.com/oauth/token")!))
        }
    )

    let start = try service.startLogin(redirectURI: "http://127.0.0.1:4173/config")
    _ = try await service.completeLogin(
        request: OpenAIOAuthCompleteRequest(
            callbackURL: "http://127.0.0.1:4173/config?code=test-code&state=\(start.state)"
        )
    )

    tracker.reset()
    try await service.ensureValidToken()
    #expect(!tracker.value)
    #expect(service.currentAccessToken() == initialToken)

    try await service.ensureValidToken(forceRefresh: true)
    #expect(tracker.value)
    #expect(service.currentAccessToken() == freshToken)
}

@Test
func openAIOAuthEnsureValidTokenSerializesConcurrentExpiredRefreshes() async throws {
    let workspaceRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openai-oauth-concurrent-refresh-\(UUID().uuidString)", isDirectory: true)

    let expiredToken = try makeJWT(
        claims: [
            "exp": NSNumber(value: 1_000_000),
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_test_123",
                "chatgpt_plan_type": "plus"
            ]
        ]
    )
    let freshToken = try makeJWT(
        claims: [
            "exp": NSNumber(value: 4_000_000_000),
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_test_123",
                "chatgpt_plan_type": "plus"
            ]
        ]
    )

    let attempts = RefreshAttemptRecorder()
    let service = OpenAIOAuthService(
        workspaceRootURL: workspaceRootURL,
        transport: { request in
            let bodyString = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if bodyString.contains("grant_type=refresh_token") {
                let attempt = await attempts.record()
                try await Task.sleep(nanoseconds: 50_000_000)
                if attempt > 1 {
                    let body =
                        """
                        {
                          "error": {
                            "message": "Your refresh token has already been used to generate a new access token.",
                            "type": "invalid_request_error",
                            "code": "refresh_token_reused"
                          }
                        }
                        """
                    return (
                        Data(body.utf8),
                        makeOAuthHTTPResponse(
                            url: request.url ?? URL(string: "https://auth.openai.com/oauth/token")!,
                            statusCode: 401
                        )
                    )
                }
                let body =
                    """
                    {
                      "access_token": "\(freshToken)",
                      "refresh_token": "refresh_new",
                      "id_token": "id_test"
                    }
                    """
                return (
                    Data(body.utf8),
                    makeOAuthHTTPResponse(url: request.url ?? URL(string: "https://auth.openai.com/oauth/token")!)
                )
            }

            let body =
                """
                {
                  "access_token": "\(expiredToken)",
                  "refresh_token": "refresh_initial",
                  "id_token": "id_test"
                }
                """
            return (
                Data(body.utf8),
                makeOAuthHTTPResponse(url: request.url ?? URL(string: "https://auth.openai.com/oauth/token")!)
            )
        }
    )

    let start = try service.startLogin(redirectURI: "http://127.0.0.1:4173/config")
    _ = try await service.completeLogin(
        request: OpenAIOAuthCompleteRequest(
            callbackURL: "http://127.0.0.1:4173/config?code=test-code&state=\(start.state)"
        )
    )

    async let first: Void = service.ensureValidToken()
    async let second: Void = service.ensureValidToken()
    _ = try await (first, second)

    #expect(await attempts.value() == 1)
    #expect(service.currentAccessToken() == freshToken)
}

@Test
func openAIOAuthStartDeviceCodeReturnsUserCode() async throws {
    let workspaceRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openai-oauth-device-\(UUID().uuidString)", isDirectory: true)

    let service = OpenAIOAuthService(
        workspaceRootURL: workspaceRootURL,
        transport: { request in
            let url = request.url?.absoluteString ?? ""
            guard url.contains("deviceauth/usercode") else {
                throw URLError(.badURL)
            }
            let body =
                """
                {
                  "device_auth_id": "dev_abc123",
                  "user_code": "ABCD-1234",
                  "interval": 5,
                  "expires_in": 600,
                  "verification_url": "https://auth.openai.com/codex/device"
                }
                """
            return (Data(body.utf8), makeOAuthHTTPResponse(url: request.url ?? URL(string: "https://auth.openai.com")!))
        }
    )

    let response = try await service.startDeviceCode()
    #expect(response.deviceAuthId == "dev_abc123")
    #expect(response.userCode == "ABCD-1234")
    #expect(response.verificationURL == "https://auth.openai.com/codex/device")
    #expect(response.interval == 5)
    #expect(response.expiresIn == 600)
}

@Test
func openAIOAuthPollDeviceTokenReturnsPending() async throws {
    let workspaceRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openai-oauth-poll-pending-\(UUID().uuidString)", isDirectory: true)

    let service = OpenAIOAuthService(
        workspaceRootURL: workspaceRootURL,
        transport: { request in
            let url = request.url?.absoluteString ?? ""
            guard url.contains("deviceauth/token") else {
                throw URLError(.badURL)
            }
            let body = """
            {"error": "authorization_pending", "error_description": "User has not yet authorized"}
            """
            return (Data(body.utf8), makeOAuthHTTPResponse(url: request.url!, statusCode: 400))
        }
    )

    let response = try await service.pollDeviceToken(deviceAuthId: "dev_abc123", userCode: "ABCD-1234")
    #expect(response.status == "pending")
    #expect(response.ok == false)
}

@Test
func openAIOAuthPollDeviceTokenCompletesOnApproval() async throws {
    let workspaceRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openai-oauth-poll-approved-\(UUID().uuidString)", isDirectory: true)

    let accessToken = try makeJWT(
        claims: [
            "exp": NSNumber(value: 2_000_000_000),
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_device_test",
                "chatgpt_plan_type": "plus"
            ]
        ]
    )

    let service = OpenAIOAuthService(
        workspaceRootURL: workspaceRootURL,
        transport: { request in
            let url = request.url?.absoluteString ?? ""

            if url.contains("deviceauth/token") {
                let body = """
                {"authorization_code": "auth_code_xyz", "code_verifier": "verifier_xyz"}
                """
                return (Data(body.utf8), makeOAuthHTTPResponse(url: request.url!))
            }

            if url.contains("/oauth/token") {
                let body =
                    """
                    {
                      "access_token": "\(accessToken)",
                      "refresh_token": "refresh_device",
                      "id_token": "id_device"
                    }
                    """
                return (Data(body.utf8), makeOAuthHTTPResponse(url: request.url!))
            }

            throw URLError(.badURL)
        }
    )

    let response = try await service.pollDeviceToken(deviceAuthId: "dev_abc123", userCode: "ABCD-1234")
    #expect(response.status == "approved")
    #expect(response.ok == true)
    #expect(response.accountId == "acct_device_test")
    #expect(response.planType == "plus")

    let storedToken = service.currentAccessToken()
    #expect(storedToken == accessToken)
}

@Test
func openAIOAuthImportCodexCredentialsReadsLocalAuthFile() async throws {
    let workspaceRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openai-oauth-import-codex-\(UUID().uuidString)", isDirectory: true)
    let codexRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openai-oauth-codex-home-\(UUID().uuidString)", isDirectory: true)
    let codexAuthURL = codexRootURL.appendingPathComponent("auth.json")

    let accessToken = try makeJWT(
        claims: [
            "exp": NSNumber(value: 2_000_000_000),
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_imported",
                "chatgpt_plan_type": "plus"
            ]
        ]
    )
    let body =
        """
        {
          "auth_mode": "chatgpt",
          "OPENAI_API_KEY": null,
          "tokens": {
            "id_token": "id_imported",
            "access_token": "\(accessToken)",
            "refresh_token": "refresh_imported"
          },
          "last_refresh": "2026-01-01T00:00:00Z"
        }
        """
    try FileManager.default.createDirectory(at: codexRootURL, withIntermediateDirectories: true)
    try Data(body.utf8).write(to: codexAuthURL)

    let service = OpenAIOAuthService(
        workspaceRootURL: workspaceRootURL,
        codexCredentialsURL: codexAuthURL
    )

    let response = try await service.importCodexCredentials()
    #expect(response.ok)
    #expect(response.accountId == "acct_imported")
    #expect(response.planType == "plus")
    #expect(service.currentAccessToken() == accessToken)
    #expect(service.currentAccountId() == "acct_imported")
}

@Test
func openAIOAuthDeviceCodeCloudflareChallengeReturnsFriendlyMessage() async throws {
    let workspaceRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openai-oauth-device-cloudflare-\(UUID().uuidString)", isDirectory: true)

    let service = OpenAIOAuthService(
        workspaceRootURL: workspaceRootURL,
        transport: { request in
            let html = "<!DOCTYPE html><html><head><title>Just a moment...</title></head><body>challenges.cloudflare.com</body></html>"
            return (Data(html.utf8), makeOAuthHTTPResponse(url: request.url!, statusCode: 403))
        }
    )

    do {
        _ = try await service.startDeviceCode()
        Issue.record("Expected Cloudflare challenge error")
    } catch {
        #expect(error.localizedDescription.contains("Cloudflare challenge"))
        #expect(!error.localizedDescription.contains("<!DOCTYPE html>"))
    }
}

@Test
func openAIOAuthStartDeviceCodeHandles404() async throws {
    let workspaceRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openai-oauth-device-404-\(UUID().uuidString)", isDirectory: true)

    let service = OpenAIOAuthService(
        workspaceRootURL: workspaceRootURL,
        transport: { request in
            return (Data("Not Found".utf8), makeOAuthHTTPResponse(url: request.url!, statusCode: 404))
        }
    )

    do {
        _ = try await service.startDeviceCode()
        Issue.record("Expected error for 404 response")
    } catch {
        #expect(error.localizedDescription.contains("Device code login is not enabled"))
    }
}

@Test
func openAIOAuthDisconnectRemovesCredentials() async throws {
    let workspaceRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openai-oauth-disconnect-\(UUID().uuidString)", isDirectory: true)

    let accessToken = try makeJWT(
        claims: [
            "exp": NSNumber(value: 2_000_000_000),
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_test_dc",
                "chatgpt_plan_type": "plus"
            ]
        ]
    )

    let service = OpenAIOAuthService(
        workspaceRootURL: workspaceRootURL,
        transport: { request in
            let body =
                """
                {
                  "access_token": "\(accessToken)",
                  "refresh_token": "refresh_dc",
                  "id_token": "id_dc"
                }
                """
            return (Data(body.utf8), makeOAuthHTTPResponse(url: request.url!))
        }
    )

    let start = try service.startLogin(redirectURI: "http://127.0.0.1:4173/config")
    _ = try await service.completeLogin(
        request: OpenAIOAuthCompleteRequest(
            callbackURL: "http://127.0.0.1:4173/config?code=test-code&state=\(start.state)"
        )
    )

    #expect(service.currentAccessToken() != nil)
    #expect(service.status().hasCredentials == true)

    try service.disconnect()

    #expect(service.currentAccessToken() == nil)
    #expect(service.status().hasCredentials == false)
}

private final class SendableFlag: @unchecked Sendable {
    private var _value = false
    var value: Bool { _value }
    func set() { _value = true }
    func reset() { _value = false }
}

private final class SendableStringBox: @unchecked Sendable {
    var value = ""
}

private actor RefreshAttemptRecorder {
    private var count = 0

    func record() -> Int {
        count += 1
        return count
    }

    func value() -> Int {
        count
    }
}
