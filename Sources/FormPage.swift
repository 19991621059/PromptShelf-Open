import AppKit

final class CompactStatusView: FlippedView {
    let symbol = NSImageView()
    let caption = NSTextField(labelWithString: "")
    init(_ text: String = "", success: Bool = false) {
        super.init(frame: .zero)
        caption.font = .systemFont(ofSize: 12)
        caption.lineBreakMode = .byTruncatingTail
        addSubview(symbol)
        addSubview(caption)
        symbol.setAccessibilityElement(false)
        update(text, success: success)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ text: String, success: Bool, detail: String? = nil) {
        caption.stringValue = text
        caption.textColor = Palette.ink
        symbol.image = NSImage(
            systemSymbolName: success ? "checkmark" : "minus", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        symbol.contentTintColor = success ? .systemGreen : Palette.secondary
        toolTip = detail
        needsLayout = true
    }
    override func layout() {
        super.layout()
        caption.textColor = Palette.ink
        symbol.frame = NSRect(x: 0, y: (bounds.height - 14) / 2, width: 14, height: 14)
        caption.frame = NSRect(
            x: 22, y: (bounds.height - 18) / 2 + labelOpticalOffset, width: max(0, bounds.width - 22),
            height: 18)
    }
}

final class FormControls: FlippedView {
    let controls: [NSView]
    let widths: [CGFloat]
    init(_ controls: [NSView], widths: [CGFloat]) {
        self.controls = controls
        self.widths = widths
        super.init(frame: .zero)
        for view in controls {
            addSubview(view)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for (index, control) in controls.enumerated() {
            if let text = control as? NSTextField { text.textColor = Palette.ink }
            let width = min(widths[index], max(0, bounds.width - x))
            let height: CGFloat
            if let text = control as? NSTextField, !text.isEditable {
                height = ceil(text.fittingSize.height)
            } else {
                height =
                    control is NSButton || control is NSPopUpButton ? 28 : 24
            }
            control.frame = NSRect(
                x: x,
                y: max(0, (bounds.height - height) / 2)
                    + ((control as? NSTextField).map { !$0.isEditable ? labelOpticalOffset : 0 } ?? 0),
                width: width, height: height)
            x += width + 8
        }
    }
}

class FormPage: FlippedView {
    struct Row {
        let label: NSTextField?
        let control: NSView
        let height: CGFloat
        let preferredWidth: CGFloat
    }
    let heading: NSTextField
    var rows: [Row] = []
    var actions: [MenuAction] = []
    var contentHeight: CGFloat { 44 + rows.reduce(0) { $0 + $1.height } + 16 }
    init(title: String) {
        heading = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        addSubview(heading)
    }
    required init?(coder: NSCoder) { fatalError() }
    func section(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        addSubview(label)
        rows.append(Row(label: nil, control: label, height: 32, preferredWidth: 0))
    }
    func row(_ title: String, _ control: NSView, height: CGFloat = 36, width: CGFloat = 0) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        addSubview(label)
        addSubview(control)
        rows.append(Row(label: label, control: control, height: height, preferredWidth: width))
    }
    func attachActions(to control: NSView, actions: [NSView], widths: [CGFloat]) {
        guard let index = rows.firstIndex(where: { $0.control === control }) else { return }
        let old = rows[index]
        let combined = FormControls([control] + actions, widths: widths)
        addSubview(combined)
        rows[index] = Row(label: old.label, control: combined, height: old.height, preferredWidth: 0)
    }
    func note(_ text: String = "", height: CGFloat = 32) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.tag = 1
        addSubview(label)
        rows.append(Row(label: nil, control: label, height: height, preferredWidth: 0))
        return label
    }
    func button(_ title: String, action: @escaping () -> Void) -> NSButton {
        let handler = MenuAction(action)
        actions.append(handler)
        let button = NSButton(title: title, target: handler, action: #selector(MenuAction.invoke))
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12)
        return button
    }
    func colors() {
        heading.textColor = Palette.ink
        for row in rows {
            row.label?.textColor = Palette.ink
            if let text = row.control as? NSTextField {
                text.textColor = text.tag == 1 ? Palette.secondary : Palette.ink
            }
        }
    }
    override func layout() {
        super.layout()
        colors()
        heading.frame = NSRect(x: 20, y: 12, width: bounds.width - 40, height: 20)
        let labelWidth: CGFloat = bounds.width < 520 ? 106 : 112
        let controlX = 20 + labelWidth + 8
        var y: CGFloat = 44
        for row in rows {
            guard row.height > 0 else {
                row.control.isHidden = true
                row.label?.isHidden = true
                continue
            }
            row.control.isHidden = false
            row.label?.isHidden = false
            let x: CGFloat = row.label == nil ? 20 : controlX
            let available = max(0, bounds.width - x - 20)
            let width = row.preferredWidth == 0 ? available : min(row.preferredWidth, available)
            row.label?.frame = NSRect(
                x: 20, y: y + (row.height - 18) / 2 + labelOpticalOffset, width: labelWidth, height: 18)
            var height: CGFloat =
                row.control is FormControls
                ? row.height
                : row.control is NSButton || row.control is NSPopUpButton
                    ? 28 : row.height > 40 ? row.height - 8 : row.control is NSTextField ? 24 : 26
            if let text = row.control as? NSTextField, !text.isEditable {
                let measured = (text.stringValue as NSString).boundingRect(
                    with: NSSize(width: width, height: 200), options: [.usesLineFragmentOrigin],
                    attributes: [.font: text.font ?? NSFont.systemFont(ofSize: 12)]
                ).height
                height = min(row.height - 4, max(18, ceil(measured)))
            }
            let labelOffset: CGFloat =
                (row.control as? NSTextField).map { !$0.isEditable && height <= 24 ? labelOpticalOffset : 0 }
                ?? 0
            row.control.frame = NSRect(
                x: x, y: y + (row.height - height) / 2 + labelOffset, width: width, height: height)
            y += row.height
        }
    }
}
