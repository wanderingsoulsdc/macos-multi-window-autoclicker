import Foundation

public struct SavedSession: Codable, Identifiable, Equatable {
    public var id: UUID
    public var plan: ClickPlan
    public init(id: UUID = UUID(), plan: ClickPlan = ClickPlan()) { self.id = id; self.plan = plan }
}

public struct WorkspaceDocument: Codable, Equatable {
    public var version = 1
    public var sessions: [SavedSession]
    public var selectedID: UUID
    public init(sessions: [SavedSession], selectedID: UUID) { self.sessions = sessions; self.selectedID = selectedID }
    public func validate() throws {
        guard version == 1, !sessions.isEmpty, sessions.count <= 30,
              Set(sessions.map(\.id)).count == sessions.count,
              sessions.contains(where: { $0.id == selectedID }) else { throw PlanError.message("多窗口方案格式无效，最多可保留 30 个标签。") }
        for session in sessions { try session.plan.validate() }
    }
}

public struct WorkspaceStore {
    public let url: URL
    public let legacyURL: URL
    public init(url: URL, legacyURL: URL) { self.url = url; self.legacyURL = legacyURL }
    public func load() throws -> WorkspaceDocument {
        if !FileManager.default.fileExists(atPath: url.path) {
            let plan = FileManager.default.fileExists(atPath: legacyURL.path) ? try PlanStore(url: legacyURL).load() : ClickPlan()
            let session = SavedSession(plan: plan)
            return WorkspaceDocument(sessions: [session], selectedID: session.id)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 20_000_000 else { throw PlanError.message("多窗口方案文件过大。") }
        let document = try JSONDecoder().decode(WorkspaceDocument.self, from: data)
        try document.validate()
        return document
    }
    public func save(_ document: WorkspaceDocument) throws {
        try document.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
