import AppKit
import Combine
import UniformTypeIdentifiers
import ApplicationServices
import ClickerCore

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var sessions: [WindowSession] = []
    @Published private(set) var selectedSessionID: UUID = UUID()
    @Published var pendingCloseID: UUID?
    @Published var windows: [WindowTarget] = []
    @Published var query = ""
    @Published var message: String?
    @Published var refreshing = false
    @Published var accessibility = AXIsProcessTrusted()
    @Published var eventAccess = CGPreflightPostEventAccess()
    @Published private(set) var saveLabel = "自动保存"
    var activeSession: WindowSession { sessions.first { $0.id == selectedSessionID } ?? sessions[0] }
    var plan: ClickPlan { get { activeSession.plan } set { activeSession.plan = newValue } }
    var target: WindowTarget? { get { activeSession.target } set { activeSession.target = newValue } }
    var selectedPoint: UUID? { get { activeSession.selectedPoint } set { activeSession.selectedPoint = newValue } }
    var preview: WindowPreview? { get { activeSession.preview } set { activeSession.preview = newValue } }
    var capturing: Bool { activeSession.capturing }
    var engine: RunEngine { activeSession.engine }
    var busyCount: Int { sessions.filter { $0.engine.state.busy }.count }
    var allPaused: Bool { busyCount > 0 && sessions.filter { $0.engine.state.busy }.allSatisfy { $0.engine.state == .paused } }
    var onShowMainWindow: (() -> Void)?
    let hotkeys = GlobalHotkeys()
    private let picker = PointPicker()
    private let menuBar = MenuBarControl()
    private var subscriptions: [AnyCancellable] = []
    private var saveSubscription: AnyCancellable?
    private let changes = PassthroughSubject<Void, Never>()
    private var allowAutosave = true
    private let store: WorkspaceStore

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MacWindowClicker", isDirectory: true)
        store = WorkspaceStore(url: base.appendingPathComponent("workspace.json"), legacyURL: base.appendingPathComponent("session.json"))
        do {
            let document = try store.load()
            sessions = document.sessions.map { WindowSession(saved: $0) }; selectedSessionID = document.selectedID
        } catch {
            let session = WindowSession(saved: SavedSession())
            sessions = [session]; selectedSessionID = session.id
            message = "上次的方案读取失败，原文件已保留。可导入其他方案，或新建标签。"; allowAutosave = false
        }
        observeSessions()
        saveSubscription = changes.debounce(for: .milliseconds(450), scheduler: RunLoop.main)
            .sink { [weak self] in self?.save() }
        hotkeys.onStop = { [weak self] in self?.stopAll() }
        hotkeys.onPause = { [weak self] in self?.togglePauseAll() }
        menuBar.onShow = { [weak self] in self?.onShowMainWindow?() }
        menuBar.onPause = { [weak self] in self?.togglePauseAll() }
        menuBar.onStop = { [weak self] in self?.stopAll() }
        refreshWindows()
    }
    private func observeSessions() {
        subscriptions.removeAll()
        for session in sessions {
            session.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
            session.engine.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
            session.$plan.dropFirst().sink { [weak self] _ in self?.changes.send() }.store(in: &subscriptions)
        }
    }
    private func save() {
        guard allowAutosave else { return }
        do {
            try store.save(WorkspaceDocument(sessions: sessions.map { SavedSession(id: $0.id, plan: $0.plan) }, selectedID: selectedSessionID))
            saveLabel = "已自动保存 · \(sessions.count) 个标签"
        } catch { saveLabel = "修改尚未保存" }
    }
    func selectSession(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }), id != selectedSessionID else { return }
        NSApp.keyWindow?.makeFirstResponder(nil); picker.cancel()
        selectedSessionID = id; changes.send()
    }
    func requestClose(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if session.engine.state.busy { pendingCloseID = id } else { closeSession(id) }
    }
    func confirmClose() {
        if let id = pendingCloseID { closeSession(id) }; pendingCloseID = nil
    }
    private func closeSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        picker.cancel(); sessions[index].engine.shutdown()
        sessions.remove(at: index)
        if sessions.isEmpty {
            let session = WindowSession(saved: SavedSession())
            sessions = [session]
        }
        if selectedSessionID == id { selectedSessionID = sessions[min(index, sessions.count - 1)].id }
        observeSessions(); changes.send()
    }
    func togglePauseAll() {
        let resume = allPaused
        for session in sessions where session.engine.state.busy && session.engine.state != .stopping {
            if (session.engine.state == .paused) == resume { session.engine.togglePause() }
        }
    }
    func stopAll() { picker.cancel(); for session in sessions { session.engine.stop() } }

    var filteredWindows: [WindowTarget] {
        query.isEmpty ? windows : windows.filter { ($0.owner + " " + $0.label).localizedCaseInsensitiveContains(query) }
    }
    var title: String { plan.windowCoordinates ? (target.map { $0.owner + " · " + $0.label } ?? "请选择要使用此方案的窗口") : "整个屏幕" }
    var canvasFrame: CGRect {
        if plan.windowCoordinates { return CGRect(origin: .zero, size: target?.frame.size ?? CGSize(width: 800, height: 600)) }
        let frame = WindowCatalog.desktopFrame
        return frame.isNull ? CGRect(x: 0, y: 0, width: 1280, height: 800) : frame
    }
    var canEdit: Bool { !engine.state.busy }
    var coordinateNote: String {
        plan.windowCoordinates ? "以窗口左上角为 (0, 0)，包含标题栏；单位为点。" : "以主屏幕左上角为 (0, 0)；多显示器坐标可能为负数。"
    }

    func refreshPermissions() { accessibility = AXIsProcessTrusted(); eventAccess = CGPreflightPostEventAccess() }
    func refreshWindows() {
        refreshPermissions()
        guard !refreshing else { return }
        refreshing = true
        Task { @MainActor in
            let items = await Task.detached(priority: .userInitiated) { WindowCatalog.list(includeTitles: true) }.value
            windows = items; refreshing = false
            for session in sessions where !session.engine.state.busy {
                if let previous = session.target,
                   let current = items.first(where: { $0.id == previous.id && $0.pid == previous.pid && $0.launchDate == previous.launchDate }) {
                    if previous.frame.size != current.frame.size { session.preview = nil }
                    session.target = current
                }
            }
        }
    }
    func choose(_ window: WindowTarget?) {
        NSApp.keyWindow?.makeFirstResponder(nil); picker.cancel()
        if let existing = sessions.first(where: { session in
            if let window { return session.target?.id == window.id && session.target?.pid == window.pid && session.target?.launchDate == window.launchDate }
            return !session.plan.windowCoordinates
        }) { selectSession(existing.id); return }
        if let window,
           let saved = sessions.first(where: { session in
               guard !session.engine.state.busy, session.plan.windowCoordinates, session.plan.targetHint == window.hint else { return false }
               return session.target == nil || (try? WindowCatalog.resolve(session.target!)) == nil
           }) {
            selectSession(saved.id)
        } else if !(window != nil && canEdit && plan.windowCoordinates && target == nil) {
            guard appendSession(ClickPlan()) else { return }
        }
        guard canEdit else { return }
        target = window; preview = nil
        plan.windowCoordinates = window != nil; plan.targetHint = window?.hint
        if window == nil { plan.mode = .foreground }
        else if plan.points.isEmpty && plan.mode == .foreground { plan.mode = .background }
        selectedPoint = plan.points.first?.id; changes.send()
    }
    @discardableResult private func appendSession(_ plan: ClickPlan) -> Bool {
        guard sessions.count < 30 else { message = "最多保留 30 个标签，请先关闭不需要的标签。"; return false }
        let session = WindowSession(saved: SavedSession(plan: plan))
        sessions.append(session); selectedSessionID = session.id
        observeSessions(); changes.send()
        return true
    }
    func newPlan() {
        NSApp.keyWindow?.makeFirstResponder(nil); picker.cancel()
        var blank = ClickPlan(); blank.windowCoordinates = true; blank.mode = .background
        if appendSession(blank) { allowAutosave = true; changes.send() }
    }
    func addPoint(at position: CGPoint? = nil) {
        guard canEdit, plan.points.count < 500 else { return }
        let fallback = plan.windowCoordinates ? CGPoint(x: canvasFrame.midX, y: canvasFrame.midY) : CGPoint(x: CGDisplayBounds(CGMainDisplayID()).midX, y: CGDisplayBounds(CGMainDisplayID()).midY)
        let p = position ?? fallback
        let point = ClickPoint(name: "点击点 \(plan.points.count + 1)", x: floor(p.x), y: floor(p.y))
        plan.points.append(point); selectedPoint = point.id
    }
    func removePoint(_ id: UUID) {
        guard canEdit else { return }
        plan.points.removeAll { $0.id == id }
        if selectedPoint == id { selectedPoint = plan.points.first?.id }
    }
    func movePoint(_ id: UUID, by offset: Int) {
        guard canEdit, let index = plan.points.firstIndex(where: { $0.id == id }), plan.points.indices.contains(index + offset) else { return }
        plan.points.swapAt(index, index + offset)
    }
    func duplicate(_ id: UUID) {
        guard canEdit, plan.points.count < 500, let index = plan.points.firstIndex(where: { $0.id == id }) else { return }
        var point = plan.points[index]; point.id = UUID(); point.name += " 副本"
        plan.points.insert(point, at: index + 1); selectedPoint = point.id
    }
    func pickPoint() {
        guard canEdit else { return }
        let session = activeSession
        do {
            let frame = try target.map { try WindowCatalog.resolve($0).frame }
            if plan.windowCoordinates && frame == nil { throw PlanError.message("请先选择目标窗口。") }
            picker.begin(targetFrame: frame) { [weak self] global in
                guard let self = self, self.activeSession.id == session.id, let global = global else { return }
                let point = frame.map { CGPoint(x: global.x - $0.minX, y: global.y - $0.minY) } ?? global
                self.addPoint(at: point)
            }
        } catch { message = error.localizedDescription }
    }
    func capturePreview() {
        guard let target = target, canEdit, !capturing else { return }
        let session = activeSession
        session.capturing = true
        Task { @MainActor in
            defer { session.capturing = false }
            do {
                let image = try await PreviewCapture.capture(target)
                if self.sessions.contains(where: { $0.id == session.id }), session.target?.id == target.id && session.target?.pid == target.pid {
                    let current = try WindowCatalog.resolve(target)
                    guard abs(current.frame.width - image.logicalSize.width) < 1,
                          abs(current.frame.height - image.logicalSize.height) < 1 else {
                        throw PlanError.message("截取期间窗口大小发生变化，请重新截取预览。")
                    }
                    session.target = current
                    session.preview = image; refreshWindows()
                    // Opt-in, local-only diagnostic capture. The flag is never
                    // created by normal application use.
                    let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                        .appendingPathComponent("MacWindowClicker", isDirectory: true)
                    if FileManager.default.fileExists(atPath: cache.appendingPathComponent("enable-preview-diagnostics").path),
                       let png = NSBitmapImageRep(cgImage: image.image).representation(using: .png, properties: [:]) {
                        try? png.write(to: cache.appendingPathComponent("target-preview.png"), options: .atomic)
                    }
                }
            } catch { message = error.localizedDescription }
        }
    }
    func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if AXIsProcessTrusted() && !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        refreshPermissions()
        message = "请在系统设置中为“Mac 窗口点击器”开启辅助功能权限。若已开启但仍提示未生效，请退出并重新打开本应用。"
    }
    func start() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard hotkeys.stopAvailable else { message = "紧急停止快捷键注册失败，可能被其他软件占用。请退出冲突软件后重新打开窗口点击器。"; return }
        engine.start(plan: plan, target: plan.windowCoordinates ? target : nil)
    }
    func testSelectedPoint() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard canEdit, let id = selectedPoint, var point = plan.points.first(where: { $0.id == id }) else { return }
        guard hotkeys.stopAvailable else { message = "紧急停止快捷键不可用，请重新打开应用。"; return }
        var test = plan
        point.count = 1; point.enabled = true
        test.points = [point]; test.rounds = 1; test.repeatForever = false
        engine.start(plan: test, target: plan.windowCoordinates ? target : nil)
    }
    func importPlan() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "导入点击方案；窗口方案需要重新选择一个当前窗口。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let loaded = try PlanStore(url: url).load()
            if appendSession(loaded) { allowAutosave = true; changes.send() }
        } catch { message = "导入失败：" + error.localizedDescription }
    }
    func exportPlan() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "点击方案.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try PlanStore(url: url).save(plan) }
        catch { message = "导出失败：" + error.localizedDescription }
    }
    func shutdown() { picker.cancel(); for session in sessions { session.engine.shutdown() }; save() }
}
