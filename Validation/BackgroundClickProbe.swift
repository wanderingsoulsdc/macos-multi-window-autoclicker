import AppKit
import ApplicationServices
import Darwin

// Experimental compatibility API. Resolve optionally; never fall back to a global click.
typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
let setWindowLocation: SetWindowLocation? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation")
    .map { unsafeBitCast($0, to: SetWindowLocation.self) }

// A disposable test target and controller. Never sends clicks to other apps.
let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resultDirectory = workspace.appendingPathComponent("Validation/results", isDirectory: true)
try? FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
let targetStateURL: URL = {
    if let index = CommandLine.arguments.firstIndex(of: "--state"), CommandLine.arguments.indices.contains(index + 1) {
        return URL(fileURLWithPath: CommandLine.arguments[index + 1])
    }
    return resultDirectory.appendingPathComponent("target.json")
}()
let reportURL = resultDirectory.appendingPathComponent("report.json")

func writeJSON(_ value: [String: Any], to url: URL) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: url, options: .atomic)
    }
}

func readTarget() -> [String: Any] {
    guard let data = try? Data(contentsOf: targetStateURL),
          let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return result
}

func permissions() -> [String: Any] {
    ["accessibility": AXIsProcessTrusted(), "postEvents": CGPreflightPostEventAccess(),
     "screenCapture": CGPreflightScreenCaptureAccess(),
     "system": ProcessInfo.processInfo.operatingSystemVersionString,
     "displays": NSScreen.screens.count]
}

@MainActor
final class TestView: NSView {
    var firstClick = false
    var received: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { firstClick }
    override func mouseDown(with event: NSEvent) { received?() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        let text = firstClick ? "自绘区域：接受首次点击" : "自绘区域：默认首次点击行为"
        (text as NSString).draw(at: NSPoint(x: 12, y: 22), withAttributes: [.foregroundColor: NSColor.labelColor])
    }
}

@MainActor
final class Target: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var events: [[String: Any]] = []
    var controls: [(String, NSView)] = []
    var rawEvents: [[String: Any]] = []
    var selfCheckPassed = false
    var eventMonitor: Any?
    var commandTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 100, y: 180, width: 430, height: 300),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "后台点击验证 · 测试靶窗口"
        if let index = CommandLine.arguments.firstIndex(of: "--name"), CommandLine.arguments.indices.contains(index + 1) {
            window.title = CommandLine.arguments[index + 1]
        }
        window.isReleasedWhenClosed = false
        let button = NSButton(title: "标准按钮", target: self, action: #selector(pressed))
        button.frame = NSRect(x: 40, y: 215, width: 350, height: 45)
        button.setAccessibilityIdentifier("probe-button")
        window.contentView!.addSubview(button)
        controls.append(("standardButton", button))
        for (index, accepts) in [false, true].enumerated() {
            let view = TestView(frame: NSRect(x: 40, y: 120 - index * 85, width: 350, height: 65))
            view.firstClick = accepts
            let name = accepts ? "acceptingView" : "defaultView"
            view.received = { [weak self] in self?.record(name) }
            window.contentView!.addSubview(view)
            controls.append((name, view))
        }
        // Show the target without activating it or taking the controller's focus.
        window.orderFrontRegardless()
        // Confirm that the recorder and each handler work independently of transport.
        button.performClick(nil)
        for (_, view) in controls {
            if let view = view as? TestView { view.received?() }
        }
        selfCheckPassed = Set(events.compactMap { $0["control"] as? String }) == Set(controls.map { $0.0 })
        events.removeAll()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self = self else { return event }
            self.rawEvents.append(["type": event.type.rawValue, "window": event.windowNumber,
                                   "x": event.locationInWindow.x, "y": event.locationInWindow.y,
                                   "flags": event.modifierFlags.rawValue])
            self.publish()
            return event
        }
        publish()
        if let index = CommandLine.arguments.firstIndex(of: "--commands"), CommandLine.arguments.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            commandTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self = self, let data = try? Data(contentsOf: url),
                          let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                    try? FileManager.default.removeItem(at: url)
                    switch command["action"] as? String {
                    case "move": self.window.setFrameOrigin(NSPoint(x: command["x"] as? Double ?? 100, y: command["y"] as? Double ?? 180))
                    case "resize": self.window.setContentSize(NSSize(width: 500, height: 300))
                    case "close": self.window.orderOut(nil); self.window.close()
                    default: break
                    }
                    self.publish()
                }
            }
        }
    }

    @objc func pressed() { record("standardButton") }
    func record(_ name: String) {
        events.append(["control": name, "time": Date().timeIntervalSince1970,
                       "targetActive": NSApp.isActive, "windowKey": window.isKeyWindow])
        publish()
    }
    func publish() {
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let points: [[String: Any]] = controls.map { name, view in
            let local = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let global = window.convertPoint(toScreen: local)
            return ["control": name, "x": global.x, "y": mainHeight - global.y,
                    "windowTopX": local.x, "windowTopY": window.frame.height - local.y,
                    "localX": local.x, "localY": local.y]
        }
        writeJSON(["pid": ProcessInfo.processInfo.processIdentifier, "window": window.windowNumber,
                   "frontPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                   "frontBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown",
                   "selfCheckPassed": selfCheckPassed, "rawEvents": rawEvents,
                   "points": points, "events": events], to: targetStateURL)
    }
}

@MainActor
final class Controller: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var output: NSTextView!
    var runButton: NSButton!
    var targetProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 590, y: 180, width: 620, height: 470),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Mac多窗口连点器 · 可行性验证"
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        let title = NSTextField(labelWithString: "验证后台点击是否收到、鼠标是否移动、焦点是否改变")
        title.frame = NSRect(x: 20, y: 425, width: 580, height: 25)
        content.addSubview(title)
        let access = NSButton(title: "1. 授予辅助功能权限", target: self, action: #selector(requestAccess))
        access.frame = NSRect(x: 20, y: 377, width: 220, height: 34)
        content.addSubview(access)
        runButton = NSButton(title: "2. 运行自有窗口测试", target: self, action: #selector(run))
        runButton.frame = NSRect(x: 260, y: 377, width: 220, height: 34)
        content.addSubview(runButton)
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 580, height: 340))
        scroll.hasVerticalScroller = true
        output = NSTextView(frame: scroll.bounds)
        output.isEditable = false
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        scroll.documentView = output
        content.addSubview(scroll)
        log("此工具只向自己创建的测试窗口发送事件。\n测试时可让其他软件保持前台，不会主动激活靶窗口。\n测试期间请暂时保持鼠标不动，以便测量。\n")
        showPermissions()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func log(_ text: String) { output.string += text + "\n"; output.scrollToEndOfDocument(nil) }
    func showPermissions() {
        log("辅助功能：\(AXIsProcessTrusted() ? "已授权" : "未授权")；事件发送：\(CGPreflightPostEventAccess() ? "已授权" : "未授权")")
    }
    @objc func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        log("请在系统设置中为“后台点击验证”开启辅助功能权限，然后返回运行测试。")
    }

    @objc func run() {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            showPermissions()
            log("尚未发送任何点击。请先授权；必要时退出并重新打开本工具。")
            writeJSON(["status": "blocked_by_permissions", "permissions": permissions(), "trials": []], to: reportURL)
            return
        }
        runButton.isEnabled = false
        writeJSON(["status": "running", "permissions": permissions(), "trials": []], to: reportURL)
        Task { @MainActor in
            defer { runButton.isEnabled = true; targetProcess?.terminate(); targetProcess = nil }
            try? FileManager.default.removeItem(at: targetStateURL)
            let process = Process()
            process.executableURL = Bundle.main.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("ProbeTarget.app/Contents/MacOS/ProbeTarget")
            process.arguments = ["--target"]
            do { try process.run() } catch {
                log("无法启动靶窗口：\(error.localizedDescription)")
                writeJSON(["status": "target_launch_failed", "permissions": permissions(), "trials": []], to: reportURL)
                return
            }
            targetProcess = process
            for _ in 0..<40 {
                let state = readTarget()
                if state["pid"] as? Int == Int(process.processIdentifier), state["selfCheckPassed"] as? Bool == true { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let initial = readTarget()
            guard initial["pid"] as? Int == Int(process.processIdentifier),
                  initial["selfCheckPassed"] as? Bool == true,
                  let windowID = initial["window"] as? Int,
                  let points = initial["points"] as? [[String: Any]] else {
                log("靶窗口未就绪，未发送点击。")
                writeJSON(["status": "target_not_ready", "permissions": permissions(), "trials": []], to: reportURL)
                return
            }
            let originalFrame = window.frame
            var trials: [[String: Any]] = []
            for covered in [false, true] {
                if covered {
                    // Cover only the tool's own target, with the controller's own window.
                    window.setFrame(NSRect(x: 80, y: 160, width: 620, height: 470), display: true)
                }
                for point in points {
                    let name = point["control"] as! String
                    for route in ["quartzToPID", "appKitToPID", "windowLocalToPID", "windowLocalCommandToPID"] {
                        if route.hasPrefix("windowLocal"), setWindowLocation == nil {
                            log("本系统没有窗口坐标接口，跳过 \(route)。")
                            continue
                        }
                        guard process.isRunning else {
                            log("靶窗口已关闭，测试中止。")
                            window.setFrame(originalFrame, display: true)
                            writeJSON(["status": "target_closed", "permissions": permissions(), "trials": trials], to: reportURL)
                            return
                        }
                        window.orderFrontRegardless()
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
                        guard frontBefore != process.processIdentifier, frontBefore != -1 else {
                            log("靶窗口正处于前台或无法读取前台状态，无法验证后台点击，已停止。")
                            window.setFrame(originalFrame, display: true)
                            writeJSON(["status": "interrupted", "permissions": permissions(), "trials": trials], to: reportURL)
                            return
                        }
                        let before = (readTarget()["events"] as? [[String: Any]] ?? []).count
                        let rawBefore = (readTarget()["rawEvents"] as? [[String: Any]] ?? []).count
                        let cursorBefore = CGEvent(source: nil)?.location ?? .zero
                        let location = CGPoint(x: point["x"] as! Double, y: point["y"] as! Double)
                        for type: CGEventType in [.leftMouseDown, .leftMouseUp] {
                            var event: CGEvent?
                            if route == "quartzToPID" {
                                event = CGEvent(mouseEventSource: CGEventSource(stateID: .privateState),
                                                mouseType: type, mouseCursorPosition: location, mouseButton: .left)
                            } else {
                                event = NSEvent.mouseEvent(with: type == .leftMouseDown ? .leftMouseDown : .leftMouseUp,
                                    location: NSPoint(x: point["localX"] as! Double, y: point["localY"] as! Double),
                                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: windowID, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)?.cgEvent
                                event?.location = location
                            }
                            event?.setIntegerValueField(.mouseEventClickState, value: 1)
                            event?.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
                            event?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
                            if route.hasPrefix("windowLocal"), let event = event {
                                setWindowLocation?(event, CGPoint(x: point["windowTopX"] as! Double,
                                                                 y: point["windowTopY"] as! Double))
                                event.setIntegerValueField(.mouseEventSubtype, value: 3)
                            }
                            if route == "windowLocalCommandToPID" { event?.flags = .maskCommand }
                            event?.postToPid(process.processIdentifier)
                            try? await Task.sleep(nanoseconds: 60_000_000)
                        }
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        let added = Array((readTarget()["events"] as? [[String: Any]] ?? []).dropFirst(before))
                        let rawAdded = Array((readTarget()["rawEvents"] as? [[String: Any]] ?? []).dropFirst(rawBefore))
                        let cursorAfter = CGEvent(source: nil)?.location ?? .zero
                        let frontAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
                        let received = added.filter { $0["control"] as? String == name }.count
                        let stable = cursorBefore == cursorAfter
                        let focusStable = frontBefore == frontAfter
                        trials.append(["control": name, "route": route, "covered": covered,
                                       "receivedCount": received, "unexpectedEvents": added.count - received,
                                       "cursorUnchanged": stable, "foregroundUnchanged": focusStable,
                                       "foregroundBefore": frontBefore, "foregroundAfter": frontAfter,
                                       "events": added, "rawEvents": rawAdded])
                        log("\(covered ? "遮挡" : "可见") / \(name) / \(route)：触发 \(received)，原始事件 \(rawAdded.count)，鼠标\(stable ? "未变" : "变化")，前台\(focusStable ? "未变" : "变化")")
                        if !focusStable {
                            window.setFrame(originalFrame, display: true)
                            log("前台应用在本次点击期间改变，停止后续测试。")
                            writeJSON(["status": "stopped_focus_changed", "permissions": permissions(), "trials": trials], to: reportURL)
                            return
                        }
                    }
                }
            }
            window.setFrame(originalFrame, display: true)
            writeJSON(["status": "completed", "permissions": permissions(), "trials": trials,
                       "scope": "Self-owned AppKit target only; no third-party compatibility claim"], to: reportURL)
            log("测试结束。结果：Validation/results/report.json\n本结果仅代表自有 AppKit 靶窗口，不代表所有软件。")
        }
    }

    func applicationWillTerminate(_ notification: Notification) { targetProcess?.terminate() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

if CommandLine.arguments.contains("--inspect") {
    let snapshot = permissions()
    let status = AXIsProcessTrusted() && CGPreflightPostEventAccess() ? "ready_not_run" : "blocked_by_permissions"
    writeJSON(["status": status, "permissions": snapshot, "trials": []], to: reportURL)
    let data = try! JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
} else {
    MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let menu = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "退出后台点击验证", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    menu.addItem(appItem)
    app.mainMenu = menu
    let delegate: NSApplicationDelegate = CommandLine.arguments.contains("--target") ? Target() : Controller()
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
    }
}
