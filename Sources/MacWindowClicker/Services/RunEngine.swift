import AppKit
import Combine
import ApplicationServices
import ClickerCore

enum RunState: Equatable {
    case idle, scheduled, waiting, countdown, running, paused, stopping, finished, stopped, failed
    var busy: Bool { [.scheduled, .waiting, .countdown, .running, .paused, .stopping].contains(self) }
    var title: String {
        switch self {
        case .idle: return "准备就绪"
        case .scheduled: return "等待定时启动"
        case .waiting: return "等待前台任务"
        case .countdown: return "即将开始"
        case .running: return "正在运行"
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
    @Published private(set) var detail = "添加步骤，然后开始。"
    @Published private(set) var countdown: Double = 0
    @Published private(set) var scheduledDate: Date?
    @Published private(set) var logs: [RunLog] = []
    private var task: Task<Void, Never>?
    private let emitter = ClickEmitter()
    private static var windowQueues: [pid_t: ForegroundQueue] = [:]
    @Published private var dragging = false
    private var resumeState: RunState = .running
    var backgroundAvailable: Bool { emitter.backgroundAvailable }
    var statusTitle: String { state == .paused && dragging ? "本次拖动结束后暂停" : state.title }

    func note(_ message: String) {
        logs.insert(RunLog(message: message), at: 0)
        if logs.count > 100 { logs.removeLast(logs.count - 100) }
    }

    func start(plan: ClickPlan, target: WindowTarget?) {
        guard !state.busy else { return }
        let timing: LaunchTiming
        do {
            try plan.validateForRun()
            timing = try plan.launchTiming()
            guard plan.windowCoordinates == (target != nil) else { throw PlanError.message("请先选择目标窗口。") }
            if plan.mode != .foreground && !emitter.backgroundAvailable { throw PlanError.message("本系统未提供后台窗口接口，请手动选择其他模式。") }
            guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { throw PlanError.message("请先开启辅助功能权限；如果刚授权，请退出并重新打开本应用。") }
            for point in plan.activePoints { _ = try resolve(point: point, target: target, initialSize: target?.frame.size) }
        } catch { state = .failed; detail = error.localizedDescription; note(detail); return }
        let batches = plan.executionBlocks.compactMap { block -> (group: LoopGroup?, enabledIndices: [Int])? in
            let indices = block.indices.filter { plan.points[$0].enabled }
            return indices.isEmpty ? nil : (block.group, indices)
        }
        sent = 0; total = plan.totalClicks; currentRound = 0; currentPoint = nil
        let delay: TimeInterval
        switch timing {
        case .after(let seconds):
            delay = seconds
            countdown = plan.mode == .foreground ? 0 : seconds
            state = plan.mode == .foreground ? .waiting : (seconds > 0 ? .countdown : .running)
            detail = seconds > 0 ? "请准备好目标窗口。" : "正在开始。"
        case .at(let date):
            delay = 0
            scheduledDate = date
            state = .scheduled
            detail = "预约开始时间：\(date.formatted(date: .abbreviated, time: .standard))"
            note(detail)
        }
        task = Task { @MainActor [weak self] in
            guard let self = self else { return }
            let reservation = UUID()
            defer { if plan.mode == .foreground { ForegroundQueue.shared.release(reservation) } }
            do {
                try await self.checkpoint()
                if case .at(let date) = timing {
                    try await self.wait(until: date)
                    self.scheduledDate = nil
                    for point in plan.activePoints {
                        _ = try self.resolve(point: point, target: target, initialSize: target?.frame.size)
                    }
                }
                if plan.mode == .foreground {
                    self.state = .waiting
                    self.detail = "等待前台任务。"
                    try await ForegroundQueue.shared.acquire(reservation)
                    try await self.checkpoint()
                    self.countdown = delay
                    self.state = delay > 0 ? .countdown : .running
                    self.detail = "已轮到此任务，请将目标窗口置于前台。"
                }
                try await self.wait(delay, isCountdown: true)
                self.countdown = 0
                self.state = .running
                self.note("开始：\(plan.mode.title(includesDrag: plan.includesDrag))，\(plan.repeatForever ? "持续循环" : "\(plan.rounds) 轮")。")
                var round = 1
                while plan.repeatForever || round <= plan.rounds {
                    self.currentRound = round
                    for batch in batches {
                        for cycle in 1...(batch.group?.rounds ?? 1) {
                            let groupProgress = batch.group.map { " · \($0.title) \(cycle)/\($0.rounds)" } ?? ""
                            for index in batch.enabledIndices {
                                let point = plan.points[index]
                                try await self.executeStep(point, target: target, mode: plan.mode,
                                                           context: "第 \(round) 轮\(groupProgress) · \(point.displayName(at: index))")
                            }
                        }
                    }
                    round += 1
                }
                self.state = .finished
                self.detail = "已发送 \(self.sent) 次，请在目标软件中确认效果。"
                self.note(self.detail)
            } catch is CancellationError {
                self.state = .stopped
                self.detail = self.scheduledDate != nil ? "已取消预约。" : "已停止，已发送 \(self.sent) 次完整操作。"
                self.note(self.detail)
            } catch {
                self.state = .failed; self.detail = error.localizedDescription; self.note(self.detail)
            }
            self.currentPoint = nil
            self.countdown = 0
            self.scheduledDate = nil
            self.task = nil
        }
    }

    private func executeStep(_ point: ClickPoint, target: WindowTarget?, mode: ClickMode, context: String) async throws {
        for repetition in 1...point.count {
            let stepDetail = "\(context) · \(repetition)/\(point.count)"
            try await execute(point, target: target, mode: mode, stepDetail: stepDetail)
            if sent < Int.max { sent += 1 }
            if repetition == point.count { note(stepDetail + "，已发送。") }
            try await wait(point.interval)
        }
    }

    func togglePause() {
        if state == .paused { state = resumeState; note("继续运行。") }
        else if state == .running || state == .countdown || state == .waiting || state == .scheduled {
            resumeState = state
            state = .paused
            note(dragging ? "当前拖动结束后暂停。" : "已暂停。")
        }
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
    private func wait(until date: Date) async throws {
        while true {
            try await checkpoint()
            let remaining = date.timeIntervalSinceNow
            if remaining <= 0 { return }
            try await Task.sleep(for: .seconds(min(1, remaining)))
        }
    }
    private func wait(_ seconds: Double, isCountdown: Bool = false) async throws {
        var remaining = seconds
        while remaining > 0 {
            try await checkpoint()
            let start = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(nanoseconds: UInt64(min(0.05, remaining) * 1_000_000_000))
            if state != .paused { remaining -= ProcessInfo.processInfo.systemUptime - start }
            if isCountdown && ceil(countdown) != ceil(remaining) { countdown = max(0, remaining) }
        }
        try await checkpoint()
    }
    private func execute(_ point: ClickPoint, target: WindowTarget?, mode: ClickMode, stepDetail: String) async throws {
        // Two windows owned by one app share its mouse gesture handling. Complete
        // the press and release before another task can send a gesture to that app.
        while true {
            try await checkpoint()
            let reservation = UUID()
            let queue = target.map { window in
                if let existing = Self.windowQueues[window.pid] { return existing }
                let queue = ForegroundQueue()
                Self.windowQueues[window.pid] = queue
                return queue
            }
            try await queue?.acquire(reservation)
            defer {
                if let target, let queue {
                    queue.release(reservation)
                    if !queue.isOccupied { Self.windowQueues[target.pid] = nil }
                }
            }
            if state == .paused { continue }
            try Task.checkCancellation()

            let resolved = try resolve(point: point, target: target, initialSize: target?.frame.size)
            if mode == .foreground, let window = resolved.window {
                try requireForeground(window, at: resolved.position)
            }
            currentPoint = point.id
            detail = stepDetail
            if let drag = point.drag, let end = resolved.end {
                if mode == .foreground, let window = resolved.window { try requireForeground(window, at: end) }
                dragging = true
                defer { dragging = false }
                try await emitter.drag(from: resolved.position, to: end, duration: drag.duration,
                                       window: resolved.window, mode: mode) { position in
                    if let window = resolved.window {
                        guard WindowCatalog.isUnchangedDuringDrag(window) else {
                            throw PlanError.message("拖动时目标窗口移动、改变大小或消失，已松开鼠标并停止。")
                        }
                        if mode == .foreground { try self.requireForeground(window, at: position) }
                    } else if !Coordinates.isOnDisplay(position, displays: WindowCatalog.displayFrames) {
                        throw PlanError.message("拖动路径超出屏幕，已停止。")
                    }
                }
            } else {
                try await emitter.send(at: resolved.position, window: resolved.window, mode: mode)
            }
            return
        }
    }

    private func requireForeground(_ window: WindowTarget, at position: CGPoint) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid,
              WindowCatalog.isUnobstructed(window, at: position) else {
            throw PlanError.message("前台模式下，目标窗口须在前台且操作位置无遮挡。请调整后重试。")
        }
    }

    private func resolve(point: ClickPoint, target: WindowTarget?, initialSize: CGSize?) throws -> (position: CGPoint, end: CGPoint?, window: WindowTarget?) {
        if let target = target, let size = initialSize {
            let current = try WindowCatalog.resolve(target)
            let position = try Coordinates.windowPoint(point.position, frame: current.frame, initialSize: size)
            let end = try point.drag.map { try Coordinates.windowPoint($0.end, frame: current.frame, initialSize: size) }
            return (position, end, current)
        }
        let displays = WindowCatalog.displayFrames
        guard Coordinates.isOnDisplay(point.position, displays: displays) else {
            throw PlanError.message("点击点不在任何已连接屏幕内，请检查坐标。")
        }
        if let drag = point.drag, !Coordinates.dragIsOnDisplays(from: point.position, to: drag.end, displays: displays) {
            throw PlanError.message("拖动路径超出屏幕，请检查起点和终点。")
        }
        return (point.position, point.drag?.end, nil)
    }
}
