import Combine
import ClickerCore
import Foundation

@MainActor
final class WindowSession: ObservableObject, Identifiable {
    let id: UUID
    @Published var plan: ClickPlan
    @Published var target: WindowTarget?
    @Published var selectedPoint: UUID?
    @Published var preview: WindowPreview?
    @Published var capturing = false
    let engine = RunEngine()
    init(saved: SavedSession) {
        id = saved.id; plan = saved.plan; selectedPoint = saved.plan.points.first?.id
    }
    var label: String {
        guard plan.windowCoordinates else { return "整个屏幕" }
        if let target { return target.label }
        return plan.targetHint?.title.isEmpty == false ? plan.targetHint!.title : "待绑定窗口"
    }
    var subtitle: String {
        if engine.state.busy { return "\(engine.state.title) · \(engine.sent)\(engine.total.map { "/\($0)" } ?? "")" }
        if plan.windowCoordinates && target == nil { return "请选择窗口重新绑定" }
        return engine.state == .idle ? "\(plan.points.count) 个点击点" : "\(engine.state.title) · \(engine.sent) 次"
    }
}
