import AppKit

enum ShelfGeometry {
    static let orbSize: CGFloat = 38
    static let halfOrb = orbSize / 2
    static func clamp(_ point: NSPoint, screen: NSRect, visible: NSRect) -> NSPoint {
        NSPoint(
            x: min(screen.maxX - halfOrb, max(screen.minX - halfOrb, point.x)),
            y: min(screen.maxY - halfOrb, max(screen.minY - halfOrb, point.y)))
    }
    static func dock(_ point: NSPoint, edge: String, screen: NSRect) -> NSPoint {
        var point = point
        // Keep exactly half visible, including at corners and when restoring older corner docks.
        if edge.contains("left") || edge.contains("right") {
            point.x = edge.contains("left") ? screen.minX - halfOrb : screen.maxX - halfOrb
            point.y = min(screen.maxY - orbSize - 2, max(screen.minY + 2, point.y))
        } else if edge.contains("top") || edge.contains("bottom") {
            point.y = edge.contains("top") ? screen.maxY - halfOrb : screen.minY - halfOrb
            point.x = min(screen.maxX - orbSize - 2, max(screen.minX + 2, point.x))
        }
        return point
    }
    static func anchor(_ library: Library, screen: NSRect, visible: NSRect) -> NSPoint {
        var point = NSPoint(
            x: screen.minX + CGFloat(library.positionX ?? 0) * (screen.width - orbSize),
            y: screen.maxY - orbSize - CGFloat(library.positionY ?? 0) * (screen.height - orbSize))
        if library.positionY == nil {
            point.y = visible.maxY - CGFloat(library.topRatio) * (visible.height - orbSize) - orbSize
        }
        let edge = library.dockEdge ?? (library.positionX == nil ? "left" : "")
        return dock(clamp(point, screen: screen, visible: visible), edge: edge, screen: screen)
    }
    static func snap(_ point: NSPoint, screen: NSRect, visible: NSRect, distance: CGFloat = 22) -> (
        NSPoint, String
    ) {
        let point = clamp(point, screen: screen, visible: visible)
        let candidates: [(String, CGFloat)] = [
            ("left", abs(point.x - screen.minX)), ("right", abs(screen.maxX - point.x - orbSize)),
            ("top", abs(screen.maxY - point.y - orbSize)), ("bottom", abs(point.y - screen.minY)),
        ]
        let nearest = candidates.enumerated().min { a, b in
            a.element.1 == b.element.1 ? a.offset < b.offset : a.element.1 < b.element.1
        }!.element
        let edge = nearest.1 < distance ? nearest.0 : ""
        return (dock(point, edge: edge, screen: screen), edge)
    }
    struct Layout {
        var window: NSRect
        var orb: NSRect
        var panel: NSRect
        var creation: NSRect?
        func local(_ rect: NSRect) -> NSRect {
            NSRect(
                x: rect.minX - window.minX, y: window.maxY - rect.maxY, width: rect.width, height: rect.height
            )
        }
    }
    static func layout(
        anchor: NSPoint, width: CGFloat, height: CGFloat, creationHeight: CGFloat, screen: NSRect,
        visible: NSRect, directoryWidth: CGFloat = 0, editingWidth: CGFloat = 0
    ) -> Layout {
        let orb = NSRect(
            origin: clamp(anchor, screen: screen, visible: visible), size: NSSize(width: 38, height: 38))
        let directoryReserve = directoryWidth > 0 ? directoryWidth + 6 : 0
        let bodyWidth = min(width - 42, visible.width - directoryReserve)
        let editingReserve =
            editingWidth > 0 && visible.width >= bodyWidth + directoryReserve + editingWidth + 12
            ? editingWidth + 6 : 0
        let reserve = directoryReserve + editingReserve
        let toRight =
            orb.maxX + 4 + bodyWidth + reserve <= visible.maxX
            || orb.minX - bodyWidth - reserve - 4 < visible.minX
        let intendedX = toRight ? orb.maxX + 4 : orb.minX - bodyWidth - reserve - 4
        let x = min(visible.maxX - bodyWidth - reserve, max(visible.minX, intendedX))
        let y = min(visible.maxY - height - creationHeight, max(visible.minY + 2, orb.maxY - height))
        let panel = NSRect(x: x, y: y, width: bodyWidth, height: height)
        let creation =
            creationHeight > 0
            ? NSRect(x: x, y: panel.maxY + 4, width: bodyWidth, height: creationHeight - 4) : nil
        var union = panel.union(orb)
        if let creation { union = union.union(creation) }
        return Layout(window: union, orb: orb, panel: panel, creation: creation)
    }
}
