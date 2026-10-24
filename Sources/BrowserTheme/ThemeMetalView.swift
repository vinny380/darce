import AppKit
import QuartzCore

/// Demand-driven native surface. Shared encoding/intermediates are main-actor
/// confined; drawable acquisition runs off-main, with one request in flight per view.
@MainActor public final class ThemeMetalView: NSView {
    private static let renderer = Result { try ThemeRenderer() }
    private struct Acquisition: @unchecked Sendable {
        let layer: CAMetalLayer
        let source: @Sendable (CAMetalLayer) -> CAMetalDrawable?
    }
    private struct Acquired: @unchecked Sendable { let drawable: CAMetalDrawable? }
    private let metal = CAMetalLayer()
    private let captureFrames: Bool
    private let drawableSource: @Sendable (CAMetalLayer) -> CAMetalDrawable?
    private var theme: ThemeLayer?
    private var submitted: ThemeFrame?
    private var scheduled = false
    private var inFlight = false
    private var retryScheduled = false
    private var retryFrame: ThemeFrame?
    private var failedAttempts = 0
    private var revision: UInt64 = 0
    public private(set) var submittedFrames = 0
    public private(set) var completedFrames = 0
    public private(set) var lastError: String?
    public private(set) var lastImage: ThemeImage?
    public var onFailure: ((String) -> Void)?
    public override var isOpaque: Bool { false }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// drawableSource is injectable for deterministic resource-failure verification.
    public init(captureFrames: Bool = false,
                drawableSource: @escaping @Sendable (CAMetalLayer) -> CAMetalDrawable? = { $0.nextDrawable() }) {
        self.captureFrames = captureFrames; self.drawableSource = drawableSource
        super.init(frame:.zero)
        wantsLayer = true; layer = metal
        metal.isOpaque = false; metal.pixelFormat = .rgba16Float
        metal.colorspace = CGColorSpace(name:CGColorSpace.extendedSRGB)
        metal.maximumDrawableCount = 3; metal.framebufferOnly = !captureFrames
        switch Self.renderer {
        case .success(let renderer): metal.device = renderer.metalDevice
        case .failure(let error): lastError = String(describing:error)
        }
    }
    required init?(coder: NSCoder) { fatalError("Use init(captureFrames:)") }

    public func update(theme: ThemeLayer) {
        if self.theme != theme { self.theme = theme; revision &+= 1 }
        schedule()
    }
    public override func layout() { super.layout(); schedule() }
    public override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); schedule() }
    public override func viewDidHide() {
        super.viewDidHide(); revision &+= 1; submitted = nil
    }
    public override func viewDidUnhide() { super.viewDidUnhide(); schedule() }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); revision &+= 1; submitted = nil; schedule()
    }
    private func schedule() {
        guard !scheduled, !retryScheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false; self.drawTheme()
        }
    }
    private func drawTheme() {
        guard !inFlight, let window, let theme, bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
              !isHiddenOrHasHiddenAncestor else { return }
        var frame = ThemeFrame(width:Int(ceil(bounds.width)),height:Int(ceil(bounds.height)),layers:[theme])
        frame.scale = Float(window.backingScaleFactor)
        guard frame != submitted else { return }
        if retryFrame != frame { retryFrame = frame; failedAttempts = 0 }
        guard failedAttempts < 3 else { return }
        let pixels = CGSize(width:CGFloat(frame.width)*window.backingScaleFactor,
                            height:CGFloat(frame.height)*window.backingScaleFactor)
        guard pixels.width <= 16384, pixels.height <= 16384, pixels.width*pixels.height <= 64*1024*1024 else {
            fail(ThemeError.invalidInput,frame:frame); return
        }
        metal.contentsScale = window.backingScaleFactor
        metal.drawableSize = pixels
        revision &+= 1
        let ticket = revision
        inFlight = true
        let request = Acquisition(layer:metal,source:drawableSource)
        DispatchQueue.global(qos:.userInitiated).async { [weak self, frame] in
            let acquired = Acquired(drawable:request.source(request.layer))
            Task { @MainActor [weak self] in self?.acquired(acquired,frame:frame,ticket:ticket) }
        }
    }
    private func acquired(_ acquired: Acquired, frame: ThemeFrame, ticket: UInt64) {
        guard revision == ticket, window != nil, !isHiddenOrHasHiddenAncestor else {
            inFlight = false; submitted = nil; schedule(); return
        }
        do {
            let renderer = try Self.renderer.get()
            guard let drawable = acquired.drawable else { throw ThemeError.gpu("No theme drawable is available") }
            try renderer.present(frame,to:drawable,capture:captureFrames) { [weak self] result in
                Task { @MainActor [weak self] in self?.completed(result,frame:frame,ticket:ticket) }
            }
            submitted = frame; submittedFrames += 1
        } catch { fail(error,frame:frame) }
    }
    private func completed(_ result: Result<ThemeImage?,ThemeError>, frame: ThemeFrame, ticket: UInt64) {
        inFlight = false
        guard revision == ticket, window != nil else { submitted = nil; schedule(); return }
        switch result {
        case .success(let image):
            completedFrames += 1; lastImage = image; lastError = nil
            failedAttempts = 0; retryFrame = nil; schedule()
        case .failure(let error): fail(error,frame:frame)
        }
    }
    private func fail(_ error: Error, frame: ThemeFrame) {
        inFlight = false; submitted = nil; retryFrame = frame
        failedAttempts += 1; lastError = String(describing:error)
        guard failedAttempts < 3 else { onFailure?(lastError!); return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline:.now() + (failedAttempts == 1 ? 0.05 : 0.2)) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false; self.schedule()
        }
    }
}
