import Foundation

/// Minimal Telegram Bot API client using URLSession.
actor TelegramBotAPI {
    private let botToken: String
    private let baseURL: URL
    private let session: URLSession

    init(botToken: String) {
        self.botToken = botToken
        self.baseURL = URL(string: "https://api.telegram.org/bot\(botToken)/")!
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 65
        self.session = URLSession(configuration: config)
    }

    // MARK: - getUpdates (long-polling)

    struct GetUpdatesResponse: Decodable {
        let ok: Bool
        let result: [Update]?
    }

    struct Update: Decodable {
        let updateId: Int64
        let message: Message?

        enum CodingKeys: String, CodingKey {
            case updateId = "update_id"
            case message
        }
    }

    struct Message: Decodable {
        let messageId: Int64
        let from: User?
        let chat: Chat
        let text: String?
        let date: Int

        enum CodingKeys: String, CodingKey {
            case messageId = "message_id"
            case from, chat, text, date
        }
    }

    struct User: Decodable {
        let id: Int64
        let firstName: String
        let lastName: String?
        let username: String?

        enum CodingKeys: String, CodingKey {
            case id
            case firstName = "first_name"
            case lastName = "last_name"
            case username
        }

        var displayName: String {
            if let username { return "@\(username)" }
            if let lastName { return "\(firstName) \(lastName)" }
            return firstName
        }
    }

    struct Chat: Decodable {
        let id: Int64
        let type: String
        let title: String?
    }

    func getUpdates(offset: Int64?, timeout: Int = 60) async throws -> [Update] {
        var params: [String: Any] = ["timeout": timeout]
        if let offset { params["offset"] = offset }
        let data = try await post(method: "getUpdates", params: params)
        let decoded = try JSONDecoder().decode(GetUpdatesResponse.self, from: data)
        return decoded.result ?? []
    }

    // MARK: - sendMessage

    struct SendMessageResponse: Decodable {
        let ok: Bool
    }

    func sendMessage(chatId: Int64, text: String, parseMode: String? = nil) async throws {
        var params: [String: Any] = [
            "chat_id": chatId,
            "text": text
        ]
        if let parseMode { params["parse_mode"] = parseMode }
        _ = try await post(method: "sendMessage", params: params)
    }

    // MARK: - HTTP transport

    private func post(method: String, params: [String: Any]) async throws -> Data {
        let url = baseURL.appendingPathComponent(method)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: params)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TelegramAPIError.httpError(statusCode: http.statusCode, body: body)
        }
        return data
    }
}

enum TelegramAPIError: Error {
    case httpError(statusCode: Int, body: String)
}
