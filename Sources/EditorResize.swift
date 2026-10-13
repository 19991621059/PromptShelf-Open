import AppKit

// Borderless panels do not expose a standard title-bar resize affordance.
// Eight small edge targets leave the text/selection area to NSTextView.
final class EditorResizeView: NSView {
    enum Edge: CaseIterable {
        case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
        var left: Bool { [.left, .topLeft, .bottomLeft].contains(self) }
        var right: Bool { [.right, .topRight, .bottomRight].contains(self) }
        var top: Bool { [.top, .topLeft, .topRight].contains(self) }
        var bottom: Bool { [.bottom, .bottomLeft, .bottomRight].contains(self) }
    }
    let edge: Edge
    var changed: ((NSRect, Bool) -> Void)?
    private var start: NSPoint?
    private var initial = NSRect.zero
    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("拖动编辑窗口边缘调整大小")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: edge == .top || edge == .bottom ? .resizeUpDown : .resizeLeftRight)
    }
    func place(in rect: NSRect) {
        let b: CGFloat = 6
        let c: CGFloat = 10
        switch edge {
        case .left: frame = NSRect(x: 0, y: c, width: b, height: rect.height - 2 * c)
        case .right: frame = NSRect(x: rect.width - b, y: c, width: b, height: rect.height - 2 * c)
        case .top: frame = NSRect(x: c, y: 0, width: rect.width - 2 * c, height: b)
        case .bottom: frame = NSRect(x: c, y: rect.height - b, width: rect.width - 2 * c, height: b)
        case .topLeft: frame = NSRect(x: 0, y: 0, width: c, height: c)
        case .topRight: frame = NSRect(x: rect.width - c, y: 0, width: c, height: c)
        case .bottomLeft: frame = NSRect(x: 0, y: rect.height - c, width: c, height: c)
        case .bottomRight: frame = NSRect(x: rect.width - c, y: rect.height - c, width: c, height: c)
        }
    }
    static func resized(_ frame: NSRect, delta: NSPoint, edge: Edge, visible: NSRect) -> NSRect {
        let minWidth = min(240, visible.width)
        let minHeight = min(180, visible.height)
        var left = frame.minX
        var right = frame.maxX
        var bottom = frame.minY
        var top = frame.maxY
        if edge.left { left = min(right - minWidth, max(visible.minX, left + delta.x)) }
        if edge.right { right = max(left + minWidth, min(visible.maxX, right + delta.x)) }
        if edge.bottom { bottom = min(top - minHeight, max(visible.minY, bottom + delta.y)) }
        if edge.top { top = max(bottom + minHeight, min(visible.maxY, top + delta.y)) }
        return NSRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }
    override func mouseDown(with event: NSEvent) {
        guard let host = window else { return }
        start = host.convertPoint(toScreen: event.locationInWindow)
        initial = host.frame
    }
    private func update(_ event: NSEvent, finished: Bool) {
        guard let host = window, let start else { return }
        let mouse = host.convertPoint(toScreen: event.locationInWindow)
        let visible = host.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        changed?(
            Self.resized(
                initial, delta: NSPoint(x: mouse.x - start.x, y: mouse.y - start.y),
                edge: edge, visible: visible), finished)
        if finished { self.start = nil }
    }
    override func mouseDragged(with event: NSEvent) { update(event, finished: false) }
    override func mouseUp(with event: NSEvent) { update(event, finished: true) }
}

extension GuidedTextView {
    func fitScrollViewport() {
        guard let scroll = enclosingScrollView else { return }
        let size = scroll.contentSize
        guard size.width > 0, size.height > 0 else { return }
        let resized = frame.width != size.width || minSize.height != size.height
        if contentExtentNeedsUpdate || resized {
            contentExtentNeedsUpdate = false
            // Reset the minimum to the viewport rather than the previous document
            // height. AppKit owns the vertical document extent as text is edited.
            minSize = size
            maxSize = NSSize(width: size.width, height: 10_000_000)
            if resized {
                textContainer?.containerSize = NSSize(
                    width: max(1, size.width - 2 * textContainerInset.width), height: 10_000_000)
                setFrameSize(NSSize(width: size.width, height: max(size.height, frame.height)))
            }
            extentTimer?.invalidate()
            extentTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
                self?.settleDocumentExtent()
            }
        }
    }

    func settleDocumentExtent() {
        extentTimer?.invalidate()
        extentTimer = nil
        guard let scroll = enclosingScrollView, let manager = layoutManager,
            let container = textContainer
        else { return }
        extentPassCount += 1
        manager.ensureLayout(for: container)
        let size = scroll.contentSize
        let extent = manager.usedRect(for: container).maxY + 2 * textContainerInset.height
        let target = NSSize(width: size.width, height: max(size.height, ceil(extent)))
        if frame.size != target { setFrameSize(target) }
    }
}
