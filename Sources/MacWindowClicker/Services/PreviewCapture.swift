import AppKit
import ScreenCaptureKit
import ClickerCore

struct WindowPreview {
    let image: CGImage
    let logicalSize: CGSize
}

enum PreviewCapture {
    static func capture(_ target: WindowTarget) async throws -> WindowPreview {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw PlanError.message("窗口预览需要屏幕录制权限。请在系统设置中允许后重新打开应用；也可以直接在屏幕上取点。")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == target.id && $0.owningApplication?.processID == target.pid }) else {
            throw PlanError.message("无法找到目标窗口，请刷新窗口列表。")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let size = filter.contentRect.size
        let scale: CGFloat = min(max(1, CGFloat(filter.pointPixelScale)), 3000 / max(1, max(size.width, size.height)))
        config.width = max(1, Int((size.width * scale).rounded()))
        config.height = max(1, Int((size.height * scale).rounded()))
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.destinationRect = CGRect(x: 0, y: 0, width: config.width, height: config.height)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return WindowPreview(image: image, logicalSize: window.frame.size)
    }
}
