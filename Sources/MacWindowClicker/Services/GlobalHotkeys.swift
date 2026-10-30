import AppKit
import Carbon

@MainActor
final class GlobalHotkeys {
    private var stopRef: EventHotKeyRef?
    private var pauseRef: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var stopAvailable = false
    private(set) var pauseAvailable = false
    var onStop: (() -> Void)?
    var onPause: (() -> Void)?

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, data in
            guard let event = event, let data = data else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                          nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            MainActor.assumeIsolated {
                let owner = Unmanaged<GlobalHotkeys>.fromOpaque(data).takeUnretainedValue()
                if id.id == 1 { owner.onStop?() }
                if id.id == 2 { owner.onPause?() }
            }
            return noErr
        }
        let result = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType,
                                        Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { return }
        let signature = OSType(0x4D57434B)
        stopAvailable = RegisterEventHotKey(53, UInt32(cmdKey | controlKey), EventHotKeyID(signature: signature, id: 1),
                                           GetApplicationEventTarget(), 0, &stopRef) == noErr
        pauseAvailable = RegisterEventHotKey(35, UInt32(cmdKey | controlKey), EventHotKeyID(signature: signature, id: 2),
                                            GetApplicationEventTarget(), 0, &pauseRef) == noErr
    }
    deinit {
        if let ref = stopRef { UnregisterEventHotKey(ref) }
        if let ref = pauseRef { UnregisterEventHotKey(ref) }
        if let handler = handler { RemoveEventHandler(handler) }
    }
}

@MainActor
final class MenuBarControl: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var onShow: (() -> Void)?
    var onPause: (() -> Void)?
    var onStop: (() -> Void)?
    override init() {
        super.init()
        item.button?.image = NSImage(systemSymbolName: "cursorarrow.click", accessibilityDescription: "窗口点击器")
        item.button?.toolTip = "窗口点击器 · 关闭窗口后继续运行 · 右键菜单可退出"
        let menu = NSMenu()
        for (title, selector) in [("打开窗口点击器", #selector(show)), ("全部暂停 / 继续", #selector(pause)), ("全部停止  ⌃⌘Esc", #selector(stop))] {
            let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            menuItem.target = self; menu.addItem(menuItem)
        }
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出程序", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
    }
    @objc private func show() { onShow?() }
    @objc private func pause() { onPause?() }
    @objc private func stop() { onStop?() }
    @objc private func quit() { NSApp.terminate(nil) }
}
