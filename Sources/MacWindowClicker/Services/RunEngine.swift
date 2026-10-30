import AppKit
import Combine
import ApplicationServices
import ClickerCore

enum RunState: Equatable {
    case idle, waiting, countdown, running, paused, stopping, finished, stopped, failed
    var busy: Bool { [.waiting, .countdown, .running, .paused, .stopping].contains(self) }
    var title: String {
        switch self {
        case .idle: return "准备就绪"
        case .waiting: return "等待前台任务"
        case .countdown: return "即将开始"
        case .running: return "正在点击"
        case .paused: return "已暂停"
        case .stopping: return "正在停止"
        case .finished: return "发送已结束"
        case .stopped: return "已停止"
        case .failed: return "运行已中止"
        }
    }
}

struct RunLog: Identifiable {
    let id = UUID()
    let time = Date()
    let message: String
}

@MainActor
final class RunEngine: ObservableObject {
    @Published private(set) var state: RunState = .idle
    @Published private(set) var sent = 0
    @Published private(set) var total: Int?
    @Published private(set) var currentRound = 0
    @Published private(set) var currentPoint: UUID?
    @Published private(set) var detail = "添加点击点，然后开始。"
    @Published private(set) var countdown: Double = 0
    @Published private(set) var logs: [RunLog] = []
    private var task: Task<Void, Never>?
    private let emitter = ClickEmitter()
    private var resumeState: RunState = .running
    var backgroundAvailable: Bool { emitter.backgroundAvailable }

    func note(_ message: String) {
        logs.insert(RunLog(message: message), at: 0)
        if logs.count > 100 { logs.removeLast(logs.count - 100) }
    }

    func start(plan: ClickPlan, target: WindowTarget?) {
        guard !state.busy else { return }
        do {
            try plan.validateForRun()
            guard plan.windowCoordinates == (target != nil) else { throw PlanError.message("请先选择当前要点击的窗口。") }
            if plan.mode != .foreground && !emitter.backgroundAvailable { throw PlanError.message("本系统未提供后台窗口接口，请手动选择其他模式。") }
            guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { throw PlanError.message("请先开启辅助功能权限；如果刚授权，请退出并重新打开本应用。") }
            for point in plan.activePoints { _ = try resolve(point: point, target: target, initialSize: target?.frame.size) }
        } catch { state = .failed; detail = error.localizedDescription; note(detail); return }
        sent = 0; total = plan.totalClicks; currentRound = 0; currentPoint = nil
        countdown = plan.startDelay; state = plan.mode == .foreground ? .waiting : (plan.startDelay > 0 ? .countdown : .running)
        detail = plan.startDelay > 0 ? "请准备好目标窗口。" : "正在开始。"
        note("开始：\(plan.mode.title)，\(plan.repeatForever ? "持续循环" : "\(plan.rounds) 轮")。")
        task = Task { @MainActor [weak self] in
            guard let self = self else { return }
            let reservation = UUID()
            defer { if plan.mode == .foreground { ForegroundQueue.shared.release(reservation) } }
            do {
                if plan.mode == .foreground {
                    self.detail = "前台任务按顺序执行，轮到后开始倒计时。"
                    try await ForegroundQueue.shared.acquire(reservation)
                    try await self.checkpoint()
                    self.state = plan.startDelay > 0 ? .countdown : .running
                    self.detail = "已轮到此任务，请将目标窗口置于前台。"
                }
                try await self.wait(plan.startDelay, isCountdown: true)
                self.state = .running
                var round = 1
                while plan.repeatForever || round <= plan.rounds {
                    self.currentRound = round
                    for (index, point) in plan.activePoints.enumerated() {
                        for repetition in 1...point.count {
                            try await self.checkpoint()
                            let resolved = try self.resolve(point: point, target: target, initialSize: target?.frame.size)
                            if plan.mode == .foreground, let window = resolved.window {
                                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid,
                                      WindowCatalog.isUnobstructed(window, at: resolved.position) else {
                                    throw PlanError.message("前台模式下，目标窗口需要在前台且点击位置未被遮挡。请调整后重新开始。")
                                }
                            }
                            self.currentPoint = point.id
                            self.detail = "第 \(round) 轮 · \(point.name.isEmpty ? "点击点 \(index + 1)" : point.name) · \(repetition)/\(point.count)"
                            try await self.emitter.send(at: resolved.position, window: resolved.window, mode: plan.mode)
                            self.sent += 1
                            if repetition == point.count { self.note(self.detail + "，已发送。") }
                            try await self.wait(point.interval)
                        }
                    }
                    round += 1
                }
                self.state = .finished
                self.detail = "已发送 \(self.sent) 次，尚未确认窗口是否响应。无反应时请手动更换点击方式。"
                self.note(self.detail)
            } catch is CancellationError {
                self.state = .stopped; self.detail = "已停止，共发送 \(self.sent) 次点击。"; self.note(self.detail)
            } catch {
                self.state = .failed; self.detail = error.localizedDescription; self.note(self.detail)
            }
            self.currentPoint = nil; self.task = nil
        }
    }

    func togglePause() {
        if state == .paused { state = resumeState; note("继续运行。") }
        else if state == .running || state == .countdown || state == .waiting { resumeState = state; state = .paused; note("已暂停。") }
    }
    func stop() {
        guard state.busy else { return }
        state = .stopping
        task?.cancel()
    }
    func shutdown() { stop(); emitter.releasePendingButton() }
    private func checkpoint() async throws {
        try Task.checkCancellation()
        while state == .paused { try await Task.sleep(nanoseconds: 50_000_000) }
        try Task.checkCancellation()
    }
    private func wait(_ seconds: Double, isCountdown: Bool = false) async throws {
        var remaining = seconds
        while remaining > 0 {
            try await checkpoint()
            let start = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(nanoseconds: UInt64(min(0.05, remaining) * 1_000_000_000))
            if state != .paused { remaining -= ProcessInfo.processInfo.systemUptime - start }
            if isCountdown { countdown = max(0, remaining) }
        }
        try await checkpoint()
    }
    private func resolve(point: ClickPoint, target: WindowTarget?, initialSize: CGSize?) throws -> (position: CGPoint, window: WindowTarget?) {
        if let target = target, let size = initialSize {
            let current = try WindowCatalog.resolve(target)
            let position = try Coordinates.windowPoint(point.position, frame: current.frame, initialSize: size)
            return (position, current)
        }
        guard Coordinates.isOnDisplay(point.position, displays: WindowCatalog.displayFrames) else {
            throw PlanError.message("点击点不在任何已连接屏幕内，请检查坐标。")
        }
        return (point.position, nil)
    }
}
