import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Protocols

/// Service for fetching skills from skills.sh registry
actor SkillsRegistryService {
    enum ServiceError: Error {
        case invalidURL
        case networkError(Error)
        case decodeError(Error)
        case invalidResponse
        case rateLimited
    }

    private let baseURL: String
    private let urlSession: URLSession
    private let decoder: JSONDecoder

    init(baseURL: String = "https://skills.sh", urlSession: URLSession = URLSession.shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: - Public API

    /// Fetch all skills from the registry
    func fetchSkills(
        search: String? = nil,
        sort: SortOption = .installs,
        limit: Int = 50,
        offset: Int = 0
    ) async throws -> SkillsRegistryResponse {
        let endpointPaths = ["/api/skills", "/api/v1/skills"]
        var lastError: Error?

        for endpointPath in endpointPaths {
            guard var components = URLComponents(string: "\(baseURL)\(endpointPath)") else {
                continue
            }

            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "per_page", value: String(limit)),
                URLQueryItem(name: "page", value: String((max(0, offset) / max(1, limit)) + 1))
            ]

            if let search = search, !search.isEmpty {
                queryItems.append(URLQueryItem(name: "search", value: search))
                queryItems.append(URLQueryItem(name: "q", value: search))
            }

            switch sort {
            case .installs:
                queryItems.append(URLQueryItem(name: "sort", value: "installs"))
            case .trending:
                queryItems.append(URLQueryItem(name: "sort", value: "trending"))
            case .recent:
                queryItems.append(URLQueryItem(name: "sort", value: "recent"))
            }

            components.queryItems = queryItems
            guard let url = components.url else {
                continue
            }

            do {
                return try await fetchSkills(from: url)
            } catch {
                lastError = error
                continue
            }
        }

        do {
            return try await fetchSkillsFromHTML(search: search, sort: sort, limit: limit, offset: offset)
        } catch {
            lastError = error
        }

        if let lastError {
            throw lastError
        }
        throw ServiceError.invalidURL
    }

    /// Fetch trending skills
    func fetchTrendingSkills(limit: Int = 20) async throws -> SkillsRegistryResponse {
        return try await fetchSkills(sort: .trending, limit: limit)
    }

    /// Fetch skills by owner
    func fetchSkillsByOwner(_ owner: String, limit: Int = 50) async throws -> SkillsRegistryResponse {
        let urlString = "\(baseURL)/api/skills?owner=\(owner.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? owner)&limit=\(limit)"

        guard let url = URL(string: urlString) else {
            throw ServiceError.invalidURL
        }

        return try await fetchSkills(from: url)
    }

    /// Get a specific skill by ID
    func fetchSkill(id: String) async throws -> SkillInfo? {
        let urlString = "\(baseURL)/api/skills/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)"

        guard let url = URL(string: urlString) else {
            throw ServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ServiceError.invalidResponse
            }

            if httpResponse.statusCode == 404 {
                return nil
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 429 {
                    throw ServiceError.rateLimited
                }
                throw ServiceError.invalidResponse
            }

            return try decoder.decode(SkillInfo.self, from: data)
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.networkError(error)
        }
    }

    // MARK: - Private Helpers

    private func fetchSkills(from url: URL) async throws -> SkillsRegistryResponse {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SlopOverlord/1.0 (+https://github.com/vprusakov/SlopOverlord)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ServiceError.invalidResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 429 {
                    throw ServiceError.rateLimited
                }
                throw ServiceError.invalidResponse
            }

            if let decoded = Self.decodeSkillsResponse(from: data, decoder: decoder) {
                return decoded
            }
            throw ServiceError.decodeError(ServiceError.invalidResponse)
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.networkError(error)
        }
    }

    private func fetchSkillsFromHTML(
        search: String?,
        sort: SortOption,
        limit: Int,
        offset: Int
    ) async throws -> SkillsRegistryResponse {
        let candidatePaths = htmlCandidatePaths(for: sort)
        var lastError: Error?

        for path in candidatePaths {
            guard let url = URL(string: "\(baseURL)\(path)") else {
                continue
            }

            var request = URLRequest(url: url)
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            request.setValue("SlopOverlord/1.0 (+https://github.com/vprusakov/SlopOverlord)", forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await urlSession.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw ServiceError.invalidResponse
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    throw ServiceError.invalidResponse
                }
                guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
                    throw ServiceError.decodeError(ServiceError.invalidResponse)
                }

                let parsedSkills = Self.parseSkillsFromHTML(html)
                guard !parsedSkills.isEmpty else {
                    throw ServiceError.decodeError(ServiceError.invalidResponse)
                }

                let filtered = Self.filterSkills(parsedSkills, search: search)
                let sorted = Self.sortSkills(filtered, by: sort)
                let page = Array(sorted.dropFirst(max(0, offset)).prefix(max(1, limit)))
                return SkillsRegistryResponse(skills: page, total: filtered.count)
            } catch {
                lastError = error
                continue
            }
        }

        if let lastError {
            throw lastError
        }
        throw ServiceError.invalidResponse
    }

    private nonisolated func htmlCandidatePaths(for sort: SortOption) -> [String] {
        switch sort {
        case .installs:
            return [
                "/",
                "/?tab=all-time",
                "/?sort=installs"
            ]
        case .trending:
            return [
                "/?tab=trending",
                "/?sort=trending",
                "/trending",
                "/"
            ]
        case .recent:
            return [
                "/?tab=recent",
                "/?sort=recent",
                "/recent",
                "/"
            ]
        }
    }

    nonisolated static func parseSkillsFromHTML(_ html: String) -> [SkillInfo] {
        var parsedSkills: [SkillInfo] = []
        var seenIDs = Set<String>()

        // First, try to extract skills from embedded Next.js JSON state.
        if let nextDataJSON = extractNextDataJSON(from: html),
           let data = nextDataJSON.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            for skill in collectSkills(from: json) {
                if seenIDs.insert(skill.id).inserted {
                    parsedSkills.append(skill)
                }
            }
        }

        // Fallback parser from href slugs: /owner/repo/skill-name
        let pattern = #"href="/([^"/?#]+)/([^"/?#]+)/([^"/?#]+)""#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(location: 0, length: html.utf16.count)
            let matches = regex.matches(in: html, range: range)

            for match in matches {
                guard match.numberOfRanges == 4 else {
                    continue
                }

                let owner = substring(html, range: match.range(at: 1))
                let repo = substring(html, range: match.range(at: 2))
                let name = substring(html, range: match.range(at: 3))

                guard let owner, let repo, let name else {
                    continue
                }
                if owner.hasPrefix("_") || repo.hasPrefix("_") || name.hasPrefix("_") {
                    continue
                }
                if owner.isEmpty || repo.isEmpty || name.isEmpty {
                    continue
                }
                if repo == "favicon.ico" || name.hasSuffix(".js") || name.hasSuffix(".css") {
                    continue
                }

                let decodedOwner = owner.removingPercentEncoding ?? owner
                let decodedRepo = repo.removingPercentEncoding ?? repo
                let decodedName = name.removingPercentEncoding ?? name
                let id = "\(decodedOwner)/\(decodedName)"

                guard seenIDs.insert(id).inserted else {
                    continue
                }

                parsedSkills.append(
                    SkillInfo(
                        id: id,
                        owner: decodedOwner,
                        repo: decodedRepo,
                        name: decodedName,
                        description: nil,
                        installs: 0,
                        githubUrl: "https://github.com/\(decodedOwner)/\(decodedRepo)"
                    )
                )
            }
        }

        return parsedSkills
    }

    nonisolated private static func sortSkills(_ skills: [SkillInfo], by sort: SortOption) -> [SkillInfo] {
        switch sort {
        case .installs, .trending:
            return skills.sorted { lhs, rhs in
                if lhs.installs == rhs.installs {
                    return lhs.id < rhs.id
                }
                return lhs.installs > rhs.installs
            }
        case .recent:
            return skills
        }
    }

    nonisolated private static func filterSkills(_ skills: [SkillInfo], search: String?) -> [SkillInfo] {
        guard let search, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return skills
        }

        return skills.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
            $0.owner.localizedCaseInsensitiveContains(search) ||
            $0.repo.localizedCaseInsensitiveContains(search) ||
            $0.id.localizedCaseInsensitiveContains(search) ||
            ($0.description?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    nonisolated static func decodeSkillsResponse(from data: Data, decoder: JSONDecoder = JSONDecoder()) -> SkillsRegistryResponse? {
        if let skillsResponse = try? decoder.decode(SkillsRegistryResponse.self, from: data) {
            return skillsResponse
        }

        if let skills = try? decoder.decode([SkillInfo].self, from: data) {
            return SkillsRegistryResponse(skills: skills, total: skills.count)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        if let object = json as? [String: Any] {
            return decodeSkillsResponse(from: object, decoder: decoder)
        }

        if let array = json as? [[String: Any]] {
            let parsedSkills = array.compactMap { decodeSkillInfo(from: $0, decoder: decoder) }
            guard !parsedSkills.isEmpty else {
                return nil
            }
            return SkillsRegistryResponse(skills: parsedSkills, total: parsedSkills.count)
        }

        return nil
    }

    nonisolated private static func decodeSkillsResponse(
        from object: [String: Any],
        decoder: JSONDecoder
    ) -> SkillsRegistryResponse? {
        let candidateArrays: [[String: Any]]
        if let skills = object["skills"] as? [[String: Any]] {
            candidateArrays = skills
        } else if let items = object["items"] as? [[String: Any]] {
            candidateArrays = items
        } else if let results = object["results"] as? [[String: Any]] {
            candidateArrays = results
        } else if let data = object["data"] as? [[String: Any]] {
            candidateArrays = data
        } else {
            candidateArrays = []
        }

        guard !candidateArrays.isEmpty else {
            return nil
        }

        let parsedSkills = candidateArrays.compactMap { decodeSkillInfo(from: $0, decoder: decoder) }
        guard !parsedSkills.isEmpty else {
            return nil
        }

        let total = extractTotal(from: object) ?? parsedSkills.count
        return SkillsRegistryResponse(skills: parsedSkills, total: total)
    }

    nonisolated private static func decodeSkillInfo(from object: [String: Any], decoder: JSONDecoder) -> SkillInfo? {
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object),
           let decoded = try? decoder.decode(SkillInfo.self, from: data) {
            return decoded
        }

        let owner = extractString(from: object, keys: [["owner"], ["author"], ["organization"]]) ??
            extractString(from: object, keys: [["owner", "login"], ["owner", "name"]])
        let repo = extractString(from: object, keys: [["repo"], ["repository"], ["repoName"]])
        let id = extractString(from: object, keys: [["id"], ["slug"]])
        let name = extractString(from: object, keys: [["name"], ["skillName"], ["title"]])

        let githubURL = extractString(
            from: object,
            keys: [["githubUrl"], ["github_url"], ["github"], ["repositoryUrl"], ["repository_url"], ["html_url"], ["url"]]
        )
        let description = extractString(from: object, keys: [["description"], ["summary"]])
        let installs = extractInt(from: object, keys: [["installs"], ["downloadCount"], ["download_count"], ["downloads"]]) ?? 0

        let resolvedOwner = owner ?? id?.split(separator: "/").first.map(String.init) ?? ""
        let resolvedRepo = repo ?? {
            if let id {
                let components = id.split(separator: "/").map(String.init)
                if components.count >= 2 {
                    return components[1]
                }
            }
            return ""
        }()
        let resolvedName = name ?? {
            if let id {
                return id.split(separator: "/").last.map(String.init) ?? ""
            }
            return ""
        }()
        let resolvedID = id ?? {
            if !resolvedOwner.isEmpty && !resolvedName.isEmpty {
                return "\(resolvedOwner)/\(resolvedName)"
            }
            return ""
        }()
        let resolvedGitHubURL = githubURL ?? {
            guard !resolvedOwner.isEmpty, !resolvedRepo.isEmpty else {
                return ""
            }
            return "https://github.com/\(resolvedOwner)/\(resolvedRepo)"
        }()

        guard !resolvedID.isEmpty, !resolvedOwner.isEmpty, !resolvedRepo.isEmpty, !resolvedName.isEmpty, !resolvedGitHubURL.isEmpty else {
            return nil
        }

        return SkillInfo(
            id: resolvedID,
            owner: resolvedOwner,
            repo: resolvedRepo,
            name: resolvedName,
            description: description,
            installs: installs,
            githubUrl: resolvedGitHubURL
        )
    }

    nonisolated private static func extractTotal(from object: [String: Any]) -> Int? {
        extractInt(from: object, keys: [["total"], ["totalCount"], ["count"], ["meta", "total"], ["meta", "count"]])
    }

    nonisolated private static func extractString(from object: [String: Any], keys: [[String]]) -> String? {
        for keyPath in keys {
            if let value = value(in: object, keyPath: keyPath) {
                if let string = value as? String {
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            }
        }
        return nil
    }

    nonisolated private static func extractInt(from object: [String: Any], keys: [[String]]) -> Int? {
        for keyPath in keys {
            guard let value = value(in: object, keyPath: keyPath) else {
                continue
            }
            if let intValue = value as? Int {
                return intValue
            }
            if let stringValue = value as? String, let intValue = Int(stringValue) {
                return intValue
            }
            if let doubleValue = value as? Double {
                return Int(doubleValue)
            }
            if let number = value as? NSNumber {
                return number.intValue
            }
        }
        return nil
    }

    nonisolated private static func value(in object: [String: Any], keyPath: [String]) -> Any? {
        var current: Any = object
        for key in keyPath {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[key]
            else {
                return nil
            }
            current = next
        }
        return current
    }

    nonisolated private static func extractNextDataJSON(from html: String) -> String? {
        let pattern = #"<script[^>]*id=["']__NEXT_DATA__["'][^>]*>([\s\S]*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(location: 0, length: html.utf16.count)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges > 1
        else {
            return nil
        }
        return substring(html, range: match.range(at: 1))
    }

    nonisolated private static func collectSkills(from value: Any) -> [SkillInfo] {
        var results: [SkillInfo] = []

        if let object = value as? [String: Any] {
            if let skill = decodeSkillInfo(from: object, decoder: JSONDecoder()) {
                results.append(skill)
            }
            for nested in object.values {
                results.append(contentsOf: collectSkills(from: nested))
            }
        } else if let array = value as? [Any] {
            for nested in array {
                results.append(contentsOf: collectSkills(from: nested))
            }
        }

        return results
    }

    nonisolated private static func substring(_ source: String, range: NSRange) -> String? {
        guard let stringRange = Range(range, in: source) else {
            return nil
        }
        return String(source[stringRange])
    }
}

// MARK: - Sort Options

extension SkillsRegistryService {
    enum SortOption {
        case installs
        case trending
        case recent
    }
}

// MARK: - Mock/Fallback Data

extension SkillsRegistryService {
    /// Returns mock skills data for development/testing when skills.sh is unavailable
    static var mockSkills: [SkillInfo] {
        [
            SkillInfo(
                id: "vercel-labs/find-skills",
                owner: "vercel-labs",
                repo: "skills",
                name: "find-skills",
                description: "This skill helps you discover and install skills from the open agent skills ecosystem.",
                installs: 365600,
                githubUrl: "https://github.com/vercel-labs/skills"
            ),
            SkillInfo(
                id: "vercel-labs/vercel-react-best-practices",
                owner: "vercel-labs",
                repo: "agent-skills",
                name: "vercel-react-best-practices",
                description: "Best practices for building React applications on Vercel.",
                installs: 180100,
                githubUrl: "https://github.com/vercel-labs/agent-skills"
            ),
            SkillInfo(
                id: "vercel-labs/web-design-guidelines",
                owner: "vercel-labs",
                repo: "agent-skills",
                name: "web-design-guidelines",
                description: "Review files for compliance with Web Interface Guidelines.",
                installs: 138600,
                githubUrl: "https://github.com/vercel-labs/agent-skills"
            ),
            SkillInfo(
                id: "remotion-dev/remotion-best-practices",
                owner: "remotion-dev",
                repo: "skills",
                name: "remotion-best-practices",
                description: "Best practices for Remotion video development.",
                installs: 119100,
                githubUrl: "https://github.com/remotion-dev/skills"
            ),
            SkillInfo(
                id: "anthropics/frontend-design",
                owner: "anthropics",
                repo: "skills",
                name: "frontend-design",
                description: "This skill guides creation of distinctive, production-grade frontend interfaces that avoid generic 'AI slop' aesthetics.",
                installs: 111900,
                githubUrl: "https://github.com/anthropics/skills"
            ),
            SkillInfo(
                id: "microsoft/github-copilot-for-azure/azure-ai",
                owner: "microsoft",
                repo: "github-copilot-for-azure",
                name: "azure-ai",
                description: "Azure AI services integration and best practices.",
                installs: 92600,
                githubUrl: "https://github.com/microsoft/github-copilot-for-azure"
            ),
            SkillInfo(
                id: "microsoft/github-copilot-for-azure/azure-observability",
                owner: "microsoft",
                repo: "github-copilot-for-azure",
                name: "azure-observability",
                description: "Monitor and observe Azure resources effectively.",
                installs: 92500,
                githubUrl: "https://github.com/microsoft/github-copilot-for-azure"
            ),
            SkillInfo(
                id: "microsoft/github-copilot-for-azure/azure-cost-optimization",
                owner: "microsoft",
                repo: "github-copilot-for-azure",
                name: "azure-cost-optimization",
                description: "Optimize and reduce Azure costs.",
                installs: 92500,
                githubUrl: "https://github.com/microsoft/github-copilot-for-azure"
            )
        ]
    }

    /// Returns mock registry response for testing
    nonisolated func fetchMockSkills(search: String? = nil, limit: Int = 20, offset: Int = 0) -> SkillsRegistryResponse {
        let allSkills = Self.mockSkills

        let filtered: [SkillInfo]
        if let search = search, !search.isEmpty {
            filtered = allSkills.filter {
                $0.name.localizedCaseInsensitiveContains(search) ||
                $0.description?.localizedCaseInsensitiveContains(search) ?? false ||
                $0.owner.localizedCaseInsensitiveContains(search)
            }
        } else {
            filtered = allSkills
        }

        let page = Array(filtered.dropFirst(max(0, offset)).prefix(max(1, limit)))
        return SkillsRegistryResponse(skills: page, total: filtered.count)
    }
}
