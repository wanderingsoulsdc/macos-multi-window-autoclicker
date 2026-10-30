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
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
              app.bundleIdentifier == target.bundleID, app.launchDate == target.launchDate,
              let current = list().first(where: { $0.id == target.id && $0.pid == target.pid }) else {
            throw PlanError.message("目标窗口已关闭、隐藏或最小化，已停止。请重新选择窗口。")
        }
        return current
    }

    static var displayFrames: [CGRect] {
        let height = CGDisplayBounds(CGMainDisplayID()).height
        return NSScreen.screens.map { screen in
            CGRect(x: screen.frame.minX, y: height - screen.frame.maxY,
                   width: screen.frame.width, height: screen.frame.height)
        }
    }
    static var desktopFrame: CGRect { displayFrames.reduce(CGRect.null) { $0.union($1) } }

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
