import AppKit

@MainActor
func runGeometryChecks() {
    for screen in [
        NSRect(x: 0, y: 0, width: 1728, height: 1080), NSRect(x: -1920, y: -120, width: 1920, height: 1200),
    ] {
        let visible = NSRect(
            x: screen.minX, y: screen.minY + 26, width: screen.width, height: screen.height - 50)
        let cases: [(NSPoint, String)] = [
            (NSPoint(x: screen.minX + 5, y: screen.midY), "left"),
            (NSPoint(x: screen.maxX - 41, y: screen.midY), "right"),
            (NSPoint(x: screen.midX, y: screen.maxY - 40), "top"),
            (NSPoint(x: screen.midX, y: screen.minY + 5), "bottom"),
            (NSPoint(x: screen.midX, y: screen.midY), ""),
            (NSPoint(x: screen.minX + 5, y: screen.maxY - 43), "left"),
        ]
        for (point, expected) in cases {
            let (snapped, edge) = ShelfGeometry.snap(point, screen: screen, visible: visible)
            precondition(edge == expected)
            var library = Library()
            library.positionX = Double((snapped.x - screen.minX) / (screen.width - 38))
            library.positionY = Double((screen.maxY - snapped.y - 38) / (screen.height - 38))
            library.dockEdge = edge
            try! library.normalize()
            let restored = ShelfGeometry.anchor(library, screen: screen, visible: visible)
            precondition(abs(restored.x - snapped.x) < 0.001 && abs(restored.y - snapped.y) < 0.001)
            for extra: CGFloat in [0, 154] {
                let layout = ShelfGeometry.layout(
                    anchor: restored, width: 424, height: 266, creationHeight: extra, screen: screen,
                    visible: visible)
                let exposed = screen.intersection(layout.orb)
                let fraction =
                    exposed.width * exposed.height / (ShelfGeometry.orbSize * ShelfGeometry.orbSize)
                precondition(abs(fraction - (edge.isEmpty ? 1 : 0.5)) < 0.001)
                precondition(visible.contains(layout.panel))
                precondition(layout.window.contains(layout.panel) && layout.window.contains(layout.orb))
                if edge == "right" { precondition(layout.panel.maxX <= layout.orb.minX) }
                if let creation = layout.creation { precondition(visible.contains(creation)) }
                for sideEditor: CGFloat in [0, 300] {
                    let indexed = ShelfGeometry.layout(
                        anchor: restored, width: 424, height: 266, creationHeight: extra, screen: screen,
                        visible: visible, directoryWidth: 104, editingWidth: sideEditor)
                    let directory = NSRect(
                        x: indexed.panel.maxX + 6, y: indexed.panel.maxY - 90, width: 104, height: 90)
                    precondition(visible.contains(indexed.panel) && visible.contains(directory))
                    precondition(directory.minX > indexed.panel.maxX)
                    if sideEditor > 0 {
                        let editor = NSRect(
                            x: directory.maxX + 6, y: indexed.panel.maxY - 180, width: sideEditor, height: 180
                        )
                        precondition(visible.contains(editor) && !editor.intersects(directory))
                    }
                }
            }
            if !edge.isEmpty {
                let movedInside = ShelfGeometry.snap(
                    NSPoint(x: screen.midX, y: screen.midY), screen: screen, visible: visible)
                precondition(
                    movedInside.1.isEmpty
                        && screen.contains(NSRect(origin: movedInside.0, size: NSSize(width: 38, height: 38)))
                )
            }
        }
        for edge in ["left|top", "left|bottom", "right|top", "right|bottom"] {
            var legacy = Library()
            legacy.dockEdge = edge
            let orb = NSRect(
                origin: ShelfGeometry.anchor(legacy, screen: screen, visible: visible),
                size: NSSize(width: 38, height: 38))
            let exposed = screen.intersection(orb)
            precondition(exposed.width * exposed.height == 38 * 19)
        }
    }
    print(
        "PASS: four-edge docking, normalized positions, right-side directory and non-overlapping editor across screen edges and screen origins"
    )
}
