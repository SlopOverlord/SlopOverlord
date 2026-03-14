import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging
import Protocols

struct OpenAIOAuthStatus: Sendable {
    var hasCredentials: Bool
    var accountId: String?
    var planType: String?
    var expiresAt: String?
}

struct OpenAIOAuthService: @unchecked Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let authorizationEndpoint = URL(string: "https://auth.openai.com/oauth/authorize")!
    private static let tokenEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    private static let modelsEndpoint = URL(string: "https://chatgpt.com/backend-api/codex/models?client_version=0.113.0")!
    private static let deviceUserCodeEndpoint = URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!
    private static let deviceTokenEndpoint = URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!
    private static let deviceRedirectURI = "https://auth.openai.com/deviceauth/callback"
    private static let defaultDeviceVerificationURL = "https://auth.openai.com/codex/device"
    private static let logger = Logger(label: "sloppy.core.openai-oauth")

    private struct PendingSession: Codable, Sendable {
        var state: String
        var codeVerifier: String
        var redirectURI: String
        var createdAt: String
    }

    private struct StoredAuth: Codable, Sendable {
        struct Tokens: Codable, Sendable {
            var idToken: String?
            var accessToken: String
            var refreshToken: String?
            var accountId: String?

            enum CodingKeys: String, CodingKey {
                case idToken = "id_token"
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case accountId = "account_id"
            }
        }

        var authMode: String
        var openAIAPIKey: String?
        var tokens: Tokens
        var lastRefresh: String

        enum CodingKeys: String, CodingKey {
            case authMode = "auth_mode"
            case openAIAPIKey = "OPENAI_API_KEY"
            case tokens
            case lastRefresh = "last_refresh"
        }
    }

    private struct TokenResponse: Decodable {
        var accessToken: String
        var refreshToken: String?
        var idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
        }
    }

    private struct DeviceCodeAPIResponse: Sendable {
        var deviceAuthId: String
        var userCode: String
        var interval: Int?
        var expiresIn: Int?
        var verificationUrl: String?

        static func decode(from data: Data) throws -> DeviceCodeAPIResponse {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "Device code response is not a JSON object.")
                )
            }

            guard let deviceAuthId = object["device_auth_id"] as? String, !deviceAuthId.isEmpty else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "Missing device_auth_id.")
                )
            }
            guard let userCode = object["user_code"] as? String, !userCode.isEmpty else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "Missing user_code.")
                )
            }

            let interval = intFromStringOrNumber(object["interval"])
            let expiresIn = intFromStringOrNumber(object["expires_in"])
            let verificationUrl = (object["verification_url"] as? String)
                ?? (object["verification_uri"] as? String)

            return DeviceCodeAPIResponse(
                deviceAuthId: deviceAuthId,
                userCode: userCode,
                interval: interval,
                expiresIn: expiresIn,
                verificationUrl: verificationUrl
            )
        }

        private static func intFromStringOrNumber(_ value: Any?) -> Int? {
            if let number = value as? NSNumber {
                return number.intValue
            }
            if let string = value as? String {
                return Int(string)
            }
            return nil
        }
    }

    private struct DeviceTokenSuccessResponse: Decodable {
        var authorizationCode: String
        var codeVerifier: String

        enum CodingKeys: String, CodingKey {
            case authorizationCode = "authorization_code"
            case codeVerifier = "code_verifier"
        }
    }

    private struct DeviceTokenErrorResponse: Decodable {
        var error: String?
        var errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    enum DeviceTokenPollResult {
        case pending
        case slowDown
        case approved(authorizationCode: String, codeVerifier: String)
    }

    private struct RemoteModelsResponse: Decodable {
        struct ReasoningEffort: Decodable {
            var reasoningEffort: String
        }

        struct Model: Decodable {
            var id: String
            var displayName: String?
            var description: String?
            var supportedReasoningEfforts: [ReasoningEffort]?
        }

        var data: [Model]
    }

    enum Error: LocalizedError {
        case invalidRedirectURI
        case missingCredentials
        case missingPendingSession
        case invalidCallback
        case stateMismatch
        case missingAuthorizationCode
        case tokenExchangeFailed(String)
        case missingAccessToken
        case missingAccountID
        case invalidTokenPayload

        var errorDescription: String? {
            switch self {
            case .invalidRedirectURI:
                return "OpenAI OAuth redirect URI is invalid."
            case .missingCredentials:
                return "OpenAI OAuth is not connected yet. Start sign-in first."
            case .missingPendingSession:
                return "OpenAI OAuth login session is missing. Start sign-in again."
            case .invalidCallback:
                return "OpenAI OAuth callback is invalid."
            case .stateMismatch:
                return "OpenAI OAuth state mismatch. Start sign-in again."
            case .missingAuthorizationCode:
                return "OpenAI OAuth callback is missing the authorization code."
            case let .tokenExchangeFailed(message):
                return "OpenAI OAuth token exchange failed: \(message)"
            case .missingAccessToken:
                return "OpenAI OAuth token response is missing the access token."
            case .missingAccountID:
                return "OpenAI OAuth token does not contain a ChatGPT account id."
            case .invalidTokenPayload:
                return "OpenAI OAuth token payload is invalid."
            }
        }
    }

    private let workspaceRootURL: URL
    private let fileManager: FileManager
    private let transport: Transport
    private let now: @Sendable () -> Date

    init(
        workspaceRootURL: URL,
        fileManager: FileManager = .default,
        transport: Transport? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.workspaceRootURL = workspaceRootURL
        self.fileManager = fileManager
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession(configuration: .default).data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return (data, http)
        }
        self.now = now
    }

    func startLogin(redirectURI: String) throws -> OpenAIOAuthStartResponse {
        guard let redirectURL = URL(string: redirectURI), let scheme = redirectURL.scheme, !scheme.isEmpty else {
            throw Error.invalidRedirectURI
        }

        let verifier = Self.randomURLSafeString(byteCount: 48)
        let state = Self.randomURLSafeString(byteCount: 24)
        let challenge = Self.sha256Base64URL(verifier)
        let pending = PendingSession(
            state: state,
            codeVerifier: verifier,
            redirectURI: redirectURI,
            createdAt: Self.iso8601String(from: now())
        )
        try savePendingSession(pending)

        var components = URLComponents(url: Self.authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: Self.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: "openid profile email offline_access"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true")
        ]

        guard let authorizationURL = components?.url else {
            throw Error.invalidRedirectURI
        }

        return OpenAIOAuthStartResponse(
            authorizationURL: authorizationURL.absoluteString,
            redirectURI: redirectURI,
            state: state
        )
    }

    func completeLogin(request: OpenAIOAuthCompleteRequest) async throws -> OpenAIOAuthCompleteResponse {
        let pending = try loadPendingSession()

        let callbackValues = extractCallbackValues(from: request.callbackURL)
        let code = request.code?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            ?? callbackValues.code
        let state = request.state?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            ?? callbackValues.state

        guard let code, !code.isEmpty else {
            throw Error.missingAuthorizationCode
        }
        guard let state, !state.isEmpty else {
            throw Error.invalidCallback
        }
        guard state == pending.state else {
            throw Error.stateMismatch
        }

        let stored = try await exchangeCode(
            code: code,
            codeVerifier: pending.codeVerifier,
            redirectURI: pending.redirectURI,
            existing: nil
        )
        try saveStoredAuth(stored)
        try? removePendingSession()

        let claims = Self.parseAuthClaims(from: stored.tokens.accessToken)
        return OpenAIOAuthCompleteResponse(
            ok: true,
            message: "OpenAI OAuth connected.",
            accountId: stored.tokens.accountId,
            planType: claims?.planType
        )
    }

    func currentAccessToken() -> String? {
        guard let stored = try? loadStoredAuth() else { return nil }
        let token = stored.tokens.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    func currentAccountId() -> String? {
        guard let stored = try? loadStoredAuth() else { return nil }
        if let accountId = stored.tokens.accountId, !accountId.isEmpty {
            return accountId
        }
        return Self.parseAuthClaims(from: stored.tokens.accessToken)?.accountId
    }

    func status() -> OpenAIOAuthStatus {
        guard let stored = try? loadStoredAuth() else {
            return OpenAIOAuthStatus(hasCredentials: false, accountId: nil, planType: nil, expiresAt: nil)
        }

        let claims = Self.parseAuthClaims(from: stored.tokens.accessToken)
        return OpenAIOAuthStatus(
            hasCredentials: true,
            accountId: stored.tokens.accountId ?? claims?.accountId,
            planType: claims?.planType,
            expiresAt: claims?.expiresAt.map(Self.iso8601String(from:))
        )
    }

    func fetchModels() async throws -> [ProviderModelOption] {
        let stored = try await validCredentials()
        let models = try await fetchModels(using: stored)
        return models
    }

    func probe() async -> ProviderProbeResponse {
        do {
            let models = try await fetchModels()
            guard !models.isEmpty else {
                return ProviderProbeResponse(
                    providerId: .openAIOAuth,
                    ok: false,
                    usedEnvironmentKey: false,
                    message: "OpenAI OAuth connected, but no Codex models were returned.",
                    models: []
                )
            }

            return ProviderProbeResponse(
                providerId: .openAIOAuth,
                ok: true,
                usedEnvironmentKey: false,
                message: "Connected to OpenAI OAuth. Loaded \(models.count) Codex models.",
                models: models
            )
        } catch {
            return ProviderProbeResponse(
                providerId: .openAIOAuth,
                ok: false,
                usedEnvironmentKey: false,
                message: "Failed to connect to OpenAI OAuth: \(error.localizedDescription)",
                models: []
            )
        }
    }

    func disconnect() throws {
        try? removePendingSession()
        let url = authFileURL()
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        Self.logger.info("openai_oauth.disconnected")
    }

    func ensureValidToken() async throws {
        _ = try await validCredentials()
    }

    func startDeviceCode() async throws -> OpenAIDeviceCodeStartResponse {
        var request = URLRequest(url: Self.deviceUserCodeEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONSerialization.data(withJSONObject: ["client_id": Self.clientID])
        request.httpBody = body

        let (data, response) = try await transport(request)

        if response.statusCode == 404 {
            throw Error.tokenExchangeFailed(
                "Device code login is not enabled. Enable it at https://chatgpt.com/security-settings."
            )
        }

        guard (200..<300).contains(response.statusCode) else {
            throw Error.tokenExchangeFailed(httpErrorMessage(data: data, statusCode: response.statusCode))
        }

        let decoded = try DeviceCodeAPIResponse.decode(from: data)
        let verificationURL = decoded.verificationUrl?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
            ? decoded.verificationUrl!
            : Self.defaultDeviceVerificationURL

        return OpenAIDeviceCodeStartResponse(
            deviceAuthId: decoded.deviceAuthId,
            userCode: decoded.userCode,
            verificationURL: verificationURL,
            interval: decoded.interval ?? 5,
            expiresIn: decoded.expiresIn ?? 600
        )
    }

    func pollDeviceToken(deviceAuthId: String, userCode: String) async throws -> OpenAIDeviceCodePollResponse {
        let pollResult = try await pollDeviceTokenRaw(deviceAuthId: deviceAuthId, userCode: userCode)

        switch pollResult {
        case .pending:
            return OpenAIDeviceCodePollResponse(
                status: "pending",
                ok: false,
                message: "Waiting for user authorization."
            )
        case .slowDown:
            return OpenAIDeviceCodePollResponse(
                status: "slow_down",
                ok: false,
                message: "Polling too fast. Slow down."
            )
        case let .approved(authorizationCode, codeVerifier):
            let stored = try await exchangeDeviceAuthorizationCode(
                authorizationCode: authorizationCode,
                codeVerifier: codeVerifier
            )
            try saveStoredAuth(stored)

            let claims = Self.parseAuthClaims(from: stored.tokens.accessToken)
            return OpenAIDeviceCodePollResponse(
                status: "approved",
                ok: true,
                message: "OpenAI OAuth connected via device code.",
                accountId: stored.tokens.accountId,
                planType: claims?.planType
            )
        }
    }

    private func pollDeviceTokenRaw(deviceAuthId: String, userCode: String) async throws -> DeviceTokenPollResult {
        var request = URLRequest(url: Self.deviceTokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONSerialization.data(withJSONObject: [
            "device_auth_id": deviceAuthId,
            "user_code": userCode
        ])
        request.httpBody = body

        let (data, response) = try await transport(request)

        if response.statusCode == 403 || response.statusCode == 404 {
            return .pending
        }

        if (200..<300).contains(response.statusCode) {
            let success = try JSONDecoder().decode(DeviceTokenSuccessResponse.self, from: data)
            return .approved(
                authorizationCode: success.authorizationCode,
                codeVerifier: success.codeVerifier
            )
        }

        if response.statusCode == 400 || response.statusCode == 429,
           let errorResponse = try? JSONDecoder().decode(DeviceTokenErrorResponse.self, from: data)
        {
            if errorResponse.error == "authorization_pending" {
                return .pending
            }
            if errorResponse.error == "slow_down" {
                return .slowDown
            }
            if let description = errorResponse.errorDescription {
                throw Error.tokenExchangeFailed(description)
            }
        }

        throw Error.tokenExchangeFailed(httpErrorMessage(data: data, statusCode: response.statusCode))
    }

    private func exchangeDeviceAuthorizationCode(
        authorizationCode: String,
        codeVerifier: String
    ) async throws -> StoredAuth {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncodedData([
            "grant_type": "authorization_code",
            "code": authorizationCode,
            "redirect_uri": Self.deviceRedirectURI,
            "client_id": Self.clientID,
            "code_verifier": codeVerifier
        ])

        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Error.tokenExchangeFailed(httpErrorMessage(data: data, statusCode: response.statusCode))
        }

        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard !token.accessToken.isEmpty else {
            throw Error.missingAccessToken
        }

        let claims = Self.parseAuthClaims(from: token.accessToken)
        let accountId = claims?.accountId

        return StoredAuth(
            authMode: "chatgpt",
            openAIAPIKey: nil,
            tokens: .init(
                idToken: token.idToken,
                accessToken: token.accessToken,
                refreshToken: token.refreshToken,
                accountId: accountId
            ),
            lastRefresh: Self.iso8601String(from: now())
        )
    }

    private func validCredentials() async throws -> StoredAuth {
        let stored = try loadStoredAuth()
        if Self.tokenNeedsRefresh(stored.tokens.accessToken, now: now()) {
            let refreshed = try await refresh(stored: stored)
            try saveStoredAuth(refreshed)
            return refreshed
        }
        return stored
    }

    private func fetchModels(using stored: StoredAuth) async throws -> [ProviderModelOption] {
        var request = URLRequest(url: Self.modelsEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(stored.tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId = stored.tokens.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Error.tokenExchangeFailed(httpErrorMessage(data: data, statusCode: response.statusCode))
        }
        let decoded = try decodeRemoteModels(from: data)
        if decoded.isEmpty {
            Self.logger.warning("openai_oauth.models.empty_response")
        } else {
            Self.logger.info(
                "openai_oauth.models.loaded",
                metadata: [
                    "count": .stringConvertible(decoded.count)
                ]
            )
        }
        return decoded.map { item in
            let capabilities = (item.supportedReasoningEfforts?.isEmpty == false) ? ["reasoning", "tools"] : ["tools"]
            return ProviderModelOption(
                id: item.id,
                title: item.displayName ?? item.id,
                contextWindow: nil,
                capabilities: capabilities
            )
        }.sorted { $0.id < $1.id }
    }

    private func decodeRemoteModels(from data: Data) throws -> [RemoteModelsResponse.Model] {
        if let decoded = try? JSONDecoder().decode(RemoteModelsResponse.self, from: data) {
            return decoded.data
        }

        guard let rawObject = try? JSONSerialization.jsonObject(with: data) else {
            throw Error.tokenExchangeFailed("OpenAI OAuth models payload is not valid JSON.")
        }

        let candidates: [Any]
        if let array = rawObject as? [Any] {
            candidates = array
        } else if let object = rawObject as? [String: Any] {
            if let dataArray = object["data"] as? [Any] {
                candidates = dataArray
            } else if let modelsArray = object["models"] as? [Any] {
                candidates = modelsArray
            } else if let itemsArray = object["items"] as? [Any] {
                candidates = itemsArray
            } else {
                throw Error.tokenExchangeFailed(
                    "OpenAI OAuth models response does not contain data/models/items array. payload=\(Self.sanitizedPayloadSnippet(data))"
                )
            }
        } else {
            throw Error.tokenExchangeFailed(
                "OpenAI OAuth models response has unexpected root type. payload=\(Self.sanitizedPayloadSnippet(data))"
            )
        }

        var models: [RemoteModelsResponse.Model] = []
        for candidate in candidates {
            guard let item = candidate as? [String: Any] else {
                continue
            }
            guard let id = (item["id"] as? String ?? item["slug"] as? String ?? item["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty
            else {
                continue
            }

            let displayName = (item["display_name"] as? String ?? item["displayName"] as? String ?? item["title"] as? String)
            let description = item["description"] as? String
            let reasoningEfforts = Self.parseReasoningEfforts(from: item)

            models.append(
                RemoteModelsResponse.Model(
                    id: id,
                    displayName: displayName,
                    description: description,
                    supportedReasoningEfforts: reasoningEfforts
                )
            )
        }

        if models.isEmpty {
            throw Error.tokenExchangeFailed(
                "OpenAI OAuth models response parsed but has no model entries. payload=\(Self.sanitizedPayloadSnippet(data))"
            )
        }
        return models
    }

    private func refresh(stored: StoredAuth) async throws -> StoredAuth {
        guard let refreshToken = stored.tokens.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines), !refreshToken.isEmpty else {
            return stored
        }

        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncodedData([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
            "scope": "openid profile email offline_access"
        ])

        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Error.tokenExchangeFailed(httpErrorMessage(data: data, statusCode: response.statusCode))
        }

        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard !token.accessToken.isEmpty else {
            throw Error.missingAccessToken
        }

        let claims = Self.parseAuthClaims(from: token.accessToken)
        let accountId = claims?.accountId ?? stored.tokens.accountId

        return StoredAuth(
            authMode: "chatgpt",
            openAIAPIKey: nil,
            tokens: .init(
                idToken: token.idToken ?? stored.tokens.idToken,
                accessToken: token.accessToken,
                refreshToken: token.refreshToken ?? stored.tokens.refreshToken,
                accountId: accountId
            ),
            lastRefresh: Self.iso8601String(from: now())
        )
    }

    private func exchangeCode(
        code: String,
        codeVerifier: String,
        redirectURI: String,
        existing: StoredAuth?
    ) async throws -> StoredAuth {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncodedData([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": Self.clientID,
            "code_verifier": codeVerifier
        ])

        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Error.tokenExchangeFailed(httpErrorMessage(data: data, statusCode: response.statusCode))
        }

        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard !token.accessToken.isEmpty else {
            throw Error.missingAccessToken
        }
        let claims = Self.parseAuthClaims(from: token.accessToken)
        let accountId = claims?.accountId ?? existing?.tokens.accountId
        guard accountId != nil else {
            throw Error.missingAccountID
        }

        return StoredAuth(
            authMode: "chatgpt",
            openAIAPIKey: nil,
            tokens: .init(
                idToken: token.idToken ?? existing?.tokens.idToken,
                accessToken: token.accessToken,
                refreshToken: token.refreshToken ?? existing?.tokens.refreshToken,
                accountId: accountId
            ),
            lastRefresh: Self.iso8601String(from: now())
        )
    }

    private func extractCallbackValues(from callbackURL: String?) -> (code: String?, state: String?) {
        guard let callbackURL = callbackURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !callbackURL.isEmpty,
              let components = URLComponents(string: callbackURL)
        else {
            return (nil, nil)
        }

        let items = components.queryItems ?? []
        return (
            items.first(where: { $0.name == "code" })?.value,
            items.first(where: { $0.name == "state" })?.value
        )
    }

    private func formEncodedData(_ values: [String: String]) -> Data {
        let body = values.map { key, value in
            "\(Self.percentEncode(key))=\(Self.percentEncode(value))"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private func httpErrorMessage(data: Data, statusCode: Int) -> String {
        if let body = String(data: data, encoding: .utf8), !body.isEmpty {
            return "status \(statusCode): \(body)"
        }
        return "status \(statusCode)"
    }

    private func savePendingSession(_ session: PendingSession) throws {
        try save(session, to: pendingSessionURL())
    }

    private func loadPendingSession() throws -> PendingSession {
        let url = pendingSessionURL()
        guard fileManager.fileExists(atPath: url.path) else {
            throw Error.missingPendingSession
        }
        return try load(PendingSession.self, from: url)
    }

    private func removePendingSession() throws {
        let url = pendingSessionURL()
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func saveStoredAuth(_ auth: StoredAuth) throws {
        try save(auth, to: authFileURL())
    }

    private func loadStoredAuth() throws -> StoredAuth {
        let url = authFileURL()
        guard fileManager.fileExists(atPath: url.path) else {
            throw Error.missingCredentials
        }
        return try load(StoredAuth.self, from: url)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }

    private func pendingSessionURL() -> URL {
        oauthDirectoryURL().appendingPathComponent("openai-oauth-pending.json")
    }

    private func authFileURL() -> URL {
        oauthDirectoryURL().appendingPathComponent("openai-oauth-auth.json")
    }

    private func oauthDirectoryURL() -> URL {
        workspaceRootURL.appendingPathComponent("auth", isDirectory: true)
    }

    private struct AuthClaims: Sendable {
        var accountId: String?
        var planType: String?
        var expiresAt: Date?
    }

    private static func parseAuthClaims(from jwt: String) -> AuthClaims? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else {
            return nil
        }

        let payloadPart = String(parts[1])
        guard let payloadData = base64URLDecode(payloadPart),
              let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            return nil
        }

        let auth = object["https://api.openai.com/auth"] as? [String: Any]
        let accountId = auth?["chatgpt_account_id"] as? String
        let planType = auth?["chatgpt_plan_type"] as? String
        let expiresAt: Date? = {
            guard let rawValue = object["exp"] as? NSNumber else {
                return nil
            }
            return Date(timeIntervalSince1970: rawValue.doubleValue)
        }()

        return AuthClaims(accountId: accountId, planType: planType, expiresAt: expiresAt)
    }

    private static func tokenNeedsRefresh(_ jwt: String, now: Date) -> Bool {
        guard let claims = parseAuthClaims(from: jwt), let expiresAt = claims.expiresAt else {
            return false
        }
        return expiresAt.timeIntervalSince(now) < 300
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max) }
        return base64URLEncode(Data(bytes))
    }

    private static func sha256Base64URL(_ value: String) -> String {
        let digest = SHA256Digest.hash(Data(value.utf8))
        return base64URLEncode(Data(digest))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while normalized.count % 4 != 0 {
            normalized.append("=")
        }
        return Data(base64Encoded: normalized)
    }

    private static func percentEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseReasoningEfforts(from object: [String: Any]) -> [RemoteModelsResponse.ReasoningEffort]? {
        if let efforts = object["supported_reasoning_efforts"] as? [String] {
            let mapped = efforts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { RemoteModelsResponse.ReasoningEffort(reasoningEffort: $0) }
            return mapped.isEmpty ? nil : mapped
        }
        if let effortObjects = object["supportedReasoningEfforts"] as? [[String: Any]] {
            let mapped = effortObjects.compactMap { effortObject in
                (effortObject["reasoning_effort"] as? String ?? effortObject["reasoningEffort"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .map { RemoteModelsResponse.ReasoningEffort(reasoningEffort: $0) }
            return mapped.isEmpty ? nil : mapped
        }
        return nil
    }

    private static func sanitizedPayloadSnippet(_ data: Data, limit: Int = 400) -> String {
        guard var text = String(data: data, encoding: .utf8) else {
            return "<non-utf8 payload>"
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if text.count > limit {
            return String(text.prefix(limit)) + "..."
        }
        return text
    }
}

private enum SHA256Digest {
    private static let initialHash: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    static func hash(_ data: Data) -> [UInt8] {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        message.append(contentsOf: withUnsafeBytes(of: bitLength.bigEndian, Array.init))

        var hash = initialHash
        var chunk = 0
        while chunk < message.count {
            let chunkBytes = Array(message[chunk..<(chunk + 64)])
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let offset = index * 4
                words[index] =
                    (UInt32(chunkBytes[offset]) << 24) |
                    (UInt32(chunkBytes[offset + 1]) << 16) |
                    (UInt32(chunkBytes[offset + 2]) << 8) |
                    UInt32(chunkBytes[offset + 3])
            }
            for index in 16..<64 {
                let s0 = rotateRight(words[index - 15], by: 7) ^ rotateRight(words[index - 15], by: 18) ^ (words[index - 15] >> 3)
                let s1 = rotateRight(words[index - 2], by: 17) ^ rotateRight(words[index - 2], by: 19) ^ (words[index - 2] >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }

            var a = hash[0]
            var b = hash[1]
            var c = hash[2]
            var d = hash[3]
            var e = hash[4]
            var f = hash[5]
            var g = hash[6]
            var h = hash[7]

            for index in 0..<64 {
                let s1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
                let choice = (e & f) ^ ((~e) & g)
                let temp1 = h &+ s1 &+ choice &+ k[index] &+ words[index]
                let s0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority

                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            hash[0] = hash[0] &+ a
            hash[1] = hash[1] &+ b
            hash[2] = hash[2] &+ c
            hash[3] = hash[3] &+ d
            hash[4] = hash[4] &+ e
            hash[5] = hash[5] &+ f
            hash[6] = hash[6] &+ g
            hash[7] = hash[7] &+ h
            chunk += 64
        }

        return hash.flatMap { word in
            [
                UInt8((word >> 24) & 0xff),
                UInt8((word >> 16) & 0xff),
                UInt8((word >> 8) & 0xff),
                UInt8(word & 0xff)
            ]
        }
    }

    private static func rotateRight(_ value: UInt32, by: UInt32) -> UInt32 {
        (value >> by) | (value << (32 - by))
    }
}
