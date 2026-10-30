import AppKit
import ApplicationServices
import ClickerCore

enum TargetDiagnostics {
    // Read-only command line mode for diagnosing the saved target without
    // replaying any user point or changing the saved plan.
    static func printSavedTarget() {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MacWindowClicker/session.json")
        var output: [String: Any] = ["accessibility": AXIsProcessTrusted(), "postEvents": CGPreflightPostEventAccess()]
        do {
            let workspace = try WorkspaceStore(url: file.deletingLastPathComponent().appendingPathComponent("workspace.json"), legacyURL: file).load()
            let plan = workspace.sessions.first { $0.id == workspace.selectedID }!.plan
            let windows = WindowCatalog.list(includeTitles: true).filter {
                $0.bundleID == plan.targetHint?.bundleID && (plan.targetHint?.title == $0.label || $0.title.isEmpty)
            }
            output["candidates"] = windows.map { window -> [String: Any] in
                var value: [String: Any] = ["id": window.id, "pid": window.pid, "owner": window.owner,
                                          "title": window.label, "x": window.frame.minX, "y": window.frame.minY,
                                          "width": window.frame.width, "height": window.frame.height]
                value["points"] = plan.activePoints.map { point -> [String: Any] in
                    let global = CGPoint(x: window.frame.minX + point.x, y: window.frame.minY + point.y)
                    var result: [String: Any] = ["x": point.x, "y": point.y, "screenX": global.x, "screenY": global.y,
                                                 "insideWindow": Coordinates.contains(point.position, size: window.frame.size)]
                    if AXIsProcessTrusted() {
                        let app = AXUIElementCreateApplication(window.pid)
                        AXUIElementSetMessagingTimeout(app, 0.15)
                        var hit: AXUIElement?
                        let error = AXUIElementCopyElementAtPosition(app, Float(global.x), Float(global.y), &hit)
                        result["hitTestStatus"] = error.rawValue
                        if let hit = hit {
                            var role: CFTypeRef?, actions: CFArray?
                            AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &role)
                            AXUIElementCopyActionNames(hit, &actions)
                            result["role"] = role as? String ?? "unknown"
                            result["actions"] = actions as? [String] ?? []
                        }
                    }
                    return result
                }
                return value
            }
        } catch { output["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
    }
}
