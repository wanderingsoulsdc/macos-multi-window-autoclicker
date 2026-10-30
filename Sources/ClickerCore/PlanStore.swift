import Foundation

public struct PlanStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> ClickPlan {
        let data = try Data(contentsOf: url)
        guard data.count <= 2_000_000 else { throw PlanError.message("方案文件过大，请选择小于 2 MB 的方案。") }
        let plan = try JSONDecoder().decode(ClickPlan.self, from: data)
        try plan.validate()
        return plan
    }
    public func save(_ plan: ClickPlan) throws {
        try plan.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(plan)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
