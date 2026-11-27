import Foundation

public struct LoopGroup: Codable, Identifiable, Equatable {
    public static let roundRange = 1...999_999
    public let id: UUID
    public var name: String
    public var rounds: Int

    public init(id: UUID = UUID(), name: String = "循环组", rounds: Int = 2) {
        self.id = id
        self.name = name
        self.rounds = rounds
    }

    public var title: String { name.isEmpty ? "循环组" : name }
}

public struct ExecutionBlock: Identifiable {
    public let id: UUID
    public let group: LoopGroup?
    public let indices: Range<Int>
}

extension ClickPlan {
    public var executionBlocks: [ExecutionBlock] {
        let settings = (groupSettings ?? []).reduce(into: [UUID: LoopGroup]()) { $0[$1.id] = $1 }
        var blocks: [ExecutionBlock] = []
        var start = points.startIndex
        while start < points.endIndex {
            let group = points[start].groupID.flatMap { settings[$0] }
            var end = start + 1
            if let group {
                while end < points.endIndex && points[end].groupID == group.id { end += 1 }
            }
            blocks.append(ExecutionBlock(id: group?.id ?? points[start].id, group: group, indices: start..<end))
            start = end
        }
        return blocks
    }

    public func groupEndChoices(startingAt id: UUID) -> [Int] {
        guard let start = points.firstIndex(where: { $0.id == id }), points[start].groupID == nil else { return [] }
        return Array(points.indices.dropFirst(start + 1).prefix { points[$0].groupID == nil })
    }

    @discardableResult
    public mutating func createGroup(start: UUID, end: UUID, name: String, rounds: Int) throws -> UUID {
        guard let first = points.firstIndex(where: { $0.id == start }),
              let last = points.firstIndex(where: { $0.id == end }), groupEndChoices(startingAt: start).contains(last) else {
            throw PlanError.message("请选择至少两条连续、未分组的步骤。")
        }
        try Self.validateGroupRounds(rounds)
        let group = LoopGroup(name: name, rounds: rounds)
        groupSettings = (groupSettings ?? []) + [group]
        var updated = points
        for index in first...last { updated[index].groupID = group.id }
        points = updated
        return group.id
    }

    public mutating func editGroup(_ id: UUID, name: String, rounds: Int) throws {
        try Self.validateGroupRounds(rounds)
        guard let index = groupSettings?.firstIndex(where: { $0.id == id }) else { return }
        groupSettings?[index].name = name
        groupSettings?[index].rounds = rounds
    }

    public mutating func ungroup(_ id: UUID) {
        points = points.map { original in
            var point = original
            if point.groupID == id { point.groupID = nil }
            return point
        }
    }

    func moveRange(for id: UUID) -> (range: Range<Int>, parent: UUID?)? {
        if let index = points.firstIndex(where: { $0.id == id }) {
            return (index..<(index + 1), points[index].groupID)
        }
        return executionBlocks.first(where: { $0.id == id && $0.group != nil }).map { ($0.indices, nil) }
    }

    func validateGroups() throws {
        let groups = groupSettings ?? []
        let declared = Set(groups.map(\.id))
        let referenced = Set(points.compactMap(\.groupID))
        let groupedBlocks = executionBlocks.compactMap { $0.group?.id }
        guard declared.count == groups.count, declared == referenced, declared.count == groupedBlocks.count,
              declared.isDisjoint(with: points.map(\.id)) else {
            throw PlanError.message("循环组的数据无效，组内步骤必须连续。")
        }
        for group in groups { try Self.validateGroupRounds(group.rounds) }
    }

    private static func validateGroupRounds(_ rounds: Int) throws {
        guard LoopGroup.roundRange.contains(rounds) else { throw PlanError.message("循环次数应为 1～999999。") }
    }
}
