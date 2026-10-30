import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var workspace: WorkspaceModel?
    var showMainWindow: (() -> Void)?
    func applicationWillTerminate(_ notification: Notification) { workspace?.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow?()
        return true
    }
}

@main
struct ClickerApp: App {
    @StateObject private var model = WorkspaceModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    init() {
        if CommandLine.arguments.contains("--diagnose-target") {
            TargetDiagnostics.printSavedTarget()
            exit(0)
        }
    }
    var body: some Scene {
        Window("Mac多窗口连点器", id: "main") {
            MainWindowContent(model: model, delegate: delegate)
        }
        .defaultSize(width: 1180, height: 790)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建窗口标签") { model.newPlan() }.keyboardShortcut("n")
                Button("导入方案…") { model.importPlan() }.keyboardShortcut("o")
                Button("导出方案…") { model.exportPlan() }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu("运行") {
                Button("开始") { model.start() }.disabled(model.engine.state.busy)
                Button("全部暂停 / 继续  ⌃⌘P") { model.togglePauseAll() }
                Button("全部停止  ⌃⌘Esc") { model.stopAll() }
            }
        }
    }
}

private struct MainWindowContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: WorkspaceModel
    let delegate: AppDelegate

    var body: some View {
        MainView(model: model, engine: model.engine)
            .id(model.selectedSessionID)
            .frame(minWidth: 1050, minHeight: 700)
            .tint(Color(red: 0.05, green: 0.49, blue: 0.48))
            .onAppear {
                delegate.workspace = model
                // SwiftUI recreates a closed scene by ID. The app-owned model
                // and click engine keep running while there is no window.
                let open = openWindow
                let show = { open(id: "main"); NSApp.activate() }
                model.onShowMainWindow = show
                delegate.showMainWindow = show
            }
    }
}
