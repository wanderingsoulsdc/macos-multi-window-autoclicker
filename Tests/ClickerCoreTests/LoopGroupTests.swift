import XCTest
@testable import ClickerCore

final class LoopGroupTests: XCTestCase {
    func testCountsAndRoundTripWithDisabledGroupMember() throws {
        var plan = ClickPlan()
        let before = ClickPoint(name: "入口"), first = ClickPoint(name: "组A", count: 2)
        let disabled = ClickPoint(name: "跳过", count: 50, enabled: false)
        let last = ClickPoint(name: "组B"), after = ClickPoint(name: "返回")
        plan.points = [before, first, disabled, last, after]
        let id = try plan.createGroup(start: first.id, end: last.id, name: "小循环", rounds: 3)
        plan.rounds = 2
        XCTAssertEqual(plan.version, 3)
        XCTAssertEqual(plan.executionBlocks.map(\.indices), [0..<1, 1..<4, 4..<5])
        XCTAssertEqual(plan.executionBlocks[1].group?.id, id)
        XCTAssertEqual(plan.clicksPerRound, 11)
        XCTAssertEqual(plan.totalClicks, 22)
        let restored = try JSONDecoder().decode(ClickPlan.self, from: JSONEncoder().encode(plan))
        try restored.validateForRun()
        XCTAssertEqual(restored, plan)
    }

    func testGroupMovesAsUnitAndCanBeUngrouped() throws {
        var plan = ClickPlan()
        let first = ClickPoint(name: "A"), second = ClickPoint(name: "B"), third = ClickPoint(name: "C"), fourth = ClickPoint(name: "D")
        plan.points = [first, second, third, fourth]
        let id = try plan.createGroup(start: second.id, end: third.id, name: "组", rounds: 2)
        XCTAssertFalse(plan.moveStep(second.id, relativeTo: first.id, placement: .before))
        XCTAssertTrue(plan.moveStep(third.id, relativeTo: second.id, placement: .before))
        XCTAssertTrue(plan.moveStep(id, relativeTo: fourth.id, placement: .after))
        XCTAssertEqual(plan.points.map(\.name), ["A", "D", "C", "B"])
        plan.ungroup(id)
        XCTAssertEqual(plan.points.map(\.name), ["A", "D", "C", "B"])
        XCTAssertEqual(plan.version, 1)
        XCTAssertTrue((plan.groupSettings ?? []).isEmpty)
        try plan.validate()
    }

    func testCopyAndDeletionPreserveGroupMembership() throws {
        var plan = ClickPlan()
        let first = ClickPoint(name: "组首"), last = ClickPoint(name: "组尾"), extra = ClickPoint(name: "普通步骤")
        plan.points = [first, last, extra]
        let id = try plan.createGroup(start: first.id, end: last.id, name: "循环", rounds: 2)
        let inside = try XCTUnwrap(plan.duplicateSteps([last.id], placement: .belowEach))
        let outside = try XCTUnwrap(plan.duplicateSteps([first.id], placement: .bottom))
        XCTAssertEqual(plan.points.map(\.groupID), [id, id, id, nil, nil])
        XCTAssertEqual(plan.points.last?.id, outside)
        plan.points.removeAll { [first.id, last.id, inside].contains($0.id) }
        XCTAssertNil(plan.groupSettings)
        try plan.validate()
    }

    func testRejectsNestedOrBrokenGroupsAndInvalidRounds() throws {
        var plan = ClickPlan()
        let first = ClickPoint(), second = ClickPoint(), third = ClickPoint(), fourth = ClickPoint()
        plan.points = [first, second, third, fourth]
        XCTAssertThrowsError(try plan.createGroup(start: first.id, end: second.id, name: "", rounds: 0))
        let id = try plan.createGroup(start: second.id, end: third.id, name: "", rounds: 1)
        XCTAssertThrowsError(try plan.createGroup(start: first.id, end: fourth.id, name: "", rounds: 2))
        XCTAssertThrowsError(try plan.editGroup(id, name: "", rounds: 1_000_000))
        plan.points.swapAt(2, 3)
        XCTAssertThrowsError(try plan.validate())
    }
}
