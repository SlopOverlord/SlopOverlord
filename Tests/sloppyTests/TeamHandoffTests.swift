import Foundation
import Testing
@testable import sloppy
@testable import Protocols

private func saveProject(_ project: ProjectRecord, service: CoreService) async {
    await service.store.saveProject(project)
}

private func channel(_ id: String = "chan") -> ProjectChannel {
    ProjectChannel(id: "project-channel-\(id)", title: id, channelId: id)
}

private func node(_ id: String, agent: String, role: ActorSystemRole? = nil, channelId: String? = "chan") -> ActorNode {
    ActorNode(
        id: id,
        displayName: agent,
        kind: .agent,
        linkedAgentId: agent,
        channelId: channelId,
        systemRole: role
    )
}

private func createAgents(_ ids: [String], service: CoreService) async throws {
    for id in ids {
        _ = try await service.createAgent(
            AgentCreateRequest(id: id, displayName: id.uppercased(), role: id.uppercased(), isSystem: false)
        )
    }
}

private func actorID(_ agentID: String) -> String {
    "agent:\(agentID)"
}

@Test
func nextTeamHandoffDelegateFollowsTaskLinks() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())

    _ = try? await service.createAgent(AgentCreateRequest(id: "dev", displayName: "Dev", role: "Dev", isSystem: false))
    _ = try? await service.createAgent(AgentCreateRequest(id: "qa", displayName: "QA", role: "QA", isSystem: false))
    _ = try? await service.createAgent(AgentCreateRequest(id: "reviewer", displayName: "Reviewer", role: "Reviewer", isSystem: false))

    // Setup Board
    var board = ActorBoardSnapshot(nodes: [], links: [], teams: [])
    let node1 = ActorNode(id: "agent:dev", displayName: "Dev", kind: .agent, linkedAgentId: "dev")
    let node2 = ActorNode(id: "agent:qa", displayName: "QA", kind: .agent, linkedAgentId: "qa")
    let node3 = ActorNode(id: "agent:reviewer", displayName: "Reviewer", kind: .agent, linkedAgentId: "reviewer")
    
    // Links: Dev -> Reviewer -> QA. (So it skips the array order [Dev, QA, Reviewer])
    let link1 = ActorLink(
        id: "link1", sourceActorId: "agent:dev", targetActorId: "agent:reviewer",
        direction: .oneWay, communicationType: .task
    )
    let link2 = ActorLink(
        id: "link2", sourceActorId: "agent:reviewer", targetActorId: "agent:qa",
        direction: .oneWay, communicationType: .task
    )
    
    // Team: [Dev, QA, Reviewer]
    let team = ActorTeam(id: "team:1", name: "Team 1", memberActorIds: ["agent:dev", "agent:qa", "agent:reviewer"])
    board.nodes = [node1, node2, node3]
    board.links = [link1, link2]
    board.teams = [team]

    _ = try await service.updateActorBoard(request: ActorBoardUpdateRequest(nodes: board.nodes, links: board.links, teams: board.teams))

    // Create Project & Task
    let project = ProjectRecord(
        id: "proj:1", name: "Test Project", description: "Test",
        channels: [], tasks: [
            ProjectTask(
                id: "task:1", title: "Task 1", description: "", priority: "medium", status: "done",
                teamId: "team:1", claimedActorId: "agent:dev", claimedAgentId: "dev"
            )
        ]
    )

    let delegate1 = await service.nextTeamHandoffDelegate(project: project, task: project.tasks[0])
    
    // Expected: It should follow link1 to "agent:reviewer", ignoring the array order which says "agent:qa" is next.
    #expect(delegate1?.actorID == "agent:reviewer")
    #expect(delegate1?.agentID == "reviewer")
    
    // Test second handoff
    var task2 = project.tasks[0]
    task2.claimedActorId = "agent:reviewer"
    let delegate2 = await service.nextTeamHandoffDelegate(project: project, task: task2)
    #expect(delegate2?.actorID == "agent:qa")
}

@Test
func nextTeamHandoffDelegateFallsBackToArrayIndex() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())

    _ = try? await service.createAgent(AgentCreateRequest(id: "dev", displayName: "Dev", role: "Dev", isSystem: false))
    _ = try? await service.createAgent(AgentCreateRequest(id: "qa", displayName: "QA", role: "QA", isSystem: false))
    _ = try? await service.createAgent(AgentCreateRequest(id: "reviewer", displayName: "Reviewer", role: "Reviewer", isSystem: false))

    // Setup Board with NO links
    var board = ActorBoardSnapshot(nodes: [], links: [], teams: [])
    let node1 = ActorNode(id: "agent:dev", displayName: "Dev", kind: .agent, linkedAgentId: "dev")
    let node2 = ActorNode(id: "agent:qa", displayName: "QA", kind: .agent, linkedAgentId: "qa")
    let team = ActorTeam(id: "team:1", name: "Team 1", memberActorIds: ["agent:dev", "agent:qa"])
    board.nodes = [node1, node2]
    board.teams = [team]

    _ = try await service.updateActorBoard(request: ActorBoardUpdateRequest(nodes: board.nodes, links: board.links, teams: board.teams))

    let project = ProjectRecord(
        id: "proj:1", name: "Test Project", description: "Test",
        channels: [], tasks: [
            ProjectTask(
                id: "task:1", title: "Task 1", description: "", priority: "medium", status: "done",
                teamId: "team:1", claimedActorId: "agent:dev"
            )
        ]
    )

    let delegate = await service.nextTeamHandoffDelegate(project: project, task: project.tasks[0])
    
    // Should fallback to next in array: QA
    #expect(delegate?.actorID == "agent:qa")
    #expect(delegate?.agentID == "qa")
}

@Test
func readyTeamTaskStartsWithFirstOrderedTeamMember() async throws {
    let service = CoreService(config: CoreConfig.test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    try await createAgents(["sloppy_manager", "serega_swift_dev", "review_bro"], service: service)

    let manager = actorID("sloppy_manager")
    let developer = actorID("serega_swift_dev")
    let reviewer = actorID("review_bro")
    let board = ActorBoardSnapshot(
        nodes: [
            node(manager, agent: "sloppy_manager", role: .manager),
            node(developer, agent: "serega_swift_dev", role: .developer),
            node(reviewer, agent: "review_bro", role: .reviewer)
        ],
        links: [],
        teams: [
            ActorTeam(id: "team:ordered", name: "Ordered Team", memberActorIds: [manager, developer, reviewer])
        ]
    )
    _ = try await service.updateActorBoard(request: ActorBoardUpdateRequest(nodes: board.nodes, links: board.links, teams: board.teams))

    let task = ProjectTask(
        id: "task-ordered",
        title: "Start with manager",
        description: "",
        priority: "medium",
        status: ProjectTaskStatus.ready.rawValue,
        teamId: "team:ordered"
    )
    let project = ProjectRecord(
        id: "proj-ordered-\(UUID().uuidString)",
        name: "Ordered Team Project",
        description: "",
        channels: [channel()],
        tasks: [task],
        reviewSettings: ProjectReviewSettings(enabled: false)
    )
    await saveProject(project, service: service)

    await service.handleTaskBecameReady(projectID: project.id, taskID: task.id)

    let saved = try await service.getProject(id: project.id)
    let savedTask = try #require(saved.tasks.first(where: { $0.id == task.id }))
    #expect(savedTask.status == ProjectTaskStatus.inProgress.rawValue)
    #expect(savedTask.claimedActorId == manager)
    #expect(savedTask.claimedAgentId == "sloppy_manager")
    #expect(savedTask.routeHistory.map(\.actorId) == [manager])
}

@Test
func handoffLoopBlocksBeforeRevisitingActor() async throws {
    let service = CoreService(config: CoreConfig.test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    try await createAgents(["a", "b"], service: service)

    let actorA = actorID("a")
    let actorB = actorID("b")
    let board = ActorBoardSnapshot(
        nodes: [
            node(actorA, agent: "a"),
            node(actorB, agent: "b")
        ],
        links: [
            ActorLink(id: "a-b", sourceActorId: actorA, targetActorId: actorB, direction: .oneWay, communicationType: .task),
            ActorLink(id: "b-a", sourceActorId: actorB, targetActorId: actorA, direction: .oneWay, communicationType: .task)
        ],
        teams: [
            ActorTeam(id: "team:loop", name: "Loop Team", memberActorIds: [actorA, actorB])
        ]
    )
    _ = try await service.updateActorBoard(request: ActorBoardUpdateRequest(nodes: board.nodes, links: board.links, teams: board.teams))

    let task = ProjectTask(
        id: "task-loop",
        title: "Looping task",
        description: "",
        priority: "medium",
        status: ProjectTaskStatus.done.rawValue,
        actorId: actorB,
        teamId: "team:loop",
        claimedActorId: actorB,
        claimedAgentId: "b",
        routeHistory: [
            ProjectTaskRouteStep(actorId: actorA, agentId: "a", reason: "delegate"),
            ProjectTaskRouteStep(actorId: actorB, agentId: "b", reason: "handoff")
        ]
    )
    let project = ProjectRecord(
        id: "proj-loop-\(UUID().uuidString)",
        name: "Loop Project",
        description: "",
        channels: [channel()],
        tasks: [task],
        reviewSettings: ProjectReviewSettings(enabled: false)
    )
    await saveProject(project, service: service)

    await service.handleVisorEvent(
        EventEnvelope(
            messageType: .workerCompleted,
            channelId: "chan",
            taskId: task.id,
            workerId: "worker-b",
            payload: .object([:])
        )
    )

    let saved = try await service.getProject(id: project.id)
    let savedTask = try #require(saved.tasks.first(where: { $0.id == task.id }))
    #expect(savedTask.status == ProjectTaskStatus.blocked.rawValue)
    #expect(savedTask.claimedActorId == actorA)
    #expect(savedTask.routeHistory.map(\.actorId) == [actorA, actorB, actorA])
    #expect(savedTask.description.contains("Autonomous routing loop detected"))
}

@Test
func linearTeamHandoffContinuesWithoutLoopBlock() async throws {
    let service = CoreService(config: CoreConfig.test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    try await createAgents(["a", "b", "c"], service: service)

    let actorA = actorID("a")
    let actorB = actorID("b")
    let actorC = actorID("c")
    let board = ActorBoardSnapshot(
        nodes: [
            node(actorA, agent: "a"),
            node(actorB, agent: "b"),
            node(actorC, agent: "c")
        ],
        links: [
            ActorLink(id: "a-b", sourceActorId: actorA, targetActorId: actorB, direction: .oneWay, communicationType: .task),
            ActorLink(id: "b-c", sourceActorId: actorB, targetActorId: actorC, direction: .oneWay, communicationType: .task)
        ],
        teams: [
            ActorTeam(id: "team:linear", name: "Linear Team", memberActorIds: [actorA, actorB, actorC])
        ]
    )
    _ = try await service.updateActorBoard(request: ActorBoardUpdateRequest(nodes: board.nodes, links: board.links, teams: board.teams))

    let task = ProjectTask(
        id: "task-linear",
        title: "Linear task",
        description: "",
        priority: "medium",
        status: ProjectTaskStatus.done.rawValue,
        actorId: actorB,
        teamId: "team:linear",
        claimedActorId: actorB,
        claimedAgentId: "b",
        routeHistory: [
            ProjectTaskRouteStep(actorId: actorA, agentId: "a", reason: "delegate"),
            ProjectTaskRouteStep(actorId: actorB, agentId: "b", reason: "handoff")
        ]
    )
    let project = ProjectRecord(
        id: "proj-linear-\(UUID().uuidString)",
        name: "Linear Project",
        description: "",
        channels: [channel()],
        tasks: [task],
        reviewSettings: ProjectReviewSettings(enabled: false)
    )
    await saveProject(project, service: service)

    await service.handleVisorEvent(
        EventEnvelope(
            messageType: .workerCompleted,
            channelId: "chan",
            taskId: task.id,
            workerId: "worker-b",
            payload: .object([:])
        )
    )

    let saved = try await service.getProject(id: project.id)
    let savedTask = try #require(saved.tasks.first(where: { $0.id == task.id }))
    #expect(savedTask.status == ProjectTaskStatus.inProgress.rawValue)
    #expect(savedTask.claimedActorId == actorC)
    #expect(savedTask.routeHistory.map(\.actorId) == [actorA, actorB, actorC])
}

@Test
func reviewRejectBlocksWhenRouteLimitReached() async throws {
    let service = CoreService(config: CoreConfig.test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    try await createAgents(["dev", "reviewer", "qa"], service: service)

    let developer = actorID("dev")
    let reviewer = actorID("reviewer")
    let qa = actorID("qa")
    let board = ActorBoardSnapshot(
        nodes: [
            node(developer, agent: "dev", role: .developer),
            node(reviewer, agent: "reviewer", role: .reviewer),
            node(qa, agent: "qa", role: .qa)
        ],
        links: [],
        teams: [
            ActorTeam(id: "team:review", name: "Review Team", memberActorIds: [developer, reviewer, qa])
        ]
    )
    _ = try await service.updateActorBoard(request: ActorBoardUpdateRequest(nodes: board.nodes, links: board.links, teams: board.teams))

    let task = ProjectTask(
        id: "task-review-limit",
        title: "Review limit",
        description: "",
        priority: "medium",
        status: ProjectTaskStatus.needsReview.rawValue,
        actorId: reviewer,
        teamId: "team:review",
        claimedActorId: reviewer,
        claimedAgentId: "reviewer",
        routeHistory: [
            ProjectTaskRouteStep(actorId: reviewer, agentId: "reviewer", reason: "handoff"),
            ProjectTaskRouteStep(actorId: qa, agentId: "qa", reason: "handoff")
        ]
    )
    let project = ProjectRecord(
        id: "proj-review-limit-\(UUID().uuidString)",
        name: "Review Limit Project",
        description: "",
        channels: [channel()],
        tasks: [task],
        reviewSettings: ProjectReviewSettings(enabled: false, maxAutonomousRouteSteps: 2)
    )
    await saveProject(project, service: service)

    try await service.rejectTask(projectID: project.id, taskID: task.id, reason: "Needs another implementation pass")

    let saved = try await service.getProject(id: project.id)
    let savedTask = try #require(saved.tasks.first(where: { $0.id == task.id }))
    #expect(savedTask.status == ProjectTaskStatus.blocked.rawValue)
    #expect(savedTask.claimedActorId == developer)
    #expect(savedTask.routeHistory.map(\.actorId) == [reviewer, qa, developer])
    #expect(savedTask.description.contains("Autonomous route limit reached"))
}

@Test
func manualReadyResetClearsRouteHistoryForFreshRun() async throws {
    let service = CoreService(config: CoreConfig.test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    try await createAgents(["a", "b"], service: service)

    let actorA = actorID("a")
    let actorB = actorID("b")
    let board = ActorBoardSnapshot(
        nodes: [
            node(actorA, agent: "a"),
            node(actorB, agent: "b")
        ],
        links: [],
        teams: [
            ActorTeam(id: "team:reset", name: "Reset Team", memberActorIds: [actorA, actorB])
        ]
    )
    _ = try await service.updateActorBoard(request: ActorBoardUpdateRequest(nodes: board.nodes, links: board.links, teams: board.teams))

    let task = ProjectTask(
        id: "task-reset",
        title: "Reset task",
        description: "Blocked by loop",
        priority: "medium",
        status: ProjectTaskStatus.blocked.rawValue,
        actorId: actorA,
        teamId: "team:reset",
        claimedActorId: actorA,
        claimedAgentId: "a",
        routeHistory: [
            ProjectTaskRouteStep(actorId: actorA, agentId: "a", reason: "delegate"),
            ProjectTaskRouteStep(actorId: actorB, agentId: "b", reason: "handoff"),
            ProjectTaskRouteStep(actorId: actorA, agentId: "a", reason: "handoff")
        ]
    )
    let project = ProjectRecord(
        id: "proj-reset-\(UUID().uuidString)",
        name: "Reset Project",
        description: "",
        channels: [channel()],
        tasks: [task],
        reviewSettings: ProjectReviewSettings(enabled: false)
    )
    await saveProject(project, service: service)

    _ = try await service.updateProjectTask(
        projectID: project.id,
        taskID: task.id,
        request: ProjectTaskUpdateRequest(status: ProjectTaskStatus.ready.rawValue)
    )

    let saved = try await service.getProject(id: project.id)
    let savedTask = try #require(saved.tasks.first(where: { $0.id == task.id }))
    #expect(savedTask.status == ProjectTaskStatus.inProgress.rawValue)
    #expect(savedTask.claimedActorId == actorA)
    #expect(savedTask.routeHistory.map(\.actorId) == [actorA])
}
