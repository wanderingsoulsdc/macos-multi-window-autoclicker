import Foundation
import CoreGraphics

public enum ClickMode: String, Codable, CaseIterable, Identifiable {
    case background, commandBackground, foreground
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .background: return "后台普通点击"
        case .commandBackground: return "后台 Command 点击"
        case .foreground: return "前台点击（占用鼠标）"
        }
    }

    public func title(includesDrag: Bool) -> String {
        guard includesDrag else { return title }
        switch self {
        case .background: return "后台普通模式"
        case .commandBackground: return "后台 Command 模式"
        case .foreground: return "前台模式（占用鼠标）"
        }
    }
}

public struct DragMotion: Codable, Equatable {
    public static let durationRange = 0.1...10.0
    public var endX: Double
    public var endY: Double
    public var duration: Double

    public init(end: CGPoint, duration: Double = 0.5) {
        endX = end.x
        endY = end.y
        self.duration = duration
    }

    public var end: CGPoint { CGPoint(x: endX, y: endY) }

    public static func position(from start: CGPoint, to end: CGPoint, fraction: Double) -> CGPoint {
        if fraction >= 1 { return end }
        return CGPoint(x: start.x + (end.x - start.x) * fraction,
                       y: start.y + (end.y - start.y) * fraction)
    }
}

public struct ClickPoint: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var x: Double
    public var y: Double
    public var count: Int
    public var interval: Double
    public var enabled: Bool
    public var drag: DragMotion?
    public var groupID: UUID?
    public init(id: UUID = UUID(), name: String = "", x: Double = 0, y: Double = 0,
                count: Int = 1, interval: Double = 0.5, enabled: Bool = true, drag: DragMotion? = nil) {
        self.id = id; self.name = name; self.x = x; self.y = y
        self.count = count; self.interval = interval; self.enabled = enabled
        self.drag = drag
    }
    public var position: CGPoint { CGPoint(x: x, y: y) }
    public var kind: String { drag == nil ? "点击点" : "拖动" }
    public func displayName(at index: Int) -> String { name.isEmpty ? "\(kind) \(index + 1)" : name }
}

public struct TargetHint: Codable, Equatable {
    public var owner: String
    public var title: String
    public var bundleID: String?
    public init(owner: String, title: String, bundleID: String?) {
        self.owner = owner; self.title = title; self.bundleID = bundleID
    }
}

public enum StartMode: String, Codable, CaseIterable, Identifiable {
    case immediate, countdown, scheduled

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .immediate: return "立即启动"
        case .countdown: return "倒计时启动"
        case .scheduled: return "指定时间启动"
        }
    }
}

public struct ClickPlan: Codable, Equatable {
    public static let maximumSteps = 500
    public var version = 1
    public var name = "我的点击方案"
    public var windowCoordinates = false
    public var targetHint: TargetHint?
    public var points: [ClickPoint] = [] {
        didSet {
            let usedGroups = Set(points.compactMap(\.groupID))
            if let groupSettings {
                let remaining = groupSettings.filter { usedGroups.contains($0.id) }
                if remaining.count != groupSettings.count { self.groupSettings = remaining.isEmpty ? nil : remaining }
            }
            updateFormatVersion()
        }
    }
    public internal(set) var groupSettings: [LoopGroup]?
    public var mode: ClickMode = .foreground
    public var rounds = 1
    public var repeatForever = false
    public var startDelay: Double = 3
    // Optional so existing workspace and exported plans still decode.
    public var startModeOverride: StartMode?
    public var scheduledStart: Date?
    public init() {}
    public var startMode: StartMode {
        get { startModeOverride ?? (startDelay == 0 ? .immediate : .countdown) }
        set { startModeOverride = newValue }
    }
    public var activePoints: [ClickPoint] { points.filter(\.enabled) }
    public var includesDrag: Bool { points.contains { $0.drag != nil } }

    private mutating func updateFormatVersion() {
        guard (1...3).contains(version) else { return }
        version = points.contains { $0.groupID != nil } ? 3 : (includesDrag ? 2 : 1)
    }

    public enum DuplicatePlacement { case belowEach, bottom }
    public enum MovePlacement { case before, after }

    /// Copy a snapshot of the requested steps in execution order.
    @discardableResult
    public mutating func duplicateSteps(_ ids: Set<UUID>, placement: DuplicatePlacement) -> UUID? {
        let originals = points.enumerated().filter { ids.contains($0.element.id) }
        guard !originals.isEmpty, points.count + originals.count <= Self.maximumSteps else { return nil }
        let copies = originals.map { index, original in
            var copy = original
            copy.id = UUID()
            copy.name = original.displayName(at: index) + " 副本"
            if placement == .bottom { copy.groupID = nil }
            return copy
        }
        switch placement {
        case .belowEach:
            let insertions = Dictionary(uniqueKeysWithValues: zip(originals.map { $0.element.id }, copies))
            points = points.flatMap { original in
                if let copy = insertions[original.id] { return [original, copy] }
                return [original]
            }
        case .bottom:
            points.append(contentsOf: copies)
        }
        return copies.first?.id
    }

    @discardableResult
    public mutating func moveStep(_ id: UUID, relativeTo otherID: UUID, placement: MovePlacement) -> Bool {
        guard id != otherID, let source = moveRange(for: id), let target = moveRange(for: otherID),
              source.parent == target.parent else { return false }
        let boundary = placement == .after ? target.range.upperBound : target.range.lowerBound
        let destination = boundary - (source.range.lowerBound < boundary ? source.range.count : 0)
        guard source.range.lowerBound != destination else { return false }
        var reordered = points
        let steps = Array(reordered[source.range])
        reordered.removeSubrange(source.range)
        reordered.insert(contentsOf: steps, at: destination)
        points = reordered
        return true
    }
    public var clicksPerRound: Int {
        executionBlocks.reduce(0) { partial, block in
            let once = points[block.indices].filter(\.enabled).reduce(0) { count, point in
                let sum = count.addingReportingOverflow(max(0, point.count))
                return sum.overflow ? Int.max : sum.partialValue
            }
            let repeated = once.multipliedReportingOverflow(by: max(0, block.group?.rounds ?? 1))
            if repeated.overflow { return Int.max }
            let sum = partial.addingReportingOverflow(repeated.partialValue)
            return sum.overflow ? Int.max : sum.partialValue
        }
    }
    public var totalClicks: Int? {
        guard !repeatForever else { return nil }
        let product = clicksPerRound.multipliedReportingOverflow(by: max(0, rounds))
        return product.overflow ? Int.max : product.partialValue
    }

    public func validate() throws {
        guard version == 3 || ((version == 2 || (version == 1 && !includesDrag)) &&
                points.allSatisfy({ $0.groupID == nil }) && (groupSettings ?? []).isEmpty) else {
            throw PlanError.message("这个方案的文件版本暂不支持。")
        }
        guard points.count <= Self.maximumSteps else { throw PlanError.message("一个方案最多包含 \(Self.maximumSteps) 个步骤。") }
        guard Set(points.map(\.id)).count == points.count else { throw PlanError.message("方案中有重复的步骤标识。") }
        try validateGroups()
        guard (1...999_999).contains(rounds), startDelay.isFinite, (0...86_400).contains(startDelay) else {
            throw PlanError.message("轮数应为 1～999999，倒计时应为 0～86400 秒。")
        }
        for (index, point) in points.enumerated() {
            guard Self.validPosition(point.position) else {
                throw PlanError.message("第 \(index + 1) 步的坐标无效。")
            }
            guard (1...999_999).contains(point.count), point.interval.isFinite, (0.05...3600).contains(point.interval) else {
                throw PlanError.message("第 \(index + 1) 步的次数应为 1～999999，等待时间应为 0.05～3600 秒。")
            }
            if let drag = point.drag {
                guard Self.validPosition(drag.end), drag.end != point.position else {
                    throw PlanError.message("第 \(index + 1) 步的拖动终点无效，起点和终点须分开。")
                }
                guard DragMotion.durationRange.contains(drag.duration) else {
                    throw PlanError.message("第 \(index + 1) 步的单次拖动耗时应为 0.1～10 秒。")
                }
            }
        }
        guard windowCoordinates || mode == .foreground else {
            throw PlanError.message("屏幕模式需要选择前台点击。后台点击需要指定窗口。")
        }
    }

    private static func validPosition(_ point: CGPoint) -> Bool {
        abs(point.x) <= 1_000_000 && abs(point.y) <= 1_000_000
    }

    public func validateForRun() throws {
        try validate()
        guard !activePoints.isEmpty else { throw PlanError.message("请先添加并启用至少一个步骤。") }
    }

    public func launchTiming(now: Date = .now) throws -> LaunchTiming {
        switch startMode {
        case .immediate:
            return .after(0)
        case .countdown:
            return .after(startDelay)
        case .scheduled:
            guard let scheduledStart, scheduledStart.timeIntervalSinceReferenceDate.isFinite, scheduledStart > now else {
                throw PlanError.message("请选择一个还没到的启动时间。")
            }
            return .at(scheduledStart)
        }
    }
}

public enum LaunchTiming: Equatable {
    case after(TimeInterval)
    case at(Date)
}

public enum PlanError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

public enum Coordinates {
    public static func quartzPoint(fromAppKit point: CGPoint, mainDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: mainDisplayHeight - point.y)
    }
    public static func contains(_ point: CGPoint, size: CGSize) -> Bool {
        point.x.isFinite && point.y.isFinite && point.x >= 0 && point.y >= 0 && point.x < size.width && point.y < size.height
    }
    public static func windowPoint(_ local: CGPoint, frame: CGRect, initialSize: CGSize) throws -> CGPoint {
        guard abs(frame.width - initialSize.width) < 1, abs(frame.height - initialSize.height) < 1 else {
            throw PlanError.message("目标窗口大小发生变化（\(Int(initialSize.width))×\(Int(initialSize.height)) → \(Int(frame.width))×\(Int(frame.height))），已停止。请刷新窗口列表并检查点击点后重新开始。")
        }
        guard contains(local, size: frame.size) else { throw PlanError.message("点击点已超出目标窗口，已停止。") }
        return CGPoint(x: frame.minX + local.x, y: frame.minY + local.y)
    }
    public static func isOnDisplay(_ point: CGPoint, displays: [CGRect]) -> Bool {
        displays.contains { $0.contains(point) }
    }

    public static func dragIsOnDisplays(from start: CGPoint, to end: CGPoint, displays: [CGRect]) -> Bool {
        guard isOnDisplay(start, displays: displays), isOnDisplay(end, displays: displays) else { return false }

        // Each rectangle covers an interval of the straight path. Adjacent displays
        // may share an edge, but a gap between their intervals interrupts the path.
        let intervals: [(lower: CGFloat, upper: CGFloat)] = displays.compactMap { rect in
            var lower: CGFloat = 0
            var upper: CGFloat = 1
            for (origin, destination, minimum, maximum) in [
                (start.x, end.x, rect.minX, rect.maxX), (start.y, end.y, rect.minY, rect.maxY)
            ] {
                let delta = destination - origin
                if delta == 0 {
                    guard origin >= minimum && origin < maximum else { return nil }
                    continue
                }
                let entry = (minimum - origin) / delta
                let exit = (maximum - origin) / delta
                lower = max(lower, min(entry, exit))
                upper = min(upper, max(entry, exit))
            }
            return lower <= upper ? (lower, upper) : nil
        }.sorted { $0.lower < $1.lower }
        var covered: CGFloat = 0
        for interval in intervals {
            guard interval.lower <= covered else { return false }
            covered = max(covered, interval.upper)
            if covered >= 1 { return true }
        }
        return false
    }
}
