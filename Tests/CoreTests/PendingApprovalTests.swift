import Foundation
import Testing
@testable import Core
@testable import Protocols
import PluginSDK

// MARK: - PendingApprovalService tests

@Test
func pendingApprovalServiceAddAndList() async {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("approval-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let service = PendingApprovalService(workspaceDirectory: dir.path)

    let entry = await service.addPending(
        platform: "telegram",
        platformUserId: "12345",
        displayName: "Alice",
        chatId: "-100000"
    )

    #expect(entry.platform == "telegram")
    #expect(entry.platformUserId == "12345")
    #expect(entry.displayName == "Alice")
    #expect(entry.code.count == 6)

    let list = await service.listPending()
    #expect(list.count == 1)
    #expect(list[0].id == entry.id)
}

@Test
func pendingApprovalServiceDeduplicates() async {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("approval-dedup-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let service = PendingApprovalService(workspaceDirectory: dir.path)

    let first = await service.addPending(
        platform: "telegram", platformUserId: "12345", displayName: "Alice", chatId: "-100"
    )
    let second = await service.addPending(
        platform: "telegram", platformUserId: "12345", displayName: "Alice", chatId: "-100"
    )

    #expect(first.id == second.id)
    let list = await service.listPending()
    #expect(list.count == 1)
}

@Test
func pendingApprovalServiceRemove() async {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("approval-remove-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let service = PendingApprovalService(workspaceDirectory: dir.path)
    let entry = await service.addPending(
        platform: "discord", platformUserId: "user-abc", displayName: "Bob", chatId: "channel-1"
    )
    await service.removePending(id: entry.id)
    let list = await service.listPending()
    #expect(list.isEmpty)
}

@Test
func pendingApprovalServicePlatformFilter() async {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("approval-filter-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let service = PendingApprovalService(workspaceDirectory: dir.path)
    _ = await service.addPending(platform: "telegram", platformUserId: "tg-1", displayName: "TG", chatId: "1")
    _ = await service.addPending(platform: "discord", platformUserId: "dc-1", displayName: "DC", chatId: "2")

    let tgList = await service.listPending(platform: "telegram")
    let dcList = await service.listPending(platform: "discord")

    #expect(tgList.count == 1)
    #expect(tgList[0].platform == "telegram")
    #expect(dcList.count == 1)
    #expect(dcList[0].platform == "discord")
}

@Test
func pendingApprovalServiceFindByUser() async {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("approval-find-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let service = PendingApprovalService(workspaceDirectory: dir.path)
    let entry = await service.addPending(platform: "telegram", platformUserId: "u42", displayName: "Zoe", chatId: "-42")

    let found = await service.findByUser(platform: "telegram", platformUserId: "u42")
    #expect(found?.id == entry.id)

    let notFound = await service.findByUser(platform: "telegram", platformUserId: "u999")
    #expect(notFound == nil)
}

// MARK: - InMemoryPersistenceStore channel_access_users tests

@Test
func inMemoryAccessUserCRUD() async {
    let store = InMemoryPersistenceStore()

    let user = ChannelAccessUser(
        id: UUID().uuidString,
        platform: "telegram",
        platformUserId: "99999",
        displayName: "Charlie",
        status: "approved"
    )
    await store.saveChannelAccessUser(user)

    let found = await store.channelAccessUser(platform: "telegram", platformUserId: "99999")
    #expect(found?.displayName == "Charlie")
    #expect(found?.status == "approved")

    let all = await store.listChannelAccessUsers(platform: nil)
    #expect(all.count >= 1)

    let filtered = await store.listChannelAccessUsers(platform: "telegram")
    #expect(filtered.contains { $0.platformUserId == "99999" })

    await store.deleteChannelAccessUser(id: user.id)
    let afterDelete = await store.channelAccessUser(platform: "telegram", platformUserId: "99999")
    #expect(afterDelete == nil)
}

@Test
func inMemoryAccessUserUpsert() async {
    let store = InMemoryPersistenceStore()

    await store.saveChannelAccessUser(ChannelAccessUser(
        id: UUID().uuidString, platform: "discord", platformUserId: "dc-99",
        displayName: "Dave", status: "approved"
    ))
    await store.saveChannelAccessUser(ChannelAccessUser(
        id: UUID().uuidString, platform: "discord", platformUserId: "dc-99",
        displayName: "Dave", status: "blocked"
    ))

    let found = await store.channelAccessUser(platform: "discord", platformUserId: "dc-99")
    #expect(found?.status == "blocked")

    let all = await store.listChannelAccessUsers(platform: "discord")
    let matching = all.filter { $0.platformUserId == "dc-99" }
    #expect(matching.count == 1)
}

// MARK: - CoreRouter channel-approvals endpoint tests

private func makeApprovalService() -> CoreService {
    CoreService(config: .default, persistenceBuilder: InMemoryCorePersistenceBuilder())
}

@Test
func channelApprovalsListEndpoint() async throws {
    let service = makeApprovalService()
    let router = CoreRouter(service: service)

    _ = await service.pendingApprovalService.addPending(
        platform: "telegram", platformUserId: "777", displayName: "Eve", chatId: "-9999"
    )

    let response = await router.handle(method: "GET", path: "/v1/channel-approvals/pending", body: nil)
    #expect(response.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let list = try decoder.decode([PendingApprovalEntry].self, from: response.body)
    #expect(list.count == 1)
    #expect(list[0].displayName == "Eve")
}

@Test
func channelApprovalsPlatformFilterEndpoint() async throws {
    let service = makeApprovalService()
    let router = CoreRouter(service: service)

    _ = await service.pendingApprovalService.addPending(platform: "telegram", platformUserId: "tg-1", displayName: "TG1", chatId: "1")
    _ = await service.pendingApprovalService.addPending(platform: "discord", platformUserId: "dc-1", displayName: "DC1", chatId: "2")

    let tgResponse = await router.handle(method: "GET", path: "/v1/channel-approvals/pending?platform=telegram", body: nil)
    #expect(tgResponse.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let tgList = try decoder.decode([PendingApprovalEntry].self, from: tgResponse.body)
    #expect(tgList.count == 1)
    #expect(tgList[0].platform == "telegram")
}

@Test
func channelApprovalsApproveWithCorrectCode() async throws {
    let service = makeApprovalService()
    let router = CoreRouter(service: service)

    let entry = await service.pendingApprovalService.addPending(
        platform: "telegram", platformUserId: "888", displayName: "Frank", chatId: "-8888"
    )

    let body = try JSONEncoder().encode(ChannelApprovalCodeRequest(code: entry.code))
    let response = await router.handle(
        method: "POST", path: "/v1/channel-approvals/\(entry.id)/approve", body: body
    )
    #expect(response.status == 200)

    let remaining = await service.pendingApprovalService.listPending()
    #expect(remaining.isEmpty)
}

@Test
func channelApprovalsApproveWithWrongCode() async throws {
    let service = makeApprovalService()
    let router = CoreRouter(service: service)

    let entry = await service.pendingApprovalService.addPending(
        platform: "telegram", platformUserId: "999", displayName: "Grace", chatId: "-9000"
    )

    let body = try JSONEncoder().encode(ChannelApprovalCodeRequest(code: "WRONG1"))
    let response = await router.handle(
        method: "POST", path: "/v1/channel-approvals/\(entry.id)/approve", body: body
    )
    #expect(response.status == 400)

    let remaining = await service.pendingApprovalService.listPending()
    #expect(remaining.count == 1)
}

@Test
func channelApprovalsRejectEndpoint() async throws {
    let service = makeApprovalService()
    let router = CoreRouter(service: service)

    let entry = await service.pendingApprovalService.addPending(
        platform: "discord", platformUserId: "dc-reject", displayName: "Henry", chatId: "ch-reject"
    )

    let response = await router.handle(
        method: "POST", path: "/v1/channel-approvals/\(entry.id)/reject", body: nil
    )
    #expect(response.status == 200)

    let remaining = await service.pendingApprovalService.listPending()
    #expect(remaining.isEmpty)
}

@Test
func channelApprovalsBlockEndpoint() async throws {
    let service = makeApprovalService()
    let router = CoreRouter(service: service)

    let entry = await service.pendingApprovalService.addPending(
        platform: "telegram", platformUserId: "tg-block", displayName: "Ivan", chatId: "ch-block"
    )

    let response = await router.handle(
        method: "POST", path: "/v1/channel-approvals/\(entry.id)/block", body: nil
    )
    #expect(response.status == 200)

    let remaining = await service.pendingApprovalService.listPending()
    #expect(remaining.isEmpty)
}

@Test
func channelApprovalsUsersEndpoint() async throws {
    let service = makeApprovalService()
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "GET", path: "/v1/channel-approvals/users", body: nil)
    #expect(response.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let users = try decoder.decode([ChannelAccessUser].self, from: response.body)
    #expect(users.isEmpty)
}

// MARK: - CoreService.checkAccess tests

@Test
func checkAccessNewUserCreatesPending() async {
    let service = makeApprovalService()

    let result = await service.checkAccess(
        platform: "telegram", platformUserId: "new-user", displayName: "New User", chatId: "-12345"
    )

    guard case .pendingApproval(let code, _) = result else {
        Issue.record("Expected pendingApproval, got \(result)")
        return
    }
    #expect(code.count == 6)

    let pending = await service.pendingApprovalService.listPending()
    #expect(pending.count == 1)
    #expect(pending[0].platformUserId == "new-user")
}

@Test
func checkAccessSameUserReturnsSameCode() async {
    let service = makeApprovalService()

    let result1 = await service.checkAccess(
        platform: "telegram", platformUserId: "repeated-user", displayName: "Repeated", chatId: "-1"
    )
    let result2 = await service.checkAccess(
        platform: "telegram", platformUserId: "repeated-user", displayName: "Repeated", chatId: "-1"
    )

    guard case .pendingApproval(let code1, _) = result1,
          case .pendingApproval(let code2, _) = result2 else {
        Issue.record("Expected both results to be pendingApproval")
        return
    }
    #expect(code1 == code2)

    let pending = await service.pendingApprovalService.listPending()
    #expect(pending.count == 1)
}

@Test
func checkAccessApprovedUserIsAllowed() async {
    let service = makeApprovalService()

    _ = await service.checkAccess(platform: "telegram", platformUserId: "will-approve", displayName: "Will", chatId: "-1")
    let entry = await service.pendingApprovalService.findByUser(platform: "telegram", platformUserId: "will-approve")!
    let approved = await service.approvePendingApproval(id: entry.id, code: entry.code)
    #expect(approved)

    let result = await service.checkAccess(
        platform: "telegram", platformUserId: "will-approve", displayName: "Will", chatId: "-1"
    )
    if case .allowed = result { } else {
        Issue.record("Expected .allowed, got \(result)")
    }
}

@Test
func checkAccessBlockedUserIsBlocked() async {
    let service = makeApprovalService()

    _ = await service.checkAccess(platform: "discord", platformUserId: "bad-actor", displayName: "Bad", chatId: "ch")
    let entry = await service.pendingApprovalService.findByUser(platform: "discord", platformUserId: "bad-actor")!
    let blocked = await service.blockPendingApproval(id: entry.id)
    #expect(blocked)

    let result = await service.checkAccess(
        platform: "discord", platformUserId: "bad-actor", displayName: "Bad", chatId: "ch"
    )
    if case .blocked = result { } else {
        Issue.record("Expected .blocked, got \(result)")
    }
}
