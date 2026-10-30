import Foundation
import CoreGraphics

/// Use exactly the same transform for preview pixels, markers, and hit testing.
public struct CanvasTransform {
    public let bounds: CGRect
    public let scale: CGFloat
    public var size: CGSize { CGSize(width: bounds.width * scale, height: bounds.height * scale) }
    public init(bounds: CGRect, viewport: CGSize, zoom: Double = 0) {
        self.bounds = bounds
        let fit = min(max(1, viewport.width - 24) / max(1, bounds.width), max(1, viewport.height - 24) / max(1, bounds.height))
        scale = zoom.isFinite && zoom > 0 ? CGFloat(min(8, max(0.05, zoom))) : max(0.0001, fit)
    }
    public func displayedPoint(_ logical: CGPoint) -> CGPoint {
        CGPoint(x: (logical.x - bounds.minX) * scale, y: (logical.y - bounds.minY) * scale)
    }
    public func logicalPoint(_ displayed: CGPoint) -> CGPoint {
        CGPoint(x: displayed.x / scale + bounds.minX, y: displayed.y / scale + bounds.minY)
    }
}
