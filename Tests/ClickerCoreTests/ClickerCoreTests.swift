import XCTest
import CoreGraphics
@testable import ClickerCore

final class ClickerCoreTests: XCTestCase {
    func testLaunchTimingPreservesOlderCountdownsAndRejectsExpiredAppointments() throws {
        let now = Date(timeIntervalSinceReferenceDate: 900_000_000)
        var legacy = ClickPlan()
        legacy.startDelay = 12
        let encoded = try JSONEncoder().encode(legacy)
        let restored = try JSONDecoder().decode(ClickPlan.self, from: encoded)
        XCTAssertEqual(try restored.launchTiming(now: now), .after(12))

        legacy.startMode = .immediate
        XCTAssertEqual(try legacy.launchTiming(now: now), .after(0))
        legacy.startMode = .scheduled
        XCTAssertThrowsError(try legacy.launchTiming(now: now))
        legacy.scheduledStart = now
        XCTAssertThrowsError(try legacy.launchTiming(now: now))
        XCTAssertNoThrow(try legacy.validate(), "Expired appointments remain editable after reopening.")

        let future = now.addingTimeInterval(37)
        legacy.scheduledStart = future
        let saved = try JSONDecoder().decode(ClickPlan.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(try saved.launchTiming(now: now), .at(future))
    }

    func testPortraitPreviewFitsWithoutCroppingAndMarkerRoundTrips() {
        let bounds = CGRect(x: 0, y: 0, width: 360, height: 720)
        for viewport in [CGSize(width: 620, height: 320), CGSize(width: 280, height: 550)] {
            let fit = CanvasTransform(bounds: bounds, viewport: viewport)
            XCTAssertLessThanOrEqual(fit.size.width, viewport.width)
            XCTAssertLessThanOrEqual(fit.size.height, viewport.height)
            XCTAssertEqual(fit.size.width / fit.size.height, bounds.width / bounds.height, accuracy: 0.000001)
            let logical = CGPoint(x: 120, y: 85)
            let returned = fit.logicalPoint(fit.displayedPoint(logical))
            XCTAssertEqual(returned.x, logical.x, accuracy: 0.000001)
            XCTAssertEqual(returned.y, logical.y, accuracy: 0.000001)
        }
    }
    func testPreviewZoomAndMultipleDisplayCoordinatesStayAligned() {
        let bounds = CGRect(x: -1710, y: -508, width: 4270, height: 1620)
        let point = CGPoint(x: 120, y: 85)
        for zoom in [0.25, 1, 2, 4] {
            let t = CanvasTransform(bounds: bounds, viewport: CGSize(width: 400, height: 300), zoom: zoom)
            XCTAssertEqual(t.scale, zoom)
            let display = t.displayedPoint(point)
            XCTAssertEqual(display.x, (point.x - bounds.minX) * zoom, accuracy: 0.00001)
            XCTAssertEqual(t.logicalPoint(display).x, point.x, accuracy: 0.00001)
            XCTAssertEqual(t.logicalPoint(display).y, point.y, accuracy: 0.00001)
        }
    }
    func testPreviewDragConvertsZoomedTranslationAndClampsToTargetEdges() throws {
        let bounds = CGRect(x: 0, y: 0, width: 360, height: 720)
        for zoom in [0.25, 0.5, 1, 2, 4] {
            let transform = CanvasTransform(bounds: bounds, viewport: CGSize(width: 420, height: 300), zoom: zoom)
            let moved = try XCTUnwrap(transform.draggedPoint(from: CGPoint(x: 73, y: 118),
                by: CGSize(width: 28 * zoom, height: -16 * zoom)))
            XCTAssertEqual(moved, CGPoint(x: 101, y: 102))
            XCTAssertEqual(transform.draggedPoint(from: moved, by: CGSize(width: 10000, height: 10000)), CGPoint(x: 359, y: 719))
            XCTAssertEqual(transform.draggedPoint(from: moved, by: CGSize(width: -10000, height: -10000)), .zero)
        }
        let desktop = CanvasTransform(bounds: CGRect(x: -1000, y: -300, width: 1800, height: 1100),
                                      viewport: CGSize(width: 400, height: 300), zoom: 0.5)
        XCTAssertEqual(desktop.draggedPoint(from: CGPoint(x: -800, y: -150), by: CGSize(width: 25, height: -10)), CGPoint(x: -750, y: -170))
        XCTAssertNil(desktop.draggedPoint(from: .zero, by: CGSize(width: CGFloat.nan, height: 0)))
    }
    func testWindowMovementFollowsButResizeStops() throws {
        let size = CGSize(width: 800, height: 600)
        let local = CGPoint(x: 120, y: 85)
        let original = try Coordinates.windowPoint(local, frame: CGRect(x: 50, y: 100, width: 800, height: 600), initialSize: size)
        let moved = try Coordinates.windowPoint(local, frame: CGRect(x: -900, y: 400, width: 800, height: 600), initialSize: size)
        XCTAssertEqual(original, CGPoint(x: 170, y: 185))
        XCTAssertEqual(moved, CGPoint(x: -780, y: 485))
        XCTAssertThrowsError(try Coordinates.windowPoint(local, frame: CGRect(x: 50, y: 100, width: 900, height: 600), initialSize: size))
    }
    func testBoundsExcludeRightBottomAndNonFiniteCoordinates() {
        let size = CGSize(width: 100, height: 100)
        XCTAssertTrue(Coordinates.contains(.zero, size: size))
        XCTAssertTrue(Coordinates.contains(CGPoint(x: 99.9, y: 99.9), size: size))
        for point in [CGPoint(x: 100, y: 10), CGPoint(x: 0, y: 100), CGPoint(x: -1, y: 5), CGPoint(x: CGFloat.nan, y: 2)] {
            XCTAssertFalse(Coordinates.contains(point, size: size))
        }
    }
    func testMultipleDisplaysAndGap() {
        let displays = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: -1200, y: 200, width: 1000, height: 800)]
        XCTAssertTrue(Coordinates.isOnDisplay(CGPoint(x: -1000, y: 400), displays: displays))
        XCTAssertFalse(Coordinates.isOnDisplay(CGPoint(x: -100, y: 400), displays: displays))
        XCTAssertEqual(Coordinates.quartzPoint(fromAppKit: CGPoint(x: -500, y: 100), mainDisplayHeight: 800), CGPoint(x: -500, y: 700))
    }
    func testValidationAndCountsIgnoreDisabledPoints() throws {
        var plan = ClickPlan()
        plan.points = [ClickPoint(name: "A", count: 2), ClickPoint(name: "B", count: 3), ClickPoint(name: "C", count: 10, enabled: false)]
        plan.rounds = 3
        try plan.validateForRun()
        XCTAssertEqual(plan.activePoints.map(\.name), ["A", "B"])
        XCTAssertEqual(plan.totalClicks, 15)
        plan.repeatForever = true
        XCTAssertNil(plan.totalClicks)
        plan.points.forEach { XCTAssertEqual($0.interval, 0.5) }
    }

    func testMixedPlanRoundTripsWithoutTurningLegacyClicksIntoDrags() throws {
        var plan = ClickPlan()
        let click = ClickPoint(name: "点击", x: 40, y: 60, count: 2)
        plan.points = [click]
        let legacyData = try JSONEncoder().encode(plan)
        let legacy = try JSONDecoder().decode(ClickPlan.self, from: legacyData)
        XCTAssertEqual(legacy.version, 1)
        XCTAssertNil(legacy.points.first?.drag)

        let end = CGPoint(x: 20, y: 100)
        let swipe = ClickPoint(name: "拖动", x: 120, y: 40, count: 3, drag: DragMotion(end: end, duration: 0.3))
        plan.points.append(swipe)
        XCTAssertEqual(plan.version, 2)
        XCTAssertEqual(plan.totalClicks, 5)
        let restored = try JSONDecoder().decode(ClickPlan.self, from: JSONEncoder().encode(plan))
        try restored.validateForRun()
        XCTAssertEqual(restored.points, [click, swipe])
        XCTAssertEqual(DragMotion.position(from: swipe.position, to: end, fraction: 0.5), CGPoint(x: 70, y: 70))
        XCTAssertEqual(DragMotion.position(from: swipe.position, to: end, fraction: 1), end)
        plan.points.removeLast()
        XCTAssertEqual(plan.version, 1)
    }

    func testCopyingCheckedStepsPreservesOrderParametersAndNewIdentifiers() {
        let click = ClickPoint(name: "点击", x: 20, y: 90, count: 3, interval: 0.25)
        let unchecked = ClickPoint(name: "跳过", enabled: false)
        let drag = ClickPoint(name: "拖动", x: 40, y: 60, drag: DragMotion(end: CGPoint(x: 80, y: 90), duration: 0.8))
        let ids: Set<UUID> = [drag.id, click.id]
        var plan = ClickPlan()
        plan.points = [click, unchecked, drag]
        var below = plan
        XCTAssertNotNil(below.duplicateSteps(ids, placement: .belowEach))
        XCTAssertEqual(below.points.map(\.name), ["点击", "点击 副本", "跳过", "拖动", "拖动 副本"])

        XCTAssertNotNil(plan.duplicateSteps(ids, placement: .bottom))
        XCTAssertEqual(plan.points.map(\.name), ["点击", "跳过", "拖动", "点击 副本", "拖动 副本"])
        XCTAssertEqual(Set(plan.points.map(\.id)).count, plan.points.count)
        for (original, copy) in zip([click, drag], plan.points.suffix(2)) {
            var restored = copy
            restored.id = original.id
            restored.name = original.name
            XCTAssertEqual(restored, original)
        }
    }

    func testBatchCopyRejectsOverflowWithoutPartiallyCopying() {
        var plan = ClickPlan()
        plan.points = (0..<(ClickPlan.maximumSteps - 1)).map { ClickPoint(x: Double($0)) }
        let original = plan
        XCTAssertNil(plan.duplicateSteps(Set(plan.points.prefix(2).map(\.id)), placement: .bottom))
        XCTAssertEqual(plan, original)
    }

    func testMovingStepsBeforeAndAfterOtherRows() {
        let first = ClickPoint(name: "A"), second = ClickPoint(name: "B"), third = ClickPoint(name: "C", enabled: false)
        var plan = ClickPlan()
        plan.points = [first, second, third]
        XCTAssertTrue(plan.moveStep(first.id, relativeTo: third.id, placement: .after))
        XCTAssertEqual(plan.points, [second, third, first])
        XCTAssertTrue(plan.moveStep(first.id, relativeTo: second.id, placement: .before))
        XCTAssertEqual(plan.points, [first, second, third])
        XCTAssertFalse(plan.moveStep(second.id, relativeTo: first.id, placement: .after))
        XCTAssertFalse(plan.moveStep(second.id, relativeTo: second.id, placement: .after))
        XCTAssertFalse(plan.moveStep(first.id, relativeTo: UUID(), placement: .before))
        XCTAssertEqual(plan.points, [first, second, third])
    }

    func testInvalidDragDurationAndEndpointsFailValidation() throws {
        var plan = ClickPlan()
        plan.points = [ClickPoint(x: 40, y: 60, drag: DragMotion(end: CGPoint(x: 120, y: 70)))]
        try plan.validateForRun()
        plan.points[0].drag?.duration = .nan
        XCTAssertThrowsError(try plan.validate())
        plan.points[0].drag?.duration = 0.01
        XCTAssertThrowsError(try plan.validate())
        plan.points[0].drag?.duration = 0.5
        plan.points[0].drag?.endX = .infinity
        XCTAssertThrowsError(try plan.validate())
        plan.points[0].drag = DragMotion(end: plan.points[0].position)
        XCTAssertThrowsError(try plan.validate())
    }

    func testDragMustStayOnDisplaysAlongTheEntirePath() {
        let left = CGRect(x: -100, y: 0, width: 100, height: 100)
        let right = CGRect(x: 0, y: 0, width: 100, height: 100)
        let start = CGPoint(x: 50, y: 20), end = CGPoint(x: -50, y: 80)
        XCTAssertTrue(Coordinates.dragIsOnDisplays(from: start, to: end, displays: [left, right]))
        XCTAssertFalse(Coordinates.dragIsOnDisplays(from: start, to: end, displays: [left.offsetBy(dx: -1, dy: 0), right]))
        XCTAssertFalse(Coordinates.dragIsOnDisplays(from: start, to: CGPoint(x: -101, y: 80), displays: [left, right]))
        XCTAssertTrue(Coordinates.dragIsOnDisplays(from: start, to: CGPoint(x: 90, y: 20), displays: [right]))
    }
    func testInvalidImportedPlansAreRejected() {
        var plan = ClickPlan()
        XCTAssertThrowsError(try plan.validateForRun())
        plan.points = [ClickPoint()]
        plan.points[0].interval = 0
        XCTAssertThrowsError(try plan.validate())
        plan.points[0].interval = 0.05
        plan.mode = .background
        XCTAssertThrowsError(try plan.validate())
        plan.windowCoordinates = true
        XCTAssertNoThrow(try plan.validate())
        plan.points.append(plan.points[0])
        XCTAssertThrowsError(try plan.validate())
        plan.points.removeLast()
        plan.version = 99
        XCTAssertThrowsError(try plan.validate())
    }
    func testCorruptAndNonFiniteFieldsFailInsteadOfOverwriting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanStore(url: dir.appendingPathComponent("plan.json"))
        var plan = ClickPlan(); plan.points = [ClickPoint(name: "保存测试", x: 40, y: 60)]
        try store.save(plan)
        XCTAssertEqual(try store.load(), plan)
        let validData = try Data(contentsOf: store.url)
        plan.points[0].x = .nan
        XCTAssertThrowsError(try store.save(plan))
        XCTAssertEqual(try Data(contentsOf: store.url), validData)
        try Data("{broken".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
    }
    func testExtremeDraftValuesDoNotOverflowSummary() {
        var plan = ClickPlan()
        plan.points = [ClickPoint(count: Int.max), ClickPoint(count: Int.max)]
        plan.rounds = Int.max
        XCTAssertEqual(plan.totalClicks, Int.max)
        XCTAssertThrowsError(try plan.validate())
    }
}
