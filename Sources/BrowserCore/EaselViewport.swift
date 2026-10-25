import CoreGraphics

/// Where the Easel's infinite canvas is looking: canvas point p appears on screen at p × scale + offset.
public struct EaselViewport: Equatable, Sendable {
    public static let minScale: CGFloat = 0.1
    public static let maxScale: CGFloat = 8

    public private(set) var scale: CGFloat
    public private(set) var offset: CGPoint

    public init(scale: CGFloat = 1, offset: CGPoint = .zero) {
        self.scale = min(Self.maxScale, max(Self.minScale, scale))
        self.offset = offset
    }

    public func toView(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale + offset.x, y: point.y * scale + offset.y)
    }

    public func toCanvas(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale)
    }

    /// Scroll/drag: the canvas follows the fingers.
    public mutating func pan(by delta: CGSize) {
        offset.x += delta.width
        offset.y += delta.height
    }

    /// Pinch or ⌘+/−: zooms while the canvas point under `anchor` stays under it.
    public mutating func zoom(by factor: CGFloat, around anchor: CGPoint) {
        let fixed = toCanvas(anchor)
        scale = min(Self.maxScale, max(Self.minScale, scale * factor))
        offset = CGPoint(x: anchor.x - fixed.x * scale, y: anchor.y - fixed.y * scale)
    }

    /// Zoom to fit: everything visible and centred, zooming out as needed but never in past 100%.
    public mutating func fit(_ content: CGRect, in view: CGSize, padding: CGFloat) {
        guard !content.isNull, view.width > padding * 2, view.height > padding * 2 else { return }
        let available = CGSize(width: view.width - padding * 2, height: view.height - padding * 2)
        scale = min(1, Self.maxScale, max(Self.minScale, min(available.width / max(content.width, 1), available.height / max(content.height, 1))))
        offset = CGPoint(x: view.width / 2 - content.midX * scale, y: view.height / 2 - content.midY * scale)
    }
}
