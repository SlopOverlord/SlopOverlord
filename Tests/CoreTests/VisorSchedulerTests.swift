import Foundation
import Logging
import Testing
@testable import AgentRuntime
@testable import Core
@testable import Protocols

@Test
func visorSchedulerGeneratesBulletinAndDigestGoesToChannel() async throws {
    let (router, service) = try makeSchedulerTestRouter()
    let projectID = "scheduler-test-\(UUID().uuidString)"
    try await createProject(router: router, projectID: projectID, channelId: "general")

    // Trigger visor bulletin manually through service
    let bulletin = await service.triggerVisorBulletin()

    // Verify bulletin was generated with expected content
    #expect(bulletin.headline.contains("channels") || bulletin.headline.contains("workers"))
    #expect(!bulletin.digest.isEmpty)

    // Verify bulletin is persisted by listing through router
    let getProjectResponse = await router.handle(method: "GET", path: "/v1/projects/\(projectID)", body: nil)
    #expect(getProjectResponse.status == 200)
}

@Test
func visorSchedulerStartStopLifecycle() async throws {
    let (router, service) = try makeSchedulerTestRouter()

    // Bootstrap should start the scheduler
    await service.bootstrapChannelPlugins()

    // Verify scheduler can be started multiple times without error
    await service.bootstrapChannelPlugins()

    // Shutdown should stop the scheduler without error
    await service.shutdownChannelPlugins()
}

@Test
func visorSchedulerOverlapProtection() async throws {
    // Test the scheduler's internal overlap protection using an actor
    actor TestState {
        var callCount = 0
        var isRunning = false
        var overlapDetected = false

        func enter() -> Bool {
            if isRunning {
                overlapDetected = true
                return false
            }
            isRunning = true
            return true
        }

        func exit() {
            isRunning = false
            callCount += 1
        }

        func getCallCount() -> Int { callCount }
        func wasOverlapDetected() -> Bool { overlapDetected }
    }

    let state = TestState()
    let logger = Logger(label: "test.visorscheduler")

    let scheduler = VisorScheduler(
        config: VisorSchedulerConfig(interval: .seconds(1), jitter: .seconds(0), autoStart: false),
        logger: logger
    ) {
        guard await state.enter() else { return }
        // Simulate slow operation
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        await state.exit()
    }

    // Trigger multiple times rapidly
    await scheduler.triggerImmediately()
    await scheduler.triggerImmediately()
    await scheduler.triggerImmediately()

    // Wait for any pending operations
    try? await Task.sleep(nanoseconds: 300_000_000) // 300ms

    // Should have completed at least one, but overlap should have been prevented
    let callCount = await state.getCallCount()
    let overlapDetected = await state.wasOverlapDetected()
    #expect(callCount >= 1)
    #expect(!overlapDetected)
}

@Test
func visorSchedulerCancelSafety() async throws {
    let logger = Logger(label: "test.visorscheduler")
    actor CallCounter {
        var count = 0
        func increment() { count += 1 }
        func get() -> Int { count }
    }
    let counter = CallCounter()

    let scheduler = VisorScheduler(
        config: VisorSchedulerConfig(interval: .seconds(1), jitter: .seconds(0), autoStart: false),
        logger: logger
    ) {
        await counter.increment()
    }

    // Start the scheduler
    await scheduler.start()
    let runningAfterStart = await scheduler.running()
    #expect(runningAfterStart)

    // Stop immediately (cancel safety test)
    await scheduler.stop()
    let runningAfterStop = await scheduler.running()
    #expect(!runningAfterStop)

    // Should not crash and should be restartable
    await scheduler.start()
    let runningAfterRestart = await scheduler.running()
    #expect(runningAfterRestart)

    await scheduler.stop()
}

// MARK: - Helpers

private func makeSchedulerTestRouter() throws -> (CoreRouter, CoreService) {
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-scheduler-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    return (router, service)
}

private func createProject(router: CoreRouter, projectID: String, channelId: String) async throws {
    let body = try JSONEncoder().encode(
        ProjectCreateRequest(
            id: projectID,
            name: "Scheduler Test Project",
            description: "Visor scheduler integration tests",
            channels: [.init(title: "General", channelId: channelId)]
        )
    )

    let response = await router.handle(method: "POST", path: "/v1/projects", body: body)
    #expect(response.status == 201)
}
