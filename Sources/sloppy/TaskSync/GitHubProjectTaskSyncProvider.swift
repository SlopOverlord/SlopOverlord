import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PluginSDK
import Protocols

struct GitHubProjectReference: Sendable, Equatable {
    var ownerKind: String
    var owner: String
    var repository: String? = nil
    var number: Int
}

struct GitHubRepositoryReference: Sendable, Equatable {
    var owner: String
    var repo: String

    var slug: String { "\(owner)/\(repo)" }
}

struct GitHubProjectTaskSyncProvider: TaskSyncProvider {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    let id = "github"
    private let transport: Transport

    init(transport: Transport? = nil) {
        self.transport = transport ?? { request in
            let (data, response) = try await SloppyURLSessionFactory.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return (data, http)
        }
    }

    enum ProviderError: LocalizedError {
        case invalidProjectURL
        case invalidRepository
        case missingToken
        case githubHTTP(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidProjectURL:
                return "Invalid GitHub Project URL."
            case .invalidRepository:
                return "Invalid GitHub default repository. Use owner/repo."
            case .missingToken:
                return "GitHub token missing."
            case .githubHTTP(let status, let body):
                return "GitHub API failed with HTTP \(status): \(body)"
            }
        }
    }

    func parseProjectURL(_ rawURL: String) throws -> TaskSyncProjectDescriptor {
        let ref = try Self.parseProjectReference(rawURL)
        return TaskSyncProjectDescriptor(
            providerId: id,
            projectURL: normalizedProjectURL(ref),
            statusOptions: ["Todo", "In Progress", "Done"]
        )
    }

    func resolveProject(url: String, token: String?, defaultRepo: String?) async throws -> TaskSyncProjectDescriptor {
        let ref = try Self.parseProjectReference(url)
        let descriptor = TaskSyncProjectDescriptor(
            providerId: id,
            projectURL: normalizedProjectURL(ref),
            projectNodeId: token == nil ? nil : try await fetchProjectNodeId(ref: ref, token: token),
            defaultRepo: try defaultRepo.map { try Self.parseRepository($0).slug },
            statusOptions: ["Todo", "In Progress", "Done"]
        )
        return descriptor
    }

    func importTasks(settings: ProjectTaskSyncSettings, token: String?) async throws -> [TaskSyncExternalTask] {
        guard token != nil else { throw ProviderError.missingToken }
        // v1 scaffold keeps import side-effect free until Project item pagination is wired.
        return []
    }

    func createOrUpdateTask(_ task: ProjectTask, settings: ProjectTaskSyncSettings, token: String?) async throws -> TaskExternalMetadata {
        guard let token else { throw ProviderError.missingToken }
        guard let repoSlug = settings.defaultRepo else { throw ProviderError.invalidRepository }
        let repo = try Self.parseRepository(repoSlug)
        if task.externalMetadata?.externalIssueId != nil {
            return try await updateIssue(task: task, repo: repo, token: token)
        }
        return try await createIssue(task: task, settings: settings, repo: repo, token: token)
    }

    func mirrorComment(
        _ comment: TaskComment,
        task: ProjectTask,
        settings: ProjectTaskSyncSettings,
        token: String?
    ) async throws -> TaskExternalMetadata {
        guard let token else { throw ProviderError.missingToken }
        guard let repoSlug = settings.defaultRepo else { throw ProviderError.invalidRepository }
        guard let number = task.externalMetadata?.externalIssueNumber else {
            return comment.externalMetadata ?? TaskExternalMetadata(providerId: id, origin: "sloppy", syncState: "pending")
        }
        let repo = try Self.parseRepository(repoSlug)
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo.owner)/\(repo.repo)/issues/\(number)/comments")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["body": comment.content])
        addHeaders(&request, token: token)
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderError.githubHTTP(response.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return TaskExternalMetadata(
            providerId: id,
            externalProjectId: settings.projectNodeId,
            externalIssueId: task.externalMetadata?.externalIssueId,
            externalIssueNumber: number,
            externalIssueURL: task.externalMetadata?.externalIssueURL,
            externalCommentId: (object?["id"] as? NSNumber)?.stringValue,
            origin: "sloppy",
            syncState: "synced",
            lastSyncedAt: Date()
        )
    }

    static func parseProjectReference(_ rawURL: String) throws -> GitHubProjectReference {
        guard let components = URLComponents(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.host?.lowercased() == "github.com"
        else {
            throw ProviderError.invalidProjectURL
        }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count == 4,
              parts[2] == "projects",
              let number = Int(parts[3])
        else {
            throw ProviderError.invalidProjectURL
        }
        if parts[0] == "orgs" || parts[0] == "users" {
            return GitHubProjectReference(ownerKind: parts[0], owner: parts[1], number: number)
        }
        guard !parts[0].isEmpty, !parts[1].isEmpty else {
            throw ProviderError.invalidProjectURL
        }
        return GitHubProjectReference(ownerKind: "repos", owner: parts[0], repository: parts[1], number: number)
    }

    static func parseRepository(_ raw: String) throws -> GitHubRepositoryReference {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/").map(String.init)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty
        else {
            throw ProviderError.invalidRepository
        }
        let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        return GitHubRepositoryReference(owner: parts[0], repo: repo)
    }

    static func mappedGitHubStatus(sloppyStatus: String, mappings: [String: String]) -> String {
        let raw = sloppyStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let configured = mappings[raw], !configured.isEmpty {
            return configured
        }
        switch ProjectTaskStatus(rawValue: raw) {
        case .pendingApproval, .backlog, .ready:
            return "Todo"
        case .inProgress, .waitingInput, .blocked, .needsReview:
            return "In Progress"
        case .done, .cancelled:
            return "Done"
        case nil:
            return "Todo"
        }
    }

    private func fetchProjectNodeId(ref: GitHubProjectReference, token: String?) async throws -> String? {
        guard let token else { throw ProviderError.missingToken }
        let query: String
        let variables: [String: Any]
        if ref.ownerKind == "repos", let repository = ref.repository {
            query = "query($owner:String!,$name:String!,$number:Int!){ repository(owner:$owner,name:$name){ projectV2(number:$number){ id } } }"
            variables = ["owner": ref.owner, "name": repository, "number": ref.number]
        } else {
            let ownerField = ref.ownerKind == "orgs" ? "organization" : "user"
            query = "query($login:String!,$number:Int!){ \(ownerField)(login:$login){ projectV2(number:$number){ id } } }"
            variables = ["login": ref.owner, "number": ref.number]
        }
        let body: [String: Any] = ["query": query, "variables": variables]
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        addHeaders(&request, token: token)
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderError.githubHTTP(response.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = object["data"] as? [String: Any]
        else {
            return nil
        }
        let containerKey = ref.ownerKind == "repos"
            ? "repository"
            : (ref.ownerKind == "orgs" ? "organization" : "user")
        guard let ownerObj = dataObj[containerKey] as? [String: Any],
              let projectObj = ownerObj["projectV2"] as? [String: Any]
        else {
            return nil
        }
        return projectObj["id"] as? String
    }

    private func createIssue(
        task: ProjectTask,
        settings: ProjectTaskSyncSettings,
        repo: GitHubRepositoryReference,
        token: String
    ) async throws -> TaskExternalMetadata {
        let labels = Array(Set((task.tags + ["github", "sloppy:\(settings.projectNodeId ?? "project")"]).filter { !$0.isEmpty }))
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo.owner)/\(repo.repo)/issues")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "title": task.title,
            "body": task.description,
            "labels": labels
        ])
        addHeaders(&request, token: token)
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderError.githubHTTP(response.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return TaskExternalMetadata(
            providerId: id,
            externalProjectId: settings.projectNodeId,
            externalIssueId: (object?["node_id"] as? String) ?? (object?["id"] as? NSNumber)?.stringValue,
            externalIssueNumber: (object?["number"] as? NSNumber)?.intValue,
            externalIssueURL: object?["html_url"] as? String,
            origin: "sloppy",
            syncState: "synced",
            lastSyncedAt: Date()
        )
    }

    private func updateIssue(task: ProjectTask, repo: GitHubRepositoryReference, token: String) async throws -> TaskExternalMetadata {
        guard let number = task.externalMetadata?.externalIssueNumber else {
            return task.externalMetadata ?? TaskExternalMetadata(providerId: id, origin: "sloppy", syncState: "pending")
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo.owner)/\(repo.repo)/issues/\(number)")!)
        request.httpMethod = "PATCH"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "title": task.title,
            "body": task.description
        ])
        addHeaders(&request, token: token)
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderError.githubHTTP(response.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        var metadata = task.externalMetadata ?? TaskExternalMetadata(providerId: id)
        metadata.syncState = "synced"
        metadata.lastSyncedAt = Date()
        return metadata
    }

    private func normalizedProjectURL(_ ref: GitHubProjectReference) -> String {
        if ref.ownerKind == "repos", let repository = ref.repository {
            return "https://github.com/\(ref.owner)/\(repository)/projects/\(ref.number)"
        }
        return "https://github.com/\(ref.ownerKind)/\(ref.owner)/projects/\(ref.number)"
    }

    private func addHeaders(_ request: inout URLRequest, token: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("sloppy-core", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
}
