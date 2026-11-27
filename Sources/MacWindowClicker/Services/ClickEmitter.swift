import AppKit
import ApplicationServices
import Darwin
import ClickerCore

@MainActor
final class ClickEmitter {
    private typealias WindowLocationSetter = @convention(c) (CGEvent, CGPoint) -> Void
    private let setWindowLocation: WindowLocationSetter? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation")
        .map { unsafeBitCast($0, to: WindowLocationSetter.self) }
    private static var serial = 1
    private var pendingRelease: (() -> Void)?
    var backgroundAvailable: Bool { setWindowLocation != nil }

    func send(at position: CGPoint, window: WindowTarget?, mode: ClickMode) async throws {
        let sequence = try sequence(window: window, mode: mode)
        let down = try sequence.make(.down, at: position)
        let up = try sequence.make(.up, at: position)
        pendingRelease = { sequence.post(up) }
        sequence.post(down)
        defer { releasePendingButton() }
        // Complete the click pair even when the run is cancelled.
        do { try await Task.sleep(for: .milliseconds(35)) } catch is CancellationError { }
    }

    func drag(from start: CGPoint, to end: CGPoint, duration: Double, window: WindowTarget?, mode: ClickMode,
              validate: (CGPoint) throws -> Void) async throws {
        let sequence = try sequence(window: window, mode: mode)
        let down = try sequence.make(.down, at: start)
        let up = try sequence.make(.up, at: start)
        try validate(start)
        var completed = false
        pendingRelease = {
            up.timestamp = DispatchTime.now().uptimeNanoseconds
            if mode == .foreground, !completed, let cursor = CGEvent(source: nil)?.location {
                // Release the real mouse button in place if the foreground changed.
                up.location = cursor
            }
            sequence.post(up)
        }
        sequence.post(down)
        defer { releasePendingButton() }

        let clock = ContinuousClock()
        let started = clock.now
        let frames = Int(ceil(duration * 30))
        for frame in 1...frames {
            let fraction = Double(frame) / Double(frames)
            try await clock.sleep(until: started.advanced(by: .seconds(duration * fraction)))
            try Task.checkCancellation()
            let position = DragMotion.position(from: start, to: end, fraction: fraction)
            try validate(position)
            let movement = try sequence.make(.dragged, at: position)
            sequence.locate(up, at: position)
            sequence.post(movement)
        }
        completed = true
    }

    func releasePendingButton() {
        let release = pendingRelease
        pendingRelease = nil
        release?()
    }

    private func sequence(window: WindowTarget?, mode: ClickMode) throws -> MouseSequence {
        try Task.checkCancellation()
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw PlanError.message("辅助功能权限尚未生效。请授权后退出并重新打开应用。")
        }
        if mode != .foreground && (window == nil || setWindowLocation == nil) {
            throw PlanError.message("当前系统不支持本应用的后台窗口接口，请手动选择其他模式。")
        }
        let serial = Self.serial
        Self.serial = serial == Int.max ? 1 : serial + 1
        return MouseSequence(mode: mode, window: window, serial: serial, setWindowLocation: setWindowLocation)
    }

    private struct MouseSequence {
        enum Phase {
            case down, dragged, up

            var quartz: CGEventType {
                switch self {
                case .down: return .leftMouseDown
                case .dragged: return .leftMouseDragged
                case .up: return .leftMouseUp
                }
            }

            var appKit: NSEvent.EventType {
                switch self {
                case .down: return .leftMouseDown
                case .dragged: return .leftMouseDragged
                case .up: return .leftMouseUp
                }
            }
        }

        let mode: ClickMode
        let window: WindowTarget?
        let serial: Int
        let setWindowLocation: WindowLocationSetter?
        private let source = CGEventSource(stateID: .privateState)

        func make(_ phase: Phase, at position: CGPoint) throws -> CGEvent {
            let event: CGEvent?
            if mode == .foreground {
                event = CGEvent(mouseEventSource: source, mouseType: phase.quartz,
                                mouseCursorPosition: position, mouseButton: .left)
                event?.flags = []
            } else if let window {
                let local = NSPoint(x: position.x - window.frame.minX, y: window.frame.maxY - position.y)
                let flags: NSEvent.ModifierFlags = mode == .commandBackground ? .command : []
                event = NSEvent.mouseEvent(with: phase.appKit, location: local, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(window.id),
                                           context: nil, eventNumber: serial, clickCount: 1,
                                           pressure: phase == .up ? 0 : 1)?.cgEvent
                event?.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.id))
                event?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.id))
                event?.setIntegerValueField(.mouseEventSubtype, value: 3)
            } else {
                event = nil
            }
            guard let event else { throw PlanError.message("无法创建鼠标事件。") }
            locate(event, at: position)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.setIntegerValueField(.mouseEventNumber, value: Int64(serial))
            return event
        }

        func locate(_ event: CGEvent, at position: CGPoint) {
            event.location = position
            if mode != .foreground, let window {
                setWindowLocation?(event, CGPoint(x: position.x - window.frame.minX, y: position.y - window.frame.minY))
            }
        }

        func post(_ event: CGEvent) {
            if mode == .foreground { event.post(tap: .cghidEventTap) }
            else if let window { event.postToPid(window.pid) }
        }
    }
}
