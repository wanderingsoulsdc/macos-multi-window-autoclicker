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
    /// A preview drag uses display-point translation; persist rounded logical
    /// coordinates and keep right/bottom edges strictly inside the target.
    public func draggedPoint(from origin: CGPoint, by translation: CGSize) -> CGPoint? {
        guard origin.x.isFinite, origin.y.isFinite,
              translation.width.isFinite, translation.height.isFinite,
              !bounds.isNull, !bounds.isInfinite, bounds.width > 0, bounds.height > 0 else { return nil }
        let logical = CGPoint(x: origin.x + translation.width / scale,
                              y: origin.y + translation.height / scale)
        guard logical.x.isFinite, logical.y.isFinite else { return nil }
        return CGPoint(x: min(max(logical.x.rounded(), bounds.minX), max(bounds.minX, floor(bounds.maxX.nextDown))),
                       y: min(max(logical.y.rounded(), bounds.minY), max(bounds.minY, floor(bounds.maxY.nextDown))))
    }

}
