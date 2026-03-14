import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Core
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

            let modelsBody =
                """
                {
                  "models": [
                    {
                      "id": "gpt-5.3-codex",
                      "display_name": "GPT-5.3 Codex",
                      "supported_reasoning_efforts": ["low", "medium", "high"]
                    }
                  ]
                }
                """
            return (Data(modelsBody.utf8), makeOAuthHTTPResponse(url: request.url ?? URL(string: "https://chatgpt.com/backend-api/codex/models")!))
        }
    )

    let start = try service.startLogin(redirectURI: "http://127.0.0.1:4173/config")
    _ = try await service.completeLogin(
        request: OpenAIOAuthCompleteRequest(
            callbackURL: "http://127.0.0.1:4173/config?code=test-code&state=\(start.state)"
        )
    )

    let models = try await service.fetchModels()
    #expect(models.contains(where: { $0.id == "gpt-5.3-codex" }))
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
