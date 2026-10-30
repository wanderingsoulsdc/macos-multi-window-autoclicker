import XCTest
import CoreGraphics
@testable import ClickerCore

final class ClickerCoreTests: XCTestCase {
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
