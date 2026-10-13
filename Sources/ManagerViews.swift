import AppKit

enum ManagerDragType {
    static let prompt = NSPasteboard.PasteboardType("io.github.promptshelf.open.prompts")
    static let group = NSPasteboard.PasteboardType("io.github.promptshelf.open.group")
}

final class ManagerSplit: NSSplitView {
    override var dividerThickness: CGFloat { 5 }
    override func drawDivider(in rect: NSRect) {
        Palette.background.setFill()
        rect.fill()
    }
}

final class ManagerRoot: FlippedView {
    var resized: (() -> Void)?
    override func layout() {
        super.layout()
        resized?()
    }
}

final class ManagerSelectionRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        Palette.hover.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

final class ManagerTable: NSTableView {
    var contextMenu: ((Int) -> NSMenu?)?
    var doubleClickRow: ((Int) -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let doubleClickRow {
            let clicked = row(at: convert(event.locationInWindow, from: nil))
            guard clicked >= 0 else { return }
            doubleClickRow(clicked)
            return
        }
        super.mouseDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        return contextMenu?(row)
    }
}

final class ManagerCell: NSTableCellView {
    let heading = NSTextField(labelWithString: "")
    let preview = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    var choose: (() -> Void)?
    let copyButton = ActionButton(symbol: "doc.on.doc", label: "复制完整提示词") {}
    private var copyTimer: Timer?
    func showCopied() {
        copyTimer?.invalidate()
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "已复制")
        copyButton.isHidden = false
        copyTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            self?.copyButton.image = NSImage(
                systemSymbolName: "doc.on.doc", accessibilityDescription: "复制完整提示词")
            self?.copyTimer = nil
        }
    }
    var showGroup = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        preview.font = .systemFont(ofSize: 12)
        preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byTruncatingTail
        preview.cell?.wraps = true
        preview.cell?.usesSingleLineMode = false
        preview.cell?.isScrollable = false
        detail.font = .systemFont(ofSize: 10)
        for view in [heading, preview, detail, copyButton, checkbox] {
            addSubview(view)
        }
        copyButton.isHidden = true
        checkbox.isHidden = true
        checkbox.target = self
        checkbox.action = #selector(toggleChoice)
    }
    @objc func toggleChoice() { choose?() }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .inVisibleRect, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { copyButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { if copyTimer == nil { copyButton.isHidden = true } }
    override func layout() {
        super.layout()
        heading.textColor = Palette.ink
        preview.textColor = Palette.secondary
        detail.textColor = Palette.secondary
        let w = bounds.width
        let left: CGFloat = checkbox.isHidden ? 10 : 32
        checkbox.frame = NSRect(x: 9, y: bounds.height - 27, width: 20, height: 20)
        heading.frame = NSRect(x: left, y: bounds.height - 24, width: w - left - 37, height: 18)
        copyButton.frame = NSRect(x: w - 32, y: bounds.height - 29, width: 24, height: 24)
        preview.frame = NSRect(x: left, y: showGroup ? 16 : 7, width: w - left - 12, height: 30)
        detail.frame = NSRect(x: left, y: 2, width: w - 22, height: 14)
        detail.isHidden = !showGroup
    }
}

final class GroupNameField: NSTextField {
    // Let the table receive double clicks until this label becomes an editor.
    override func hitTest(_ point: NSPoint) -> NSView? { isEditable ? super.hitTest(point) : nil }
}

final class ManagerGroupCell: NSTableCellView {
    let name = GroupNameField(labelWithString: "")
    let count = NSTextField(labelWithString: "")
    var group: String?
    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: 12)
        name.isBezeled = false
        name.drawsBackground = false
        name.focusRingType = .none
        name.lineBreakMode = .byTruncatingTail
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        count.alignment = .right
        for view in [name, count] {
            addSubview(view)
        }
        textField = name
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        name.textColor = Palette.ink
        count.textColor = Palette.secondary
        let lineHeight: CGFloat = 18
        let centerY = (bounds.height - lineHeight) / 2 - labelOpticalOffset
        name.frame = NSRect(x: 12, y: centerY, width: max(40, bounds.width - 48), height: lineHeight)
        count.frame = NSRect(x: bounds.width - 35, y: centerY, width: 25, height: lineHeight)
    }
}
