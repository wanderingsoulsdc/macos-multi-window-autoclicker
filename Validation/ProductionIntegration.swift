import AppKit
import ApplicationServices
import ClickerCore

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
private let resultDir = root.appendingPathComponent("Validation/results")
private let targetURL = resultDir.appendingPathComponent("target.json")
private let commandURL = resultDir.appendingPathComponent("target-command.json")
private let reportURL = resultDir.appendingPathComponent("production-integration.json")

private func json(_ url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return value
}
private func save(_ value: [String: Any], to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url, options: .atomic) }
}

@MainActor
final class IntegrationController: NSObject, NSApplicationDelegate {
    let engine = RunEngine()
    let secondEngine = RunEngine()
    var secondProcess: Process?
    var process: Process?
    var checks: [[String: Any]] = []
    var observations: [String: Any] = [:]
    var window: NSWindow!
    var label: NSTextField!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 650, y: 200, width: 440, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "正式版 · 自有窗口集成测试"
        window.isReleasedWhenClosed = false
        label = NSTextField(wrappingLabelWithString: "正在检查正式版的点击次数、顺序、暂停、停止、窗口移动和失效处理。只点击自有靶窗口。")
        label.frame = NSRect(x: 25, y: 35, width: 390, height: 110)
        window.contentView?.addSubview(label); window.orderFrontRegardless()
        Task { @MainActor in await run() }
    }
    func require(_ condition: Bool, _ text: String) throws {
        checks.append(["check": text, "passed": condition])
        label.stringValue = text + (condition ? "：通过" : "：失败")
        guard condition else { throw PlanError.message(text) }
    }
    func wait(timeout: Double = 6, until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw PlanError.message("等待测试状态超时：\(engine.detail)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    func spawn() async throws -> WindowTarget {
        if let process = process, process.isRunning { process.terminate(); try await Task.sleep(nanoseconds: 100_000_000) }
        try? FileManager.default.removeItem(at: targetURL)
        try? FileManager.default.removeItem(at: commandURL)
        let child = Process()
        child.executableURL = root.appendingPathComponent("Validation/build/ProbeTarget.app/Contents/MacOS/ProbeTarget")
        child.arguments = ["--target", "--commands", commandURL.path]
        try child.run(); process = child
        try await wait { json(targetURL)["pid"] as? Int == Int(child.processIdentifier) && json(targetURL)["selfCheckPassed"] as? Bool == true }
        try await Task.sleep(nanoseconds: 500_000_000)
        guard let target = WindowCatalog.list().first(where: { $0.pid == child.processIdentifier }) else { throw PlanError.message("找不到集成测试靶窗口。") }
        return target
    }
    func point(_ name: String, target: WindowTarget, count: Int = 1, stateURL: URL = targetURL) throws -> ClickPoint {
        let data = json(stateURL)
        guard let row = (data["points"] as? [[String: Any]])?.first(where: { $0["control"] as? String == name }),
              let x = row["windowTopX"] as? Double, let y = row["windowTopY"] as? Double else { throw PlanError.message("缺少测试坐标。") }
        return ClickPoint(name: name, x: x, y: y, count: count, interval: 0.12)
    }
    var actions: [String] { (json(targetURL)["events"] as? [[String: Any]] ?? []).compactMap { $0["control"] as? String } }
    func run() async {
        do {
            try require(AXIsProcessTrusted() && CGPreflightPostEventAccess(), "验证工具权限已就绪")
            var target = try await spawn()
            let beforeCursor = CGEvent(source: nil)?.location
            let beforeFront = NSWorkspace.shared.frontmostApplication?.processIdentifier
            var plan = ClickPlan(); plan.windowCoordinates = true; plan.mode = .background; plan.startDelay = 0; plan.rounds = 2
            plan.points = [try point("standardButton", target: target, count: 2), try point("acceptingView", target: target)]
            var disabled = try point("defaultView", target: target); disabled.enabled = false; plan.points.append(disabled)
            engine.start(plan: plan, target: target)
            try await wait { !engine.state.busy }
            try require(engine.state == .finished && engine.sent == 6, "两轮计划精确发送六次")
            try require(actions == ["standardButton", "standardButton", "acceptingView", "standardButton", "standardButton", "acceptingView"], "真实控件收到正确顺序和次数，跳过禁用点")
            observations["cursorSnapshotUnchanged"] = CGEvent(source: nil)?.location == beforeCursor
            observations["foregroundSnapshotUnchanged"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == beforeFront
            observations["note"] = "Snapshots are observations only; concurrent user activity can change pointer or foreground."

            let previousActions = actions.count
            var commandPlan = plan
            commandPlan.rounds = 1; commandPlan.mode = .commandBackground
            commandPlan.points = [try point("defaultView", target: target, count: 2)]
            engine.start(plan: commandPlan, target: target)
            try await wait { !engine.state.busy }
            try require(engine.state == .finished && engine.sent == 2 && Array(actions.dropFirst(previousActions)) == ["defaultView", "defaultView"], "显式 Command 模式收到两次特殊点击")

            let secondaryURL = resultDir.appendingPathComponent("secondary-target.json")
            try? FileManager.default.removeItem(at: secondaryURL)
            let child = Process()
            child.executableURL = root.appendingPathComponent("Validation/build/ProbeTarget.app/Contents/MacOS/ProbeTarget")
            child.arguments = ["--target", "--state", secondaryURL.path]
            try child.run(); secondProcess = child
            try await wait { json(secondaryURL)["pid"] as? Int == Int(child.processIdentifier) && json(secondaryURL)["selfCheckPassed"] as? Bool == true }
            guard let otherTarget = WindowCatalog.list().first(where: { $0.pid == child.processIdentifier }) else { throw PlanError.message("缺少第二个靶窗口") }
            var parallel = plan; parallel.rounds = 1; parallel.repeatForever = true
            parallel.points = [try point("standardButton", target: target)]
            var otherPlan = parallel
            otherPlan.points = [try point("standardButton", target: otherTarget, stateURL: secondaryURL)]
            let firstActions = actions.count
            engine.start(plan: parallel, target: target)
            secondEngine.start(plan: otherPlan, target: otherTarget)
            try await wait { engine.sent >= 3 && secondEngine.sent >= 3 }
            try require(engine.state.busy && secondEngine.state.busy && actions.count >= firstActions + 3 && (json(secondaryURL)["events"] as? [[String: Any]] ?? []).count >= 3, "两个真实窗口同时收到各自后台点击")
            engine.togglePause()
            try await Task.sleep(nanoseconds: 80_000_000)
            let firstPaused = engine.sent, secondBefore = secondEngine.sent
            try await wait { secondEngine.sent >= secondBefore + 2 }
            try require(engine.sent == firstPaused && engine.state == .paused, "暂停一个窗口不影响另一个窗口")
            engine.togglePause(); secondEngine.togglePause()
            engine.togglePause() // Both are now paused, as with the workspace's all-pause action.
            try await Task.sleep(nanoseconds: 100_000_000)
            let firstAllPaused = engine.sent, secondAllPaused = secondEngine.sent
            try await Task.sleep(nanoseconds: 250_000_000)
            try require(engine.sent == firstAllPaused && secondEngine.sent == secondAllPaused, "多任务暂停后均不再点击")
            engine.stop(); secondEngine.stop()
            try await wait { !engine.state.busy && !secondEngine.state.busy }
            try require(engine.state == .stopped && secondEngine.state == .stopped, "多个运行器可同时停止并释放按键")
            secondProcess?.terminate(); secondProcess = nil

            plan.rounds = 1; plan.repeatForever = true; plan.points = [try point("standardButton", target: target)]
            engine.start(plan: plan, target: target)
            try await wait { engine.sent >= 1 }
            engine.togglePause(); try await Task.sleep(nanoseconds: 80_000_000)
            let pausedSent = engine.sent, pausedActions = actions.count
            try await Task.sleep(nanoseconds: 300_000_000)
            try require(engine.state == .paused && engine.sent == pausedSent && actions.count == pausedActions, "暂停后不继续发送或触发点击")
            engine.togglePause(); try await wait { engine.sent > pausedSent }
            engine.stop(); try await wait { !engine.state.busy }
            let stoppedActions = actions.count
            try await Task.sleep(nanoseconds: 250_000_000)
            try require(engine.state == .stopped && actions.count == stoppedActions, "继续后可停止，停止后不再点击")

            target = try await spawn()
            plan.repeatForever = false; plan.points = [try point("standardButton", target: target, count: 4)]
            engine.start(plan: plan, target: target)
            try await wait { engine.sent >= 1 }
            save(["action": "move", "x": 240, "y": 240], to: commandURL)
            try await wait { !engine.state.busy }
            try require(engine.state == .finished && engine.sent == 4 && actions.count == 4, "窗口移动后仍点中原控件")

            plan.repeatForever = true; plan.points = [try point("standardButton", target: target)]
            engine.start(plan: plan, target: target)
            try await wait { engine.sent >= 1 }
            save(["action": "resize"], to: commandURL)
            try await wait { !engine.state.busy }
            try require(engine.state == .failed && engine.detail.contains("大小"), "窗口尺寸改变会停止")

            target = try await spawn()
            plan.points = [try point("standardButton", target: target)]
            engine.start(plan: plan, target: target)
            try await wait { engine.sent >= 1 }
            save(["action": "close"], to: commandURL)
            try await wait { !engine.state.busy }
            // macOS can shrink a closing window before removing it from the list;
            // stopping on that size change is also the required safe outcome.
            try require(engine.state == .failed && (engine.detail.contains("关闭") || engine.detail.contains("大小")), "窗口关闭或进入关闭动画后停止")
            save(["status": "passed", "checks": checks, "observations": observations], to: reportURL)
            label.stringValue = "正式版核心集成测试全部通过。\n结果：Validation/results/production-integration.json"
        } catch {
            engine.shutdown(); secondEngine.shutdown()
            save(["status": "failed", "error": error.localizedDescription, "checks": checks, "observations": observations, "engine": engine.detail], to: reportURL)
            label.stringValue = "测试中止：" + error.localizedDescription
        }
        process?.terminate(); process = nil; secondProcess?.terminate(); secondProcess = nil
    }
    func applicationWillTerminate(_ notification: Notification) { engine.shutdown(); secondEngine.shutdown(); process?.terminate(); secondProcess?.terminate() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ProductionIntegration {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let controller = IntegrationController(); app.delegate = controller
        app.run(); withExtendedLifetime(controller) {}
    }
}
