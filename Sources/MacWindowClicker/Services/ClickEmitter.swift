import AppKit
import ApplicationServices
import Darwin
import ClickerCore

@MainActor
final class ClickEmitter {
    private typealias WindowLocationSetter = @convention(c) (CGEvent, CGPoint) -> Void
    private let setWindowLocation: WindowLocationSetter? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation")
        .map { unsafeBitCast($0, to: WindowLocationSetter.self) }
    private var serial = 1
    private var pendingRelease: (() -> Void)?
    var backgroundAvailable: Bool { setWindowLocation != nil }

    func send(at position: CGPoint, window: WindowTarget?, mode: ClickMode) async throws {
        try Task.checkCancellation()
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw PlanError.message("辅助功能权限尚未生效。请授权后退出并重新打开应用。")
        }
        let down: CGEvent
        let up: CGEvent
        if mode == .foreground {
            guard let d = CGEvent(mouseEventSource: CGEventSource(stateID: .privateState), mouseType: .leftMouseDown,
                                  mouseCursorPosition: position, mouseButton: .left),
                  let u = CGEvent(mouseEventSource: CGEventSource(stateID: .privateState), mouseType: .leftMouseUp,
                                  mouseCursorPosition: position, mouseButton: .left) else {
                throw PlanError.message("无法创建鼠标事件。")
            }
            down = d; up = u
            down.flags = []; up.flags = []
        } else {
            guard let target = window, let setter = setWindowLocation else {
                throw PlanError.message("当前系统不支持本应用的后台点击接口，请手动选择其他模式。")
            }
            let local = CGPoint(x: position.x - target.frame.minX, y: position.y - target.frame.minY)
            let appKitLocal = NSPoint(x: local.x, y: target.frame.height - local.y)
            let flags: NSEvent.ModifierFlags = mode == .commandBackground ? .command : []
            guard let d = NSEvent.mouseEvent(with: .leftMouseDown, location: appKitLocal, modifierFlags: flags,
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(target.id),
                                            context: nil, eventNumber: serial, clickCount: 1, pressure: 1)?.cgEvent,
                  let u = NSEvent.mouseEvent(with: .leftMouseUp, location: appKitLocal, modifierFlags: flags,
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(target.id),
                                            context: nil, eventNumber: serial, clickCount: 1, pressure: 0)?.cgEvent else {
                throw PlanError.message("无法创建窗口鼠标事件。")
            }
            serial = serial == Int.max ? 1 : serial + 1
            down = d; up = u
            for event in [down, up] {
                event.location = position
                setter(event, local)
                event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.id))
                event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.id))
                event.setIntegerValueField(.mouseEventSubtype, value: 3)
            }
        }
        for event in [down, up] { event.setIntegerValueField(.mouseEventClickState, value: 1) }
        let pid = window?.pid
        func post(_ event: CGEvent) {
            if mode == .foreground { event.post(tap: .cghidEventTap) }
            else if let pid = pid { event.postToPid(pid) }
        }
        pendingRelease = { post(up) }
        post(down)
        defer { releasePendingButton() }
        // Cancellation must release the button before the engine permits a new run.
        // Once down has been sent, finish the pair and let the caller count it.
        // Its next cancellation checkpoint stops further clicks.
        do { try await Task.sleep(nanoseconds: 35_000_000) } catch is CancellationError { }
    }
    func releasePendingButton() { let release = pendingRelease; pendingRelease = nil; release?() }
}
