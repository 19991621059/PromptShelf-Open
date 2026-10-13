import AppKit

struct EditorCommand: Equatable {
    enum Kind: Equatable {
        case heading(Int)
        case bold
        case paragraph
        case code(String)
    }
    let title: String
    let keywords: String
    let kind: Kind
    static let all: [Self] = [
        Self(title: "一级标题", keywords: "h1 heading title 标题", kind: .heading(1)),
        Self(title: "二级标题", keywords: "h2 heading subtitle 标题", kind: .heading(2)),
        Self(title: "加粗", keywords: "bold 加粗", kind: .bold),
        Self(title: "代码块 · 纯文本", keywords: "code plain text 代码 纯文本", kind: .code("")),
        Self(title: "代码块 · Python", keywords: "code python py 代码", kind: .code("python")),
        Self(title: "代码块 · JavaScript", keywords: "code javascript js 代码", kind: .code("javascript")),
        Self(title: "代码块 · Swift", keywords: "code swift 代码", kind: .code("swift")),
        Self(title: "代码块 · JSON", keywords: "code json 代码", kind: .code("json")),
        Self(title: "代码块 · Shell", keywords: "code bash shell sh 代码", kind: .code("bash")),
        Self(title: "正文", keywords: "paragraph normal text 正文", kind: .paragraph),
    ]
    static func trigger(in text: NSString, selection: NSRange) -> (NSRange, String)? {
        guard selection.length == 0, selection.location > 0, selection.location <= text.length else {
            return nil
        }
        var start = selection.location
        while start > 0, selection.location - start <= 40 {
            let previous = text.character(at: start - 1)
            if previous == 10 || previous == 13 || previous == 0x2028 || previous == 0x2029 { break }
            start -= 1
        }
        guard selection.location - start <= 40 else { return nil }
        let prefix = text.substring(
            with: NSRange(location: start, length: selection.location - start))
        guard prefix.hasPrefix("/"), !prefix.contains("\n"), !prefix.contains("\r"), prefix.utf16.count <= 40
        else { return nil }
        let query = String(prefix.dropFirst())
        guard !query.contains("/") else { return nil }
        return (NSRange(location: start, length: prefix.utf16.count), query)
    }
}

final class CommandMenuView: FlippedView {
    let scroll = NSScrollView()
    let list = FlippedView()
    init(choices: [EditorCommand], selected: Int, choose: @escaping (EditorCommand) -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Palette.background.cgColor
        layer?.borderColor = Palette.secondary.withAlphaComponent(0.35).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
        setAccessibilityLabel("编辑命令，方向键选择，回车应用，Esc 关闭")
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = list
        addSubview(scroll)
        for (index, choice) in choices.enumerated() {
            let row = TextActionButton(title: choice.title, frame: .zero, selected: index == selected) {
                choose(choice)
            }
            row.refusesFirstResponder = true
            row.tag = index
            list.addSubview(row)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 3, dy: 3)
        list.frame = NSRect(
            x: 0, y: 0, width: scroll.contentSize.width, height: CGFloat(list.subviews.count) * 26)
        for row in list.subviews {
            row.frame = NSRect(x: 4, y: CGFloat(row.tag) * 26, width: list.bounds.width - 8, height: 26)
        }
    }
    func reveal(_ index: Int) {
        layoutSubtreeIfNeeded()
        list.scrollToVisible(NSRect(x: 0, y: CGFloat(index) * 26, width: 1, height: 26))
    }
}

extension GuidedTextView {
    func dismissCommands() {
        commandMenu?.removeFromSuperview()
        commandMenu = nil
        commandRange = nil
        commandQuery = ""
        commandChoices = []
        commandIndex = 0
    }
    func updateCommands() {
        guard !hasMarkedText(), window?.firstResponder === self,
            let (range, query) = EditorCommand.trigger(in: string as NSString, selection: selectedRange())
        else {
            dismissCommands()
            return
        }
        let choices = EditorCommand.all.filter {
            query.isEmpty || $0.keywords.localizedCaseInsensitiveContains(query)
                || $0.title.localizedCaseInsensitiveContains(query)
        }
        guard !choices.isEmpty else {
            dismissCommands()
            return
        }
        let reuse = commandMenu != nil && choices == commandChoices
        if query != commandQuery { commandIndex = 0 }
        commandRange = range
        commandQuery = query
        commandChoices = choices
        commandIndex = min(commandIndex, choices.count - 1)
        if reuse {
            positionCommands()
            commandMenu?.reveal(commandIndex)
        } else {
            showCommands()
        }
    }
    func showCommands() {
        commandMenu?.removeFromSuperview()
        guard let root = enclosingScrollView?.superview else { return }
        let menu = CommandMenuView(choices: commandChoices, selected: commandIndex) { [weak self] command in
            self?.applyCommand(command)
        }
        commandMenu = menu
        root.addSubview(menu, positioned: .above, relativeTo: nil)
        positionCommands()
        menu.reveal(commandIndex)
    }
    func positionCommands() {
        guard let menu = commandMenu, let root = menu.superview else { return }
        let width = min(238, max(1, root.bounds.width - 16))
        let height = min(CGFloat(commandChoices.count) * 26 + 6, max(32, root.bounds.height - 44), 188)
        var actual = NSRange()
        let caret = firstRect(forCharacterRange: selectedRange(), actualRange: &actual)
        let local = window.map { root.convert($0.convertFromScreen(caret), from: nil) } ?? .zero
        let x = max(8, min(root.bounds.width - width - 8, local.minX))
        let y = max(32, min(root.bounds.height - height - 6, local.maxY + 3))
        menu.frame = NSRect(x: x, y: y, width: width, height: height)
        menu.needsLayout = true
    }
    func applyCommand(_ command: EditorCommand) {
        guard !hasMarkedText(), let storage = textStorage else {
            dismissCommands()
            return
        }
        var selection = selectedRange()
        let trigger = commandRange
        guard selection.location != NSNotFound, NSMaxRange(selection) <= storage.length else { return }
        beginRichChange(command.title)
        dismissCommands()
        window?.makeFirstResponder(self)
        if let trigger {
            storage.replaceCharacters(in: trigger, with: "")
            selection = NSRange(location: trigger.location, length: 0)
        }
        switch command.kind {
        case .bold:
            if selection.length > 0 {
                var allBold = true
                storage.enumerateAttribute(.promptBold, in: selection) { value, _, _ in
                    if (value as? Bool) != true { allBold = false }
                }
                if allBold {
                    storage.removeAttribute(.promptBold, range: selection)
                } else {
                    storage.addAttribute(.promptBold, value: true, range: selection)
                }
                refreshRichStyles(in: selection)
                setSelectedRange(selection)
                typingAttributes = semanticTypingAttributes(at: selection.location)
            } else {
                setSelectedRange(selection)
                var attrs = typingAttributes
                let enabled = (attrs[.promptBold] as? Bool) != true
                if enabled { attrs[.promptBold] = true } else { attrs.removeValue(forKey: .promptBold) }
                let oldFont = attrs[.font] as? NSFont ?? .systemFont(ofSize: 14)
                attrs[.font] = NSFontManager.shared.convert(
                    oldFont,
                    toHaveTrait: enabled || attrs[.promptHeading] != nil ? .boldFontMask : .unboldFontMask)
                typingAttributes = attrs
            }
        case .heading, .code, .paragraph:
            // Block styles apply to complete native paragraphs; visible text stays
            // free of Markdown delimiters and retains its exact Unicode contents.
            let source = storage.string as NSString
            var block = source.paragraphRange(for: selection)
            if block.length == 0, case .heading(let level) = command.kind {
                setSelectedRange(selection)
                var attrs = baseAttributes
                attrs[.promptHeading] = level
                attrs[.font] = NSFont.systemFont(ofSize: level == 1 ? 26 : 20, weight: .bold)
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 3
                paragraph.paragraphSpacing = 10
                attrs[.paragraphStyle] = paragraph
                typingAttributes = attrs
                didChangeText()
                breakUndoCoalescing()
                return
            }
            if block.length == 0, command.kind == .paragraph {
                setSelectedRange(selection)
                typingAttributes = baseAttributes
                didChangeText()
                breakUndoCoalescing()
                return
            }
            if block.length == 0 {
                storage.replaceCharacters(in: NSRange(location: block.location, length: 0), with: "\n")
                storage.setAttributes(baseAttributes, range: NSRange(location: block.location, length: 1))
                block.length = 1
            }
            for key in [NSAttributedString.Key.promptHeading, .promptCode, .promptCodeID] {
                storage.removeAttribute(key, range: block)
            }
            switch command.kind {
            case .heading(let level): storage.addAttribute(.promptHeading, value: level, range: block)
            case .code(let language):
                storage.addAttributes(
                    [.promptCode: language, .promptCodeID: UUID().uuidString], range: block)
            default: break
            }
            refreshRichStyles(in: block)
            setSelectedRange(selection)
            typingAttributes = semanticTypingAttributes(at: selection.location)
        }
        didChangeText()
        scrollRangeToVisible(selectedRange())
        breakUndoCoalescing()
    }
    func exitCodeBlock() -> Bool {
        guard !hasMarkedText(), let storage = textStorage, storage.length > 0,
            typingAttributes[.promptCodeID] != nil
        else { return false }
        let at = min(selectedRange().location, storage.length - 1)
        var block = NSRange()
        guard
            storage.attribute(
                .promptCodeID, at: at, longestEffectiveRange: &block,
                in: NSRange(location: 0, length: storage.length)) != nil
        else { return false }
        beginRichChange("回到正文")
        var end = NSMaxRange(block)
        if end > 0 && ![10, 13].contains((storage.string as NSString).character(at: end - 1)) {
            storage.replaceCharacters(in: NSRange(location: end, length: 0), with: "\n")
            storage.setAttributes(
                semanticTypingAttributes(at: end - 1), range: NSRange(location: end, length: 1))
            end += 1
        }
        storage.replaceCharacters(in: NSRange(location: end, length: 0), with: "\n")
        storage.setAttributes(baseAttributes, range: NSRange(location: end, length: 1))
        setSelectedRange(NSRange(location: end, length: 0))
        typingAttributes = baseAttributes
        didChangeText()
        breakUndoCoalescing()
        scrollRangeToVisible(selectedRange())
        return true
    }
    func handleCommandKey(_ event: NSEvent) -> Bool {
        guard !hasMarkedText() else {
            dismissCommands()
            return false
        }
        if [36, 76].contains(event.keyCode), event.modifierFlags.contains(.option), exitCodeBlock() {
            return true
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers?.lowercased() == "b"
        {
            applyCommand(EditorCommand.all[2])
            return true
        }
        guard commandMenu != nil else { return false }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift) {
            dismissCommands()
            return false
        }
        if event.keyCode == 53 {
            dismissCommands()
            return true
        }
        if [125, 126].contains(event.keyCode) {
            commandIndex =
                (commandIndex + (event.keyCode == 125 ? 1 : commandChoices.count - 1)) % commandChoices.count
            showCommands()
            return true
        }
        if [36, 76].contains(event.keyCode), !event.modifierFlags.contains(.command) {
            applyCommand(commandChoices[commandIndex])
            return true
        }
        if [123, 124, 115, 119, 116, 121].contains(event.keyCode) { dismissCommands() }
        return false
    }
}
