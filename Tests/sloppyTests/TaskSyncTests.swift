import Foundation
import Protocols
import Testing
@testable import sloppy

@Test
func gitHubProjectURLParserAcceptsOrgAndUserProjects() throws {
    let org = try GitHubProjectTaskSyncProvider.parseProjectReference("https://github.com/orgs/AdaEngine/projects/2")
    #expect(org.ownerKind == "orgs")
    #expect(org.owner == "AdaEngine")
    #expect(org.number == 2)

    let user = try GitHubProjectTaskSyncProvider.parseProjectReference("https://github.com/users/vlad/projects/10")
    #expect(user.ownerKind == "users")
    #expect(user.owner == "vlad")
    #expect(user.number == 10)
}

@Test
func gitHubProjectURLParserAcceptsRepositoryProjects() throws {
    let repo = try GitHubProjectTaskSyncProvider.parseProjectReference("https://github.com/AdaEngine/AdaEngine/projects/2")
    #expect(repo.ownerKind == "repos")
    #expect(repo.owner == "AdaEngine")
    #expect(repo.repository == "AdaEngine")
    #expect(repo.number == 2)
}

@Test
func gitHubStatusMappingFallsBackToBasicFlow() {
    #expect(GitHubProjectTaskSyncProvider.mappedGitHubStatus(sloppyStatus: "ready", mappings: [:]) == "Todo")
    #expect(GitHubProjectTaskSyncProvider.mappedGitHubStatus(sloppyStatus: "in_progress", mappings: [:]) == "In Progress")
    #expect(GitHubProjectTaskSyncProvider.mappedGitHubStatus(sloppyStatus: "cancelled", mappings: [:]) == "Done")
    #expect(GitHubProjectTaskSyncProvider.mappedGitHubStatus(sloppyStatus: "ready", mappings: ["ready": "Queued"]) == "Queued")
}

@Test
func taskSyncHMACMatchesKnownVector() {
    let digest = TaskSyncCrypto.hmacSHA256Hex(
        key: Data("key".utf8),
        message: Data("The quick brown fox jumps over the lazy dog".utf8)
    )
    #expect(digest == "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
    #expect(TaskSyncCrypto.verifyGitHubSignature(
        body: Data("The quick brown fox jumps over the lazy dog".utf8),
        secret: "key",
        signatureHeader: "sha256=\(digest)"
    ))
}

@Test
func taskSyncRouterLinksTokenStatusAndDedupesWebhookDelivery() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let router = CoreRouter(service: service)

    let create = try await service.createProject(ProjectCreateRequest(id: "sync-test", name: "Sync Test"))
    #expect(create.project.id == "sync-test")

    let linkBody = try JSONEncoder().encode(ProjectTaskSyncLinkRequest(
        projectURL: "https://github.com/orgs/AdaEngine/projects/2",
        defaultRepo: "AdaEngine/Sloppy"
    ))
    let linkResponse = await router.handle(method: "POST", path: "/v1/projects/sync-test/task-sync/link", body: linkBody)
    #expect(linkResponse.status == 200)

    let tokenBody = try JSONEncoder().encode(ProjectTaskSyncTokenRequest(token: "ghp_test_token_123456"))
    let tokenResponse = await router.handle(method: "POST", path: "/v1/projects/sync-test/task-sync/token", body: tokenBody)
    #expect(tokenResponse.status == 200)
    let tokenStatus = try JSONDecoder().decode(ProjectTaskSyncTokenStatusResponse.self, from: tokenResponse.body)
    #expect(tokenStatus.hasOverrideToken)
    #expect(tokenStatus.maskedToken == "ghp_...3456")

    let workspace = config.resolvedWorkspaceRootURL(currentDirectory: FileManager.default.currentDirectoryPath)
    let secretURL = workspace
        .appendingPathComponent("auth/task-sync/github", isDirectory: true)
        .appendingPathComponent("sync-test.webhook-secret")
    let secret = try String(contentsOf: secretURL).trimmingCharacters(in: .whitespacesAndNewlines)
    let body = Data(#"{"action":"opened","issue":{"id":1,"node_id":"ISSUE_1","number":12,"html_url":"https://github.com/AdaEngine/Sloppy/issues/12","title":"Issue","body":"Body","state":"open"}}"#.utf8)
    let signature = "sha256=" + TaskSyncCrypto.hmacSHA256Hex(key: Data(secret.utf8), message: body)
    let headers = [
        "X-GitHub-Delivery": "delivery-1",
        "X-GitHub-Event": "issues",
        "X-Hub-Signature-256": signature
    ]

    let webhookResponse = await router.handle(method: "POST", path: "/v1/task-sync/github/webhook", body: body, headers: headers)
    #expect(webhookResponse.status == 200)
    let duplicateResponse = await router.handle(method: "POST", path: "/v1/task-sync/github/webhook", body: body, headers: headers)
    #expect(duplicateResponse.status == 200)
    let duplicate = try JSONDecoder().decode(TaskSyncWebhookResponse.self, from: duplicateResponse.body)
    #expect(duplicate.duplicate)
}
