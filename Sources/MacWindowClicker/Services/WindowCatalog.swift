import AppKit
import ApplicationServices
import ClickerCore

struct WindowTarget: Identifiable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    let owner: String
    let title: String
    let bundleID: String?
    let launchDate: Date?
    let frame: CGRect
    var label: String { title.isEmpty ? "窗口 \(id)" : title }
    var hint: TargetHint { TargetHint(owner: owner, title: label, bundleID: bundleID) }
}

enum WindowLookupError: LocalizedError {
    case applicationEnded, applicationChanged, applicationHidden
    case unavailable, missing(CGWindowID), offScreen(CGWindowID), invalidWindow(CGWindowID)

    var canRetry: Bool {
        switch self {
        case .unavailable, .missing, .offScreen, .invalidWindow: return true
        case .applicationEnded, .applicationChanged, .applicationHidden: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .applicationEnded: return "目标应用已退出。"
        case .applicationChanged: return "目标应用进程已更换，请重新选择窗口。"
        case .applicationHidden: return "macOS 报告目标应用处于隐藏状态。"
        case .unavailable: return "macOS 暂时未返回窗口状态。"
        case .missing(let id): return "找不到原目标窗口（编号 \(id)）。窗口可能已关闭或重新创建，请重新选择。"
        case .offScreen(let id): return "macOS 未确认目标窗口（编号 \(id)）在当前屏幕上。"
        case .invalidWindow(let id): return "原目标窗口（编号 \(id)）的大小或显示状态暂时不适合操作。"
        }
    }
}

enum WindowCatalog {
    static func list(includeOwn: Bool = false, includeTitles: Bool = false) -> [WindowTarget] {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var titles: [pid_t: [(CGRect, String)]] = [:]
        return rows.compactMap { row in
            guard let id = row[kCGWindowNumber as String] as? UInt32,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  includeOwn || pid != ProcessInfo.processInfo.processIdentifier,
                  row[kCGWindowLayer as String] as? Int == 0,
                  let dict = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: dict as CFDictionary), frame.width >= 60, frame.height >= 40,
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            var title = row[kCGWindowName as String] as? String ?? ""
            if includeTitles && title.isEmpty && AXIsProcessTrusted() {
                if titles[pid] == nil { titles[pid] = accessibleTitles(pid: pid) }
                let matches = (titles[pid] ?? []).filter {
                    abs($0.0.minX - frame.minX) < 2 && abs($0.0.minY - frame.minY) < 2 &&
                    abs($0.0.width - frame.width) < 2 && abs($0.0.height - frame.height) < 2
                }
                if matches.count == 1 { title = matches[0].1 }
            }
            return WindowTarget(id: id, pid: pid,
                                owner: row[kCGWindowOwnerName as String] as? String ?? app?.localizedName ?? "应用",
                                title: title,
                                bundleID: app?.bundleIdentifier, launchDate: app?.launchDate, frame: frame)
        }
    }

    private static func accessibleTitles(pid: pid_t) -> [(CGRect, String)] {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.08)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows) == .success,
              let elements = windows as? [AXUIElement] else { return [] }
        return elements.compactMap { element in
            AXUIElementSetMessagingTimeout(element, 0.08)
            var name: CFTypeRef?, position: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &name) == .success,
                  let title = name as? String, !title.isEmpty,
                  AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
                  let position = position, let size = size,
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, dimensions = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
            return (CGRect(origin: point, size: dimensions), title)
        }
    }

    static func resolve(_ target: WindowTarget) throws -> WindowTarget {
        try resolve(target, confirmInScreenList: true)
    }

    private static func resolve(_ target: WindowTarget, confirmInScreenList: Bool) throws -> WindowTarget {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else {
            throw WindowLookupError.applicationEnded
        }
        guard app.bundleIdentifier == target.bundleID, app.launchDate == target.launchDate else {
            throw WindowLookupError.applicationChanged
        }
        guard !app.isHidden else { throw WindowLookupError.applicationHidden }
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, target.id) as? [[String: Any]] else {
            throw WindowLookupError.unavailable
        }
        guard let row = rows.first(where: { $0[kCGWindowNumber as String] as? UInt32 == target.id }) else {
            throw WindowLookupError.missing(target.id)
        }
        guard row[kCGWindowOwnerPID as String] as? Int32 == target.pid else {
            throw WindowLookupError.applicationChanged
        }
        let onScreenFlag = row[kCGWindowIsOnscreen as String] as? Bool
        guard onScreenFlag != false else { throw WindowLookupError.offScreen(target.id) }
        if confirmInScreenList || onScreenFlag == nil {
            // A state transition can leave the per-window snapshot behind the current list.
            guard let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
                throw WindowLookupError.unavailable
            }
            guard onScreen.contains(where: {
                $0[kCGWindowNumber as String] as? UInt32 == target.id && $0[kCGWindowOwnerPID as String] as? Int32 == target.pid
            }) else { throw WindowLookupError.offScreen(target.id) }
        }
        guard row[kCGWindowLayer as String] as? Int == 0, (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let bounds = row[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              frame.width.isFinite, frame.height.isFinite, frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width >= 60, frame.height >= 40 else {
            throw WindowLookupError.invalidWindow(target.id)
        }
        return WindowTarget(id: target.id, pid: target.pid, owner: target.owner, title: target.title,
                            bundleID: target.bundleID, launchDate: target.launchDate, frame: frame)
    }

    static var displayFrames: [CGRect] {
        let height = CGDisplayBounds(CGMainDisplayID()).height
        return NSScreen.screens.map { screen in
            CGRect(x: screen.frame.minX, y: height - screen.frame.maxY,
                   width: screen.frame.width, height: screen.frame.height)
        }
    }
    static var desktopFrame: CGRect { displayFrames.reduce(CGRect.null) { $0.union($1) } }

    static func requireUnchangedDuringDrag(_ target: WindowTarget) throws {
        let current: WindowTarget
        do { current = try resolve(target, confirmInScreenList: false) }
        catch { throw PlanError.message("拖动检查已中止 · \(error.localizedDescription)") }
        guard current.frame.size == target.frame.size else {
            throw PlanError.message("拖动中目标窗口大小发生变化，已中止。")
        }
        guard current.frame.origin == target.frame.origin else {
            throw PlanError.message("拖动中目标窗口位置发生变化，已中止。")
        }
    }

    static func isUnobstructed(_ target: WindowTarget, at point: CGPoint) -> Bool {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for row in rows {
            guard let dict = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: dict as CFDictionary), frame.contains(point),
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            return row[kCGWindowNumber as String] as? UInt32 == target.id
        }
        return false
    }
}
