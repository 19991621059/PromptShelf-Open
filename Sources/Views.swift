import AppKit

// Native label cells draw their visible text slightly above the frame center.
let labelOpticalOffset: CGFloat = 2

private func screenPoint(_ event: NSEvent, in host: NSWindow) -> NSPoint {
    (event.window ?? host).convertPoint(toScreen: event.locationInWindow)
}

enum Palette {
    static var dark = false
    static var background: NSColor { dark ? NSColor(white: 0.10, alpha: 1) : .white }
    static var ink: NSColor { dark ? NSColor(white: 0.94, alpha: 1) : NSColor(white: 0.08, alpha: 1) }
    static var secondary: NSColor { dark ? NSColor(white: 0.59, alpha: 1) : NSColor(white: 0.43, alpha: 1) }
    static var hover: NSColor { dark ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.95, alpha: 1) }
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class SearchActivationView: FlippedView {
    var activate: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSTextField || hit is NSButton ? hit : self
    }
    override func mouseDown(with event: NSEvent) { activate?() }
}

final class ShelfPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onEscape: (() -> Void)?
    var pointerCompletion: ((NSEvent) -> (() -> Void)?)?
    var routePointer: ((NSEvent) -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, routePointer?(event) == true { return }
        let completion =
            [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
            ? pointerCompletion?(event) : nil
        super.sendEvent(event)
        completion?()
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

final class ActionButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var actionBlock: (() -> Void)?
    private var hint: NSView?
    private var hintTimer: Timer?
    private var hintLabel = ""
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        hintTimer?.invalidate()
        hintTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.showHint()
        }
    }
    override func mouseExited(with event: NSEvent) { hideHint() }
    override func mouseDown(with event: NSEvent) {
        hideHint()
        super.mouseDown(with: event)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        hideHint()
        super.viewWillMove(toWindow: newWindow)
    }
    func hideHint() {
        hintTimer?.invalidate()
        hintTimer = nil
        hint?.removeFromSuperview()
        hint = nil
    }
    func showHint() {
        guard let root = window?.contentView else { return }
        hideHint()
        let font = NSFont.systemFont(ofSize: 10)
        let width = min(
            root.bounds.width, (hintLabel as NSString).size(withAttributes: [.font: font]).width + 12)
        let rect = convert(bounds, to: root)
        let bubble = FlippedView(
            frame: NSRect(
                x: max(0, min(root.bounds.width - width, rect.midX - width / 2)), y: rect.maxY + 3,
                width: width, height: 21))
        bubble.wantsLayer = true
        bubble.layer?.backgroundColor = Palette.hover.cgColor
        bubble.layer?.cornerRadius = 4
        let text = NSTextField(labelWithString: hintLabel)
        text.font = font
        text.textColor = Palette.secondary
        text.frame = NSRect(x: 6, y: 3, width: width - 12, height: 15)
        bubble.addSubview(text)
        root.addSubview(bubble)
        hint = bubble
    }
    init(symbol: String, label: String, frame: NSRect = .zero, action: @escaping () -> Void) {
        super.init(frame: frame)
        isBordered = false
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        contentTintColor = Palette.secondary
        target = self
        self.action = #selector(invoke)
        actionBlock = action
        hintLabel = label.contains("提示词目录") ? "目录" : label.contains("新建提示词") ? "新建提示词" : label
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { actionBlock?() }
    override func accessibilityPerformPress() -> Bool {
        invoke()
        return true
    }
}

final class HandleView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var interactive = true
    override func hitTest(_ point: NSPoint) -> NSView? { interactive ? super.hitTest(point) : nil }
    var context: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { context?() }
    var toggle: (() -> Void)?
    private var petView: PlushPetView?
    var petStyle = "classic" { didSet { updatePet() } }
    private func updatePet() {
        let normalized = PetCatalog.normalize(petStyle)
        if petStyle != normalized { petStyle = normalized }
        guard petStyle != oldValueStyle else { return }
        oldValueStyle = petStyle
        petView?.removeFromSuperview()
        petView = petStyle == "classic" ? nil : PlushPetView(style: petStyle)
        if let petView {
            petView.frame = bounds
            petView.autoresizingMask = [.width, .height]
            addSubview(petView)
        }
        needsDisplay = true
    }
    private var oldValueStyle = "classic"
    var began: ((NSPoint) -> Void)?
    var moved: ((NSPoint) -> Void)?
    var finished: (() -> Void)?
    private var start = NSPoint.zero
    private var didDrag = false
    private var tracking = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("展开 PromptShelf；上下拖动调整位置")
    }
    required init?(coder: NSCoder) { fatalError() }
    func activate(clickCount: Int) {
        toggle?()
    }
    override func accessibilityPerformPress() -> Bool {
        activate(clickCount: 1)
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard petStyle == "classic" else { return }
        let circle = bounds.insetBy(dx: 2, dy: 2)
        Palette.background.setFill()
        NSBezierPath(ovalIn: circle).fill()
        Palette.secondary.withAlphaComponent(0.16).setStroke()
        let rim = NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5))
        rim.lineWidth = 0.7
        rim.stroke()
        Palette.ink.setStroke()
        let bubble = NSBezierPath(
            roundedRect: NSRect(x: 10, y: 12, width: 18, height: 14), xRadius: 4, yRadius: 4)
        bubble.lineWidth = 1.4
        bubble.stroke()
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 13, y: 12))
        tail.line(to: NSPoint(x: 13, y: 9))
        tail.line(to: NSPoint(x: 17, y: 12))
        tail.lineWidth = 1.4
        tail.lineJoinStyle = .round
        tail.stroke()
        Palette.ink.setFill()
        for x: CGFloat in [15, 21] {
            NSBezierPath(roundedRect: NSRect(x: x, y: 18, width: 2.4, height: 4), xRadius: 0.8, yRadius: 0.8)
                .fill()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let host = window else { return }
        start = screenPoint(event, in: host)
        didDrag = false
        tracking = true
        began?(start)
    }
    override func mouseDragged(with event: NSEvent) {
        guard tracking, let host = window else { return }
        let point = screenPoint(event, in: host)
        if hypot(point.x - start.x, point.y - start.y) > 4 { didDrag = true }
        if didDrag { moved?(point) }
    }
    override func mouseUp(with event: NSEvent) {
        guard tracking, let host = window else { return }
        tracking = false
        let point = screenPoint(event, in: host)
        if hypot(point.x - start.x, point.y - start.y) > 4 { didDrag = true }
        if didDrag {
            moved?(point)
            finished?()
        } else {
            activate(clickCount: event.clickCount)
        }
    }
}

final class HeaderView: FlippedView {
    var began: ((NSPoint) -> Void)?
    var moved: ((NSPoint) -> Void)?
    var finished: (() -> Void)?
    private var start: NSPoint?
    private var dragging = false
    override func mouseDown(with event: NSEvent) {
        guard let host = window else { return }
        start = screenPoint(event, in: host)
        dragging = false
        began?(start!)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start, let host = window else { return }
        let point = screenPoint(event, in: host)
        if hypot(point.x - start.x, point.y - start.y) > 4 { dragging = true }
        if dragging { moved?(point) }
    }
    override func mouseUp(with event: NSEvent) {
        guard let start, let host = window else { return }
        self.start = nil
        let point = screenPoint(event, in: host)
        if hypot(point.x - start.x, point.y - start.y) > 4 { dragging = true }
        if dragging {
            moved?(point)
            finished?()
        }
    }
}

final class PromptRow: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    static func preview(_ prompt: Prompt) -> String {
        prompt.body.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }
    static func height(_ prompt: Prompt, width: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let size = (preview(prompt) as NSString).boundingRect(
            with: NSSize(width: width - 23, height: 1000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: paragraph])
        return 30 + min(30, max(15, ceil(size.height)))
    }
    let prompt: Prompt
    var onCopy: (() -> Void)?
    var bulk = false
    var selected = false
    var onSelect: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var groupOptions: [String] = []
    var onGroup: ((String) -> Void)?
    var located = false
    var copied = false { didSet { needsDisplay = true } }
    private var hovered = false
    private var tracking: NSTrackingArea?
    init(prompt: Prompt, frame: NSRect) {
        self.prompt = prompt
        super.init(frame: frame)
        isBordered = false
        title = prompt.title
        target = self
        action = #selector(pressed)
        setAccessibilityLabel("\(prompt.title)，单击复制，双击编辑")
        toolTip = "单击复制；双击编辑；右键删除"
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            activate(clickCount: event.clickCount)
            return
        }
        super.mouseDown(with: event)
    }
    func activate(clickCount: Int) {
        if bulk { onSelect?() } else if clickCount >= 2 { onEdit?() } else { onCopy?() }
    }
    @objc private func pressed() { activate(clickCount: 1) }
    override func accessibilityPerformPress() -> Bool {
        activate(clickCount: 1)
        return true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || copied || located || selected || isHighlighted {
            Palette.hover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let left: CGFloat = bulk ? 34 : 11
        if bulk {
            let box = NSRect(x: 11, y: 8, width: 14, height: 14)
            (selected ? Palette.ink : Palette.secondary).setStroke()
            let outline = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
            outline.lineWidth = 1
            outline.stroke()
            if selected, let image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) {
                image.draw(in: box.insetBy(dx: 2, dy: 2))
            }
        }
        let titleText = copied ? "\(prompt.title)  ✓" : prompt.title
        (titleText as NSString).draw(
            in: NSRect(x: left, y: 6, width: bounds.width - left - 23, height: 18),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: Palette.ink,
                .paragraphStyle: paragraph,
            ])
        paragraph.lineBreakMode = .byWordWrapping
        (Self.preview(prompt) as NSString).draw(
            with: NSRect(x: left, y: 25, width: bounds.width - left - 12, height: bounds.height - 30),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: Palette.secondary,
                .paragraphStyle: paragraph,
            ])
        if window?.firstResponder === self {
            Palette.secondary.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1), xRadius: 5, yRadius: 5)
            path.lineWidth = 1
            path.stroke()
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (name, selector) in [
            ("复制", #selector(copyItem)), ("编辑…", #selector(editItem)), ("上移", #selector(shiftUp)),
            ("下移", #selector(shiftDown)), ("删除…", #selector(deleteItem)),
        ] {
            let item = NSMenuItem(title: name, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        let groupMenu = NSMenu()
        for group in groupOptions + [""] {
            let item = NSMenuItem(
                title: group.isEmpty ? "未分组" : group, action: #selector(assignGroup(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = group
            item.state = prompt.group == group ? .on : .off
            groupMenu.addItem(item)
        }
        let move = NSMenuItem(title: "移动到分组", action: nil, keyEquivalent: "")
        move.submenu = groupMenu
        menu.insertItem(move, at: 2)
        return menu
    }
    @objc private func assignGroup(_ sender: NSMenuItem) {
        if let group = sender.representedObject as? String { onGroup?(group) }
    }
    @objc private func copyItem() { onCopy?() }
    @objc private func editItem() { onEdit?() }
    @objc private func deleteItem() { onDelete?() }
    @objc private func shiftUp() { onMove?(-1) }
    @objc private func shiftDown() { onMove?(1) }
}

// A plain text editor plus one separate icon avoids NSSearchField's duplicate
// icon and placeholder rendering when its borderless field editor becomes active.
final class PromptSearchField: NSTextField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isEditable = true
        isSelectable = true
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        cell?.focusRingType = .none
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        super.mouseDown(with: event)
    }
}

final class GroupNavigationButton: NSButton {
    var contextMenuBuilder: (() -> NSMenu)?
    override func menu(for event: NSEvent) -> NSMenu? { contextMenuBuilder?() ?? super.menu(for: event) }
    private let caption = NSTextField(labelWithString: "")
    private let symbol = NSImageView()
    private var selected: Bool
    private let fontSize: CGFloat
    private var hovered = false
    private let invokeAction: () -> Void
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(
        title: String, icon: String, frame: NSRect, selected: Bool, fontSize: CGFloat = 11,
        action: @escaping () -> Void
    ) {
        self.selected = selected
        self.fontSize = fontSize
        invokeAction = action
        super.init(frame: frame)
        self.title = title
        isBordered = false
        target = self
        self.action = #selector(invoke)
        state = selected ? .on : .off
        caption.stringValue = title
        caption.font = .systemFont(ofSize: fontSize, weight: selected ? .semibold : .regular)
        caption.textColor = selected ? Palette.ink : Palette.secondary
        caption.lineBreakMode = .byTruncatingTail
        symbol.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        symbol.contentTintColor = caption.textColor
        symbol.imageScaling = .scaleProportionallyDown
        caption.setAccessibilityElement(false)
        symbol.setAccessibilityElement(false)
        addSubview(symbol)
        addSubview(caption)
        setAccessibilityLabel(title)
        setAccessibilityValue(selected ? "已选中" : "未选中")
        toolTip = title
    }
    required init?(coder: NSCoder) { fatalError() }
    func select(_ value: Bool) {
        selected = value
        state = value ? .on : .off
        caption.font = .systemFont(ofSize: fontSize, weight: value ? .semibold : .regular)
        caption.textColor = value ? Palette.ink : Palette.secondary
        symbol.contentTintColor = caption.textColor
        setAccessibilityValue(value ? "已选中" : "未选中")
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        symbol.frame = NSRect(x: 8, y: (bounds.height - 14) / 2, width: 12, height: 14)
        caption.frame = NSRect(
            x: 27, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 33), height: 16)
    }
    override func draw(_ dirtyRect: NSRect) {
        if selected || hovered || isHighlighted {
            (selected ? Palette.hover : Palette.hover.withAlphaComponent(0.6)).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill() }
    @objc private func invoke() { invokeAction() }
    override func accessibilityPerformPress() -> Bool {
        invoke()
        return true
    }
}

class GuidedTextView: NSTextView {
    var isStructuredDocument = false
    var contentExtentNeedsUpdate = true
    var extentTimer: Timer?
    var extentPassCount = 0
    var cachedRichText: RichTextDocument?
    var richTextCacheValid = false
    var snapshotPassCount = 0
    private var scrollObserver: NSObjectProtocol?
    var codeLanguageButtons: [String: CodeLanguageButton] = [:]
    override init(frame frameRect: NSRect, textContainer: NSTextContainer?) {
        let storage = NSTextStorage()
        let manager = RichCodeLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(1, frameRect.width), height: 10_000_000))
        storage.addLayoutManager(manager)
        container.heightTracksTextView = false
        manager.addTextContainer(container)
        super.init(frame: frameRect, textContainer: container)
        isRichText = true
        importsGraphics = false
        allowsUndo = true
    }
    override convenience init(frame frameRect: NSRect) { self.init(frame: frameRect, textContainer: nil) }
    convenience init() { self.init(frame: .zero, textContainer: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func paste(_ sender: Any?) {
        if let text = OpenEnvironment.pasteboard.string(forType: .string) {
            insertText(text, replacementRange: selectedRange())
        }
    }
    deinit {
        extentTimer?.invalidate()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        extentTimer?.invalidate()
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in self?.needsLayout = true }
        }
    }
    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), let storage = textStorage else {
            super.insertNewline(sender)
            return
        }
        let selection = selectedRange()
        let attrs = typingAttributes
        guard attrs[.promptHeading] != nil || attrs[.promptCode] != nil else {
            super.insertNewline(sender)
            return
        }
        beginRichChange("换行")
        storage.replaceCharacters(in: selection, with: NSAttributedString(string: "\n", attributes: attrs))
        let caret = NSRange(location: selection.location + 1, length: 0)
        let nextParagraph = (storage.string as NSString).paragraphRange(for: caret)
        var next = attrs
        if attrs[.promptHeading] != nil {
            next = baseAttributes
            if nextParagraph.length > 0 { storage.setAttributes(baseAttributes, range: nextParagraph) }
        } else {
            let paragraph =
                (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            paragraph.paragraphSpacingBefore = 0
            next[.paragraphStyle] = paragraph
            if nextParagraph.length > 0 {
                storage.addAttribute(.paragraphStyle, value: paragraph, range: nextParagraph)
            }
        }
        setSelectedRange(caret)
        typingAttributes = next
        didChangeText()
        breakUndoCoalescing()
        scrollRangeToVisible(caret)
    }
    override func layout() {
        super.layout()
        fitScrollViewport()
        layoutCodeControls()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { dismissCommands() }
        return resigned
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        dismissCommands()
        let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
        let format = NSMenu(title: "格式")
        for (index, command) in EditorCommand.all.enumerated() {
            let item = NSMenuItem(
                title: command.title, action: #selector(applyFormatItem(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            format.addItem(item)
        }
        let item = NSMenuItem(title: "格式", action: nil, keyEquivalent: "")
        item.submenu = format
        menu.addItem(.separator())
        menu.addItem(item)
        return menu
    }
    @objc private func applyFormatItem(_ item: NSMenuItem) {
        guard EditorCommand.all.indices.contains(item.tag) else { return }
        applyCommand(EditorCommand.all[item.tag])
    }
    override func scrollWheel(with event: NSEvent) {
        dismissCommands()
        super.scrollWheel(with: event)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        dismissCommands()
        // A nonactivating side panel deliberately starts without a text responder.
        // Activate it before AppKit computes selection, including the first click
        // after switching applications, rather than consuming that click as focus.
        window?.makeKey()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    var commandMenu: CommandMenuView?
    var commandRange: NSRange?
    var commandQuery = ""
    var commandIndex = 0
    var commandChoices: [EditorCommand] = []
    var placeholder = "输入或粘贴提示词" { didSet { needsDisplay = true } }
    override var string: String {
        didSet {
            richTextCacheValid = false
            dismissCommands()
            isStructuredDocument = false
            if let storage = textStorage {
                storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
            }
            needsDisplay = true
        }
    }
    override func didChangeText() {
        richTextCacheValid = false
        super.didChangeText()
        contentExtentNeedsUpdate = true
        needsDisplay = true
        needsLayout = true
        updateCommands()
    }
    override func keyDown(with event: NSEvent) {
        if handleCommandKey(event) { return }
        super.keyDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty && !hasMarkedText() {
            (placeholder as NSString).draw(
                in: NSRect(
                    x: textContainerInset.width + 5, y: textContainerInset.height,
                    width: max(0, bounds.width - 12), height: 40),
                withAttributes: [.font: font ?? .systemFont(ofSize: 12), .foregroundColor: Palette.secondary])
        }
    }
}

final class PromptTextView: GuidedTextView {
    var saveAction: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if handleCommandKey(event) { return }
        if [36, 76].contains(event.keyCode), !hasMarkedText() {
            if event.modifierFlags.contains(.command) {
                saveAction?()
            } else {
                insertNewline(nil)
            }
            return
        }
        super.keyDown(with: event)
    }
}

final class TextActionButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var block: (() -> Void)?
    init(title: String, frame: NSRect, selected: Bool = false, action: @escaping () -> Void) {
        super.init(frame: frame)
        self.title = title
        isBordered = false
        font = .systemFont(ofSize: 11, weight: selected ? .semibold : .regular)
        contentTintColor = selected ? Palette.ink : Palette.secondary
        cell?.lineBreakMode = .byTruncatingTail
        alignment = .left
        wantsLayer = true
        if selected {
            layer?.backgroundColor = Palette.hover.cgColor
            layer?.cornerRadius = 4
        }
        block = action
        target = self
        self.action = #selector(invoke)
        setAccessibilityLabel(title)
        toolTip = title
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { block?() }
    override func accessibilityPerformPress() -> Bool {
        invoke()
        return true
    }
}

final class ResizeView: NSView {
    var panelSize: NSSize?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    enum Edge { case right, bottom, corner }
    let edge: Edge
    var changed: ((NSSize, Bool) -> Void)?
    private var start = NSPoint.zero
    private var initial = NSSize.zero
    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(edge == .right ? "拖动调整宽度" : edge == .bottom ? "拖动调整高度" : "拖动调整大小")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: edge == .bottom ? .resizeUpDown : .resizeLeftRight)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard edge == .corner else { return }
        Palette.secondary.withAlphaComponent(0.5).setStroke()
        for offset: CGFloat in [4, 8] {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: bounds.maxX - offset, y: 3))
            line.line(to: NSPoint(x: bounds.maxX - 3, y: offset))
            line.lineWidth = 1
            line.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let host = window else { return }
        start = screenPoint(event, in: host)
        initial = panelSize ?? host.frame.size
        // Keep the drag's owner alive while layout rebuilds the window content.
        while let next = host.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let finished = next.type == .leftMouseUp
            update(next, in: host, final: finished)
            if finished { break }
        }
    }
    private func update(_ event: NSEvent, in host: NSWindow, final: Bool) {
        let mouse = screenPoint(event, in: host)
        changed?(
            NSSize(
                width: initial.width + (edge == .bottom ? 0 : mouse.x - start.x),
                height: initial.height + (edge == .right ? 0 : start.y - mouse.y)), final)
    }
    override func mouseDragged(with event: NSEvent) {
        if let host = window { update(event, in: host, final: false) }
    }
    override func mouseUp(with event: NSEvent) {
        if let host = window { update(event, in: host, final: true) }
    }
}

final class DraftStretchView: FlippedView {
    var changed: ((CGFloat) -> Void)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
    override func draw(_ dirtyRect: NSRect) {
        Palette.secondary.withAlphaComponent(0.45).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: bounds.midX - 9, y: 3, width: 18, height: 2), xRadius: 1, yRadius: 1
        ).fill()
    }
    override func mouseDown(with event: NSEvent) {
        guard let host = window else { return }
        var lastY = screenPoint(event, in: host).y
        while let next = host.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let y = screenPoint(next, in: host).y
            changed?(lastY - y)
            lastY = y
            if next.type == .leftMouseUp { break }
        }
    }
}

final class InlineEditor: FlippedView, NSTextFieldDelegate, NSTextViewDelegate {
    let titleField = NSTextField()
    let bodyField = PromptTextView()
    let validation = NSTextField(labelWithString: "")
    let scroll = NSScrollView()
    let cancel = ActionButton(symbol: "xmark", label: "取消编辑") {}
    let saveButton = ActionButton(symbol: "checkmark", label: "保存提示词") {}
    let stretch = DraftStretchView()
    let draftNotice = NSTextField(labelWithString: "正文为空，尚未保存")
    let restoreButton = NSButton(title: "恢复已保存正文", target: nil, action: nil)
    var savedBody: String?
    var savedRichText: RichTextDocument?
    var saved: ((String, String, String) throws -> Void)?
    var closed: (() -> Void)?
    var relayout: (() -> Void)?
    var promptID: UUID?
    var keepsOpenAfterSave = false
    let group: String
    var minimal: Bool { true }
    var hasEmptyExistingDraft: Bool {
        promptID != nil && bodyField.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    let widthGrip = GroupRailResize(frame: .zero)
    let edgeGrips = EditorResizeView.Edge.allCases.map { EditorResizeView(edge: $0) }
    var resizeFrame: ((NSRect, Bool) -> Void)?
    var preferredHeight: CGFloat = 150
    var preferredFrame: NSRect?
    init(prompt: Prompt?, selectedGroup: String?) {
        promptID = prompt?.id
        savedBody = prompt?.body
        savedRichText = prompt?.richText
        group = prompt?.group ?? selectedGroup ?? ""
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        titleField.placeholderString = "给提示词起个名字"
        titleField.stringValue = prompt?.title ?? ""
        titleField.font = .systemFont(ofSize: prompt == nil ? 13 : 15, weight: .bold)
        titleField.focusRingType = .none
        titleField.setAccessibilityLabel("标题")
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.delegate = self
        widthGrip.setAccessibilityLabel("拖动调整编辑栏宽度")
        widthGrip.toolTip = "左右拖动调整编辑栏"
        bodyField.isRichText = true
        bodyField.allowsUndo = true
        bodyField.isAutomaticQuoteSubstitutionEnabled = false
        bodyField.isAutomaticDashSubstitutionEnabled = false
        bodyField.isAutomaticTextReplacementEnabled = false
        bodyField.isAutomaticSpellingCorrectionEnabled = false
        bodyField.font = .systemFont(ofSize: 12)
        bodyField.textContainerInset = NSSize(width: 2, height: 2)
        bodyField.isVerticallyResizable = true
        bodyField.isHorizontallyResizable = false
        bodyField.autoresizingMask = [.width]
        bodyField.textContainer?.widthTracksTextView = true
        bodyField.loadBody(prompt?.body ?? "", richText: prompt?.richText)
        bodyField.delegate = self
        bodyField.setAccessibilityLabel("提示词正文，回车换行，⌘回车保存并继续编辑；行首 / 插入格式")
        bodyField.saveAction = { [weak self] in self?.save(keepingOpen: true) }
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = bodyField
        validation.font = .systemFont(ofSize: 10)
        validation.textColor = .systemRed
        draftNotice.font = .systemFont(ofSize: 10)
        restoreButton.isBordered = false
        restoreButton.font = .systemFont(ofSize: 10)
        restoreButton.target = self
        restoreButton.action = #selector(restoreSavedBody)
        restoreButton.setAccessibilityLabel("恢复已保存正文")
        saveButton.actionBlock = { [weak self] in self?.save() }
        cancel.actionBlock = { [weak self] in self?.closed?() }
        stretch.changed = { [weak self] delta in
            guard let self else { return }
            self.preferredHeight = min(600, max(112, self.preferredHeight + delta))
            self.relayout?()
        }
        let children: [NSView] =
            minimal
            ? [titleField, scroll, validation, draftNotice, restoreButton]
            : [titleField, scroll, validation, cancel, saveButton, stretch]
        for view in children {
            addSubview(view)
        }
        for grip in edgeGrips {
            grip.changed = { [weak self] frame, finished in self?.resizeFrame?(frame, finished) }
            addSubview(grip)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let w = bounds.width
        for grip in edgeGrips { grip.place(in: bounds) }
        let emptyDraft = hasEmptyExistingDraft
        draftNotice.isHidden = !emptyDraft
        restoreButton.isHidden = !emptyDraft
        bodyField.placeholder = emptyDraft ? "输入正文，或恢复已保存内容" : "输入或粘贴提示词，行首 / 插入格式"
        layer?.backgroundColor = Palette.background.cgColor
        titleField.textColor = Palette.ink
        titleField.frame = NSRect(x: 11, y: 7, width: w - (minimal ? 24 : 76), height: 22)
        cancel.frame = NSRect(x: w - 60, y: 5, width: 24, height: 24)
        saveButton.frame = NSRect(x: w - 31, y: 5, width: 24, height: 24)
        scroll.frame = NSRect(
            x: 9, y: 32, width: w - 18,
            height: bounds.height - (validation.stringValue.isEmpty && !emptyDraft ? (minimal ? 40 : 44) : 61)
        )
        bodyField.fitScrollViewport()
        bodyField.backgroundColor = Palette.background
        bodyField.textColor = Palette.ink
        bodyField.insertionPointColor = Palette.ink
        validation.frame = NSRect(x: 11, y: bounds.height - 27, width: w - 22, height: 17)
        draftNotice.frame = NSRect(x: 11, y: bounds.height - 27, width: w - 120, height: 17)
        draftNotice.textColor = Palette.secondary
        restoreButton.frame = NSRect(x: w - 107, y: bounds.height - 29, width: 98, height: 20)
        restoreButton.contentTintColor = Palette.ink
        if emptyDraft { validation.isHidden = true } else { validation.isHidden = false }
        stretch.frame = NSRect(x: 5, y: bounds.height - 10, width: w - 10, height: 10)
        cancel.contentTintColor = Palette.secondary
        saveButton.contentTintColor = Palette.ink
        bodyField.positionCommands()
    }
    func textDidChange(_ notification: Notification) { needsLayout = true }
    @objc func restoreSavedBody() {
        guard let savedBody else { return }
        bodyField.loadBody(savedBody, richText: savedRichText)
        validation.stringValue = ""
        needsLayout = true
        scroll.contentView.scroll(to: .zero)
        window?.makeFirstResponder(bodyField)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() {
            window?.makeFirstResponder(bodyField)
            return true
        }
        return false
    }
    func save(keepingOpen: Bool = false) {
        guard !bodyField.hasMarkedText(),
            (titleField.currentEditor() as? NSTextView)?.hasMarkedText() != true
        else { return }
        keepsOpenAfterSave = keepingOpen
        if let entry = titleField.currentEditor() { titleField.stringValue = entry.string }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            validation.stringValue = "请输入标题"
            needsLayout = true
            return
        }
        guard !bodyField.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validation.stringValue = "请输入提示词"
            needsLayout = true
            return
        }
        do { try saved?(title, bodyField.string, group) } catch {
            validation.stringValue = error.localizedDescription
            validation.toolTip = error.localizedDescription
            needsLayout = true
        }
    }
}
