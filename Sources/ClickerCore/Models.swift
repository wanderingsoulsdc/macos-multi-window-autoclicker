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
}

public struct ClickPoint: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var x: Double
    public var y: Double
    public var count: Int
    public var interval: Double
    public var enabled: Bool
    public init(id: UUID = UUID(), name: String = "", x: Double = 0, y: Double = 0,
                count: Int = 1, interval: Double = 0.5, enabled: Bool = true) {
        self.id = id; self.name = name; self.x = x; self.y = y
        self.count = count; self.interval = interval; self.enabled = enabled
    }
    public var position: CGPoint { CGPoint(x: x, y: y) }
}

public struct TargetHint: Codable, Equatable {
    public var owner: String
    public var title: String
    public var bundleID: String?
    public init(owner: String, title: String, bundleID: String?) {
        self.owner = owner; self.title = title; self.bundleID = bundleID
    }
}

public struct ClickPlan: Codable, Equatable {
    public var version = 1
    public var name = "我的点击方案"
    public var windowCoordinates = false
    public var targetHint: TargetHint?
    public var points: [ClickPoint] = []
    public var mode: ClickMode = .foreground
    public var rounds = 1
    public var repeatForever = false
    public var startDelay: Double = 3
    public init() {}
    public var activePoints: [ClickPoint] { points.filter(\.enabled) }
    public var clicksPerRound: Int {
        activePoints.reduce(0) { partial, point in
            let sum = partial.addingReportingOverflow(max(0, point.count))
            return sum.overflow ? Int.max : sum.partialValue
        }
    }
    public var totalClicks: Int? {
        guard !repeatForever else { return nil }
        let product = clicksPerRound.multipliedReportingOverflow(by: max(0, rounds))
        return product.overflow ? Int.max : product.partialValue
    }

    public func validate() throws {
        guard version == 1 else { throw PlanError.message("这个方案的文件版本暂不支持。") }
        guard points.count <= 500 else { throw PlanError.message("一个方案最多包含 500 个点击点。") }
        guard Set(points.map(\.id)).count == points.count else { throw PlanError.message("方案中有重复的点击点标识。") }
        guard (1...999_999).contains(rounds), startDelay.isFinite, (0...60).contains(startDelay) else {
            throw PlanError.message("轮数应为 1～999999，开始倒计时应为 0～60 秒。")
        }
        for (index, point) in points.enumerated() {
            guard point.x.isFinite, point.y.isFinite, abs(point.x) <= 1_000_000, abs(point.y) <= 1_000_000 else {
                throw PlanError.message("第 \(index + 1) 个点的坐标无效。")
            }
            guard (1...999_999).contains(point.count), point.interval.isFinite, (0.05...3600).contains(point.interval) else {
                throw PlanError.message("第 \(index + 1) 个点的次数应为 1～999999，等待时间应为 0.05～3600 秒。")
            }
        }
        guard windowCoordinates || mode == .foreground else {
            throw PlanError.message("屏幕模式需要选择前台点击。后台点击需要指定窗口。")
        }
    }

    public func validateForRun() throws {
        try validate()
        guard !activePoints.isEmpty else { throw PlanError.message("请先添加并启用至少一个点击点。") }
    }
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
}
