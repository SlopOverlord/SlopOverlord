import Foundation

/// Bridges inbound Telegram messages to the SlopOverlord Core channel API.
actor CoreBridge {
    private let baseURL: String
    private let authToken: String
    private let session: URLSession

    init(baseURL: String, authToken: String) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.authToken = authToken
        self.session = URLSession(configuration: .default)
    }

    struct ChannelMessagePayload: Encodable {
        let userId: String
        let content: String
    }

    /// Posts a message to Core's channel endpoint. Returns true on 2xx.
    func postChannelMessage(channelId: String, userId: String, content: String) async -> Bool {
        let urlString = "\(baseURL)/v1/channels/\(channelId)/messages"
        guard let url = URL(string: urlString) else { return false }

        let body = ChannelMessagePayload(userId: userId, content: content)
        guard let bodyData = try? JSONEncoder().encode(body) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData
        request.timeoutInterval = 30

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200..<300).contains(http.statusCode)
            }
            return false
        } catch {
            return false
        }
    }
}
