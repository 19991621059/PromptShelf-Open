import AppKit

/// Tracks a whole drag even when rendering rebuilds the panel's view hierarchy.
final class GroupRailResize: NSView {
    var columnWidth: CGFloat = 86
    var changed: ((CGFloat, Bool) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("拖动调整分组栏宽度")
        toolTip = "左右拖动调整分组栏"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    private var hovered = false
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        Palette.secondary.withAlphaComponent(hovered ? 0.7 : 0.32).setFill()
        let height = min(32, bounds.height - 16)
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 0.5, y: bounds.midY - height / 2,
            width: 1, height: height), xRadius: 0.5, yRadius: 0.5).fill()
        if hovered {
            for dx: CGFloat in [-2, 2] {
                NSBezierPath(ovalIn: NSRect(x: bounds.midX + dx - 0.5, y: bounds.midY - 0.5,
                    width: 1, height: 1)).fill()
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let initial = columnWidth
        let start = window.convertPoint(toScreen: event.locationInWindow).x
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let final = next.type == .leftMouseUp
            let x = window.convertPoint(toScreen: next.locationInWindow).x
            changed?(initial + x - start, final)
            if final { break }
        }
    }
}

extension AppDelegate {
    func groupRailWidth(in available: CGFloat) -> CGFloat {
        let preferred = liveGroupRailWidth ?? CGFloat(store.library.groupRailWidth ?? 86)
        return min(max(86, preferred), max(86, available - 160))
    }
    func resizeGroupRail(to requested: CGFloat, finished: Bool) {
        guard requested.isFinite else { return }
        liveGroupRailWidth = min(260, max(86, requested))
        render()
        if finished {
            let actual = groupRailResize.columnWidth
            do { try store.change { $0.groupRailWidth = Double(actual) } }
            catch { showError(error.localizedDescription) }
            liveGroupRailWidth = nil
        }
    }
}
