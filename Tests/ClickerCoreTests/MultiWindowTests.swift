import XCTest
@testable import ClickerCore

final class MultiWindowTests: XCTestCase {
    func testLegacyMigrationAndIndependentTabsRoundTripWithoutChangingLegacy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = PlanStore(url: directory.appendingPathComponent("session.json"))
        var original = ClickPlan(); original.windowCoordinates = true; original.mode = .commandBackground
        original.points = [ClickPoint(x: 120, y: 85, count: 37, interval: 0.25)]
        try legacy.save(original)
        let legacyData = try Data(contentsOf: legacy.url)
        let store = WorkspaceStore(url: directory.appendingPathComponent("workspace.json"), legacyURL: legacy.url)
        var document = try store.load()
        XCTAssertEqual(document.sessions.first?.plan, original)
        var second = SavedSession(plan: original)
        second.plan.points[0].count = 17
        second.plan.mode = .background
        document.sessions.append(second); document.selectedID = second.id
        try store.save(document)
        let restored = try store.load()
        XCTAssertEqual(restored, document)
        XCTAssertEqual(restored.sessions[0].plan.points[0].count, 37)
        XCTAssertEqual(restored.sessions[1].plan.points[0].count, 17)
        XCTAssertEqual(try Data(contentsOf: legacy.url), legacyData)
        document.sessions.append(second)
        XCTAssertThrowsError(try store.save(document))
        XCTAssertEqual(try store.load(), restored)
        try Data("{broken".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load()) // Never silently discard corrupt multi-tab data for the old plan.
    }

    @MainActor
    func testForegroundQueueSerializesAndCancelledWaiterDoesNotBlockNext() async throws {
        let queue = ForegroundQueue()
        let first = UUID(), second = UUID(), third = UUID()
        try await queue.acquire(first)
        var secondEntered = false, thirdEntered = false
        let cancelled = Task { @MainActor in try await queue.acquire(second); secondEntered = true }
        await Task.yield()
        let next = Task { @MainActor in try await queue.acquire(third); thirdEntered = true }
        await Task.yield()
        XCTAssertFalse(secondEntered); XCTAssertFalse(thirdEntered)
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled waiter acquired the mouse") } catch is CancellationError {} catch { throw error }
        queue.release(second) // A non-owner cannot release the active task.
        XCTAssertTrue(queue.isOccupied); XCTAssertFalse(thirdEntered)
        queue.release(first)
        try await next.value
        XCTAssertTrue(thirdEntered); XCTAssertTrue(queue.isOccupied)
        queue.release(first) // A late release must not release the new owner.
        XCTAssertTrue(queue.isOccupied)
        queue.release(third)
        XCTAssertFalse(queue.isOccupied)
    }

    @MainActor
    func testCancellationAfterGrantStillAllowsExplicitRelease() async throws {
        let queue = ForegroundQueue(), first = UUID(), second = UUID()
        try await queue.acquire(first)
        let next = Task { @MainActor in
            defer { queue.release(second) }
            try await queue.acquire(second)
            try Task.checkCancellation()
        }
        await Task.yield()
        queue.release(first); next.cancel()
        _ = await next.result
        XCTAssertFalse(queue.isOccupied)
    }
}
