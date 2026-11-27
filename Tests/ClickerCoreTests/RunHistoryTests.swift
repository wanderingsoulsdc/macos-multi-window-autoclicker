import Foundation
import XCTest
@testable import ClickerCore

final class RunHistoryTests: XCTestCase {
    func testHistoryRestoresLatestEntriesAndCompletionAfterReopening() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let history = RunHistory(url: url)
        for index in 0..<110 { history.append(RunRecord(message: "步骤 \(index)")) }
        let finished = RunRecord(time: Date(timeIntervalSinceReferenceDate: 123), message: "已停止", closesRun: true)
        history.append(finished)

        let reopened = RunHistory(url: url).recent()
        XCTAssertEqual(reopened.count, RunHistory.visibleLimit)
        XCTAssertEqual(reopened.first, finished)
        XCTAssertEqual(reopened.last?.message, "步骤 11")
    }

    func testPartialWriteDoesNotHideCompletedRecordsOrPreventFutureWrites() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let history = RunHistory(url: url)
        history.append(RunRecord(message: "已提交"))
        RunHistory.flush()
        let file = try FileHandle(forWritingTo: url)
        try file.seekToEnd()
        try file.write(contentsOf: Data("\n{\"me".utf8))
        try file.close()
        XCTAssertEqual(RunHistory(url: url).recent().map(\.message), ["已提交"])

        history.append(RunRecord(message: "再次打开", closesRun: true))
        XCTAssertEqual(RunHistory(url: url).recent().map(\.message), ["再次打开", "已提交"])
    }

    func testHistoryCompactsWhenFileReachesSizeLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(repeating: 0x20, count: 1_048_000)
        data.append(0x0A)
        data.append(try JSONEncoder().encode(RunRecord(message: "较早的记录")))
        try data.write(to: url)
        let history = RunHistory(url: url)
        history.append(RunRecord(message: String(repeating: "A", count: 1_024)))
        XCTAssertEqual(history.recent().last?.message, "较早的记录")
        XCTAssertEqual(history.recent().count, 2)
        XCTAssertLessThan(try Data(contentsOf: url).count, 2_048)
    }
}
