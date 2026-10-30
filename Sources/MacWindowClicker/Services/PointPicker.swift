import AppKit
import ClickerCore

@MainActor
final class PointPicker {
    private var windows: [NSWindow] = []
    private var completion: ((CGPoint?) -> Void)?
    func begin(targetFrame: CGRect?, completion: @escaping (CGPoint?) -> Void) {
        cancel()
        self.completion = completion
        for screen in NSScreen.screens {
            let window = PickerWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            window.isOpaque = false; window.backgroundColor = .clear
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.target = targetFrame
            view.screenOrigin = screen.frame.origin
            view.chosen = { [weak self] in self?.finish($0) }
            window.contentView = view
            window.acceptsMouseMovedEvents = true
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            windows.append(window)
        }
        NSCursor.crosshair.set()
    }
    func cancel() { if !windows.isEmpty { finish(nil) } }
    private func finish(_ point: CGPoint?) {
        let callback = completion; completion = nil
        windows.forEach { $0.orderOut(nil); $0.close() }; windows.removeAll()
        NSCursor.arrow.set()
        callback?(point)
    }
}

private final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class PickerView: NSView {
    var target: CGRect?
    var screenOrigin: CGPoint = .zero
    var chosen: ((CGPoint?) -> Void)?
    private var cursor: CGPoint?
    private var invalid = false
    private var pendingPoint: CGPoint?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) { cursor = event.locationInWindow; needsDisplay = true; NSCursor.crosshair.set() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { chosen?(nil) } }
    override func rightMouseUp(with event: NSEvent) { chosen?(nil) }
    override func mouseDown(with event: NSEvent) {
        let globalNS = CGPoint(x: screenOrigin.x + event.locationInWindow.x, y: screenOrigin.y + event.locationInWindow.y)
        let global = Coordinates.quartzPoint(fromAppKit: globalNS, mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
        if let target = target, !target.contains(global) { pendingPoint = nil; invalid = true; needsDisplay = true; return }
        pendingPoint = global
    }
    override func mouseUp(with event: NSEvent) { if let point = pendingPoint { pendingPoint = nil; chosen?(point) } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.16).setFill(); bounds.fill()
        if let target = target {
            let height = CGDisplayBounds(CGMainDisplayID()).height
            let local = CGRect(x: target.minX - screenOrigin.x, y: height - target.maxY - screenOrigin.y,
                               width: target.width, height: target.height)
            NSColor.systemTeal.setStroke()
            let path = NSBezierPath(rect: local.insetBy(dx: 1, dy: 1)); path.lineWidth = 3; path.stroke()
        }
        let text = invalid ? "请在青色边框内取点 · Esc 取消" : "单击设置点击点 · Esc 或右键取消"
        let font = NSFont.systemFont(ofSize: 18, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let panel = CGRect(x: bounds.midX - size.width / 2 - 22, y: bounds.maxY - 105, width: size.width + 44, height: 50)
        NSColor.black.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect: panel, xRadius: 12, yRadius: 12).fill()
        (text as NSString).draw(at: CGPoint(x: panel.minX + 22, y: panel.minY + 14), withAttributes: attributes)
        if let cursor = cursor {
            NSColor.white.withAlphaComponent(0.65).setStroke()
            let lines = NSBezierPath()
            lines.move(to: CGPoint(x: 0, y: cursor.y)); lines.line(to: CGPoint(x: bounds.width, y: cursor.y))
            lines.move(to: CGPoint(x: cursor.x, y: 0)); lines.line(to: CGPoint(x: cursor.x, y: bounds.height))
            lines.lineWidth = 0.5; lines.stroke()
        }
    }
}
