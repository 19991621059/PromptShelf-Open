import AppKit

// Original native vector companions; no exported templates or web renderer.
enum PetCatalog {
    static let styles = [("classic", "原始图标"), ("round", "奶油圆团"), ("cloud", "金黄云团"), ("heart", "蜜桃心团"), ("sprout", "薄荷芽团"), ("cat", "雾蓝猫团")]
    static func normalize(_ style: String) -> String {
        if style == "bear" { return "round" }
        if style == "bunny" { return "heart" }
        return styles.contains(where: { $0.0 == style }) ? style : "classic"
    }
}

final class PlushPetView: NSView {
    let style: String
    var animationEnabled = false
    init(style: String) { self.style = PetCatalog.normalize(style); super.init(frame: .zero); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let tones: [String: NSColor] = ["round": NSColor(calibratedRed: 0.95, green: 0.86, blue: 0.7, alpha: 1), "cloud": .systemYellow, "heart": .systemPink, "sprout": .systemMint, "cat": .systemTeal]
        let color = tones[style] ?? .controlAccentColor
        let rect = bounds.insetBy(dx: bounds.width * 0.12, dy: bounds.height * 0.14)
        if style == "cat" {
            color.setFill()
            for x in [rect.minX, rect.maxX - rect.width * 0.25] {
                let ear = NSBezierPath(); ear.move(to: NSPoint(x: x, y: rect.midY)); ear.line(to: NSPoint(x: x + rect.width * 0.1, y: rect.maxY + 3)); ear.line(to: NSPoint(x: x + rect.width * 0.25, y: rect.midY)); ear.close(); ear.fill()
            }
        }
        NSGradient(starting: color.blended(withFraction: 0.25, of: .white)!, ending: color)!.draw(in: NSBezierPath(ovalIn: rect), angle: -90)
        if style == "sprout" {
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX, y: rect.maxY - 2, width: rect.width * 0.25, height: rect.height * 0.15)).fill()
        }
        NSColor(calibratedWhite: 0.17, alpha: 1).setFill()
        for x in [rect.midX - rect.width * 0.18, rect.midX + rect.width * 0.12] {
            NSBezierPath(ovalIn: NSRect(x: x, y: rect.midY, width: 2.5, height: 3.5)).fill()
        }
        let smile = NSBezierPath(); smile.move(to: NSPoint(x: rect.midX - 3, y: rect.midY - 4)); smile.curve(to: NSPoint(x: rect.midX + 3, y: rect.midY - 4), controlPoint1: NSPoint(x: rect.midX - 2, y: rect.midY - 7), controlPoint2: NSPoint(x: rect.midX + 2, y: rect.midY - 7)); smile.lineWidth = 1.1; NSColor.darkGray.setStroke(); smile.stroke()
    }
}

final class PetChoiceButton: NSButton {
    var selected = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(selected ? "已选择" : "未选择")
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        if selected {
            Palette.hover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
            Palette.ink.withAlphaComponent(0.5).setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            border.lineWidth = 1
            border.stroke()
        }
    }
}

final class PetPicker: FlippedView {
    var selected: String { didSet { updateSelection() } }
    var changed: ((String) -> Void)?
    var animationEnabled = false {
        didSet {
            for button in subviews {
                (button.subviews.first as? PlushPetView)?.animationEnabled = animationEnabled
            }
        }
    }
    init(selected: String) {
        self.selected = PetCatalog.normalize(selected)
        super.init(frame: .zero)
        for (index, style) in PetCatalog.styles.enumerated() {
            let button = PetChoiceButton(title: "", target: self, action: #selector(choose(_:)))
            button.tag = index
            button.isBordered = false
            button.setAccessibilityLabel("选择\(style.1)")
            addSubview(button)
            let preview: NSView
            if style.0 == "classic" {
                let handle = HandleView(frame: .zero)
                handle.interactive = false
                preview = handle
            } else {
                let pet = PlushPetView(style: style.0)
                pet.animationEnabled = false
                preview = pet
            }
            button.addSubview(preview)
        }
        updateSelection()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func choose(_ sender: NSButton) {
        selected = PetCatalog.styles[sender.tag].0
        changed?(selected)
    }
    private func updateSelection() {
        let normalized = PetCatalog.normalize(selected)
        for (i, button) in subviews.enumerated() {
            (button as? PetChoiceButton)?.selected = PetCatalog.styles[i].0 == normalized
        }
    }
    override func layout() {
        super.layout()
        let width = min(52, bounds.width / 6)
        for (i, view) in subviews.enumerated() {
            view.frame = NSRect(x: CGFloat(i) * width, y: 0, width: width - 4, height: 52)
            view.subviews.first?.frame = NSRect(x: (width - 4 - 38) / 2, y: 7, width: 38, height: 38)
        }
    }
}
