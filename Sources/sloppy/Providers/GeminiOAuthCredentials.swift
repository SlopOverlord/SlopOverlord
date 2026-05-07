import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct GeminiOAuthCredentials: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let requiredGenerativeLanguageScope = "https://www.googleapis.com/auth/generative-language.retriever"

    static let defaultCredentialsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini", isDirectory: true)
        .appendingPathComponent("oauth_creds.json")

    private static let oauthClientID = "AWVUXkJFTBZjXFBLUFksAFwDFxwZQSEIHR4AQEtgBBIUUxU1XAwIB0cUAGBZBV4RCV4gSwQdChMvChEWBlwVXj0YCh4EV008CA"
    private static let oauthClientSecret = "ARQjLCMgIQNnECsVKCQuQlUKVH0dHDQJOUYzDBswCTs0Fgwv"
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    let accessToken: String
    let refreshToken: String?
    let tokenType: String
    let expiryDate: Date?
    let scope: String?
    let idToken: String?

    init(
        accessToken: String,
        refreshToken: String?,
        tokenType: String,
        expiryDate: Date?,
        scope: String? = nil,
        idToken: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiryDate = expiryDate
        self.scope = scope
        self.idToken = idToken
    }

    var authorizationHeaderValue: String {
        "\(tokenType.isEmpty ? "Bearer" : tokenType) \(accessToken)"
    }

    var hasAccessToken: Bool {
        !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasRefreshToken: Bool {
        !(refreshToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isUsableForGenerativeLanguageAPI: Bool {
        guard let scope, !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        let scopes = scope
            .split { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" }
            .map(String.init)
        return scopes.contains(Self.requiredGenerativeLanguageScope)
    }

    var generativeLanguageScopeDescription: String {
        scope?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? scope!
            : "unknown"
    }

    static func load(url: URL = defaultCredentialsURL) -> GeminiOAuthCredentials? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(GeminiOAuthCredentials.self, from: data)
    }

    func refreshedIfNeeded(
        url: URL = defaultCredentialsURL,
        now: Date = Date(),
        leeway: TimeInterval = 120,
        transport: Transport? = nil
    ) async throws -> GeminiOAuthCredentials {
        if hasAccessToken, let expiryDate, expiryDate.timeIntervalSince(now) > leeway {
            return self
        }
        if hasAccessToken, expiryDate == nil {
            return self
        }

        let refreshToken = (refreshToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refreshToken.isEmpty else {
            if hasAccessToken {
                return self
            }
            throw GeminiOAuthCredentialsError.missingAccessAndRefreshToken
        }

        let refreshed = try await refreshAccessToken(refreshToken: refreshToken, transport: transport)
        let nextRefreshToken = refreshed.refreshToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let next = GeminiOAuthCredentials(
            accessToken: refreshed.accessToken,
            refreshToken: nextRefreshToken?.isEmpty == false ? nextRefreshToken : refreshToken,
            tokenType: refreshed.tokenType?.isEmpty == false ? refreshed.tokenType! : tokenType,
            expiryDate: refreshed.expiresIn.map { now.addingTimeInterval($0) },
            scope: refreshed.scope ?? scope,
            idToken: refreshed.idToken ?? idToken
        )
        try next.save(url: url)
        return next
    }

    private func refreshAccessToken(refreshToken: String, transport: Transport?) async throws -> RefreshTokenResponse {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formURLEncodedBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": try _secretDecode(Self.oauthClientID),
            "client_secret": try _secretDecode(Self.oauthClientSecret),
        ])

        let resolvedTransport = transport ?? Self.defaultTransport
        let (data, response) = try await resolvedTransport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw GeminiOAuthCredentialsError.refreshFailed(
                statusCode: response.statusCode,
                body: Self.sanitizedPayloadSnippet(data)
            )
        }

        return try JSONDecoder().decode(RefreshTokenResponse.self, from: data)
    }

    private func save(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(StoredCredentials(credentials: self))
        try data.write(to: url, options: [.atomic])
    }

    private static func defaultTransport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await SloppyURLSessionFactory.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, httpResponse)
    }

    private static func formURLEncodedBody(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private static func sanitizedPayloadSnippet(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let text = String(decoding: data.prefix(512), as: UTF8.self)
        return text.replacingOccurrences(
            of: #"(?i)(access_token|refresh_token|id_token|client_secret)"\s*:\s*"[^"]*""#,
            with: #"$1":"[REDACTED]""#,
            options: .regularExpression
        )
    }

    private struct RefreshTokenResponse: Decodable {
        let accessToken: String
        let expiresIn: TimeInterval?
        let tokenType: String?
        let refreshToken: String?
        let scope: String?
        let idToken: String?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case tokenType = "token_type"
            case refreshToken = "refresh_token"
            case scope
            case idToken = "id_token"
        }
    }

    private struct StoredCredentials: Encodable {
        let accessToken: String
        let refreshToken: String?
        let tokenType: String
        let expiryDate: Int64?
        let scope: String?
        let idToken: String?

        init(credentials: GeminiOAuthCredentials) {
            accessToken = credentials.accessToken
            refreshToken = credentials.refreshToken
            tokenType = credentials.tokenType.isEmpty ? "Bearer" : credentials.tokenType
            expiryDate = credentials.expiryDate.map { Int64($0.timeIntervalSince1970 * 1000) }
            scope = credentials.scope
            idToken = credentials.idToken
        }

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case tokenType = "token_type"
            case expiryDate = "expiry_date"
            case scope
            case idToken = "id_token"
        }
    }
}

extension GeminiOAuthCredentials: Decodable {
    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiryDate = "expiry_date"
        case scope
        case idToken = "id_token"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(accessToken ?? "").isEmpty || !(refreshToken ?? "").isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .accessToken,
                in: container,
                debugDescription: "Gemini OAuth credentials do not contain an access token or refresh token."
            )
        }

        self.accessToken = accessToken ?? ""
        self.refreshToken = refreshToken
        self.tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Bearer"
        self.scope = try container.decodeIfPresent(String.self, forKey: .scope)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.idToken = try container.decodeIfPresent(String.self, forKey: .idToken)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let value = try? container.decode(Double.self, forKey: .expiryDate) {
            let seconds = value > 10_000_000_000 ? value / 1000 : value
            self.expiryDate = Date(timeIntervalSince1970: seconds)
        } else {
            self.expiryDate = nil
        }
    }
}

enum GeminiOAuthCredentialsError: Error, LocalizedError {
    case missingAccessAndRefreshToken
    case missingRequiredScope(currentScopes: String)
    case refreshFailed(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingAccessAndRefreshToken:
            return "Gemini CLI OAuth credentials do not contain an access token or refresh token. Run `gemini auth login` again."
        case .missingRequiredScope(let currentScopes):
            return "Gemini CLI OAuth credentials are missing the required scope \(GeminiOAuthCredentials.requiredGenerativeLanguageScope). Current scopes: \(currentScopes). Provide a Gemini API key or re-authenticate OAuth with the Gemini API scope."
        case .refreshFailed(let statusCode, let body):
            if body.isEmpty {
                return "Gemini CLI OAuth token refresh failed with HTTP \(statusCode)."
            }
            return "Gemini CLI OAuth token refresh failed with HTTP \(statusCode): \(body)"
        }
    }
}

enum GeminiAuthCredential: Sendable {
    case oauth(GeminiOAuthCredentials)
    case apiKey(String)
}
