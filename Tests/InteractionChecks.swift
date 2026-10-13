import AppKit

@MainActor
func runInteractionChecks() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "PromptShelf-interaction-\(UUID())")
    let suite = "PromptShelf-interaction-\(UUID())"
    let prefs = UserDefaults(suiteName: suite)!
    prefs.set(300, forKey: "PromptShelfOpenEditorWidth")
    prefs.set(240, forKey: "PromptShelfEditorHeight")
    defer {
        try? FileManager.default.removeItem(at: root)
        prefs.removePersistentDomain(forName: suite)
    }
    let longText = (0..<2400).map { "第\($0)行 中文输入与光标测试 abcdefghijklmnop 😀  保留空格" }.joined(separator: "\n")
    let legacy = Prompt(title: "长文本", body: longText, group: "回归测试")
    let store = PromptStore(directory: root)
    try store.change {
        $0.groups = ["回归测试"]
        $0.prompts = [legacy]
    }
    let host = AppDelegate(store: store, presentsWindows: false, editorPreferences: prefs)
    host.panel = ShelfPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    host.panel.isReleasedWhenClosed = false
    defer {
        host.panel.close()
        host.editPanel?.close()
    }
    NotificationCenter.default.addObserver(
        host, selector: #selector(AppDelegate.libraryDidChange), name: PromptStore.didChange, object: store)
    defer { NotificationCenter.default.removeObserver(host) }
    host.openEditor(legacy)
    let draft = host.editor!
    let text = draft.bodyField
    host.editPanel!.makeFirstResponder(text)
    precondition(
        text.acceptsFirstMouse(for: nil), "First click must select text even in a nonactivating panel")
    let start = ProcessInfo.processInfo.systemUptime
    for size in [
        NSSize(width: 520, height: 500), NSSize(width: 260, height: 180), NSSize(width: 620, height: 360),
    ] {
        draft.resizeFrame?(NSRect(origin: host.editPanel!.frame.origin, size: size), false)
        text.layoutManager!.ensureLayout(for: text.textContainer!)
        precondition(abs(text.frame.width - draft.scroll.contentSize.width) < 1)
        precondition(text.frame.height >= draft.scroll.contentSize.height)
        precondition(host.editPanel!.firstResponder === text)
        let ns = text.string as NSString
        for target in [0, ns.range(of: "第1200行").location, ns.range(of: "第2399行").location] {
            let glyph = text.layoutManager!.glyphIndexForCharacter(at: target)
            let rect = text.layoutManager!.boundingRect(
                forGlyphRange: NSRange(location: glyph, length: 1), in: text.textContainer!)
            let point = NSPoint(
                x: rect.minX + text.textContainerOrigin.x + 0.1, y: rect.midY + text.textContainerOrigin.y)
            let located = text.characterIndexForInsertion(at: point)
            precondition(
                located == target, "Native hit testing must map each glyph to its UTF-16 caret index")
            text.setSelectedRange(NSRange(location: located, length: 3))
            text.scrollRangeToVisible(text.selectedRange())
            let clip = draft.scroll.contentView
            let visiblePoint = text.convert(point, to: clip.superview)
            precondition(clip.hitTest(visiblePoint) === text, "Scrolled text must retain mouse hit targets")
        }
    }
    let geometryMS = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
    let editStart = ProcessInfo.processInfo.systemUptime
    for index in 0..<30 {
        let target = (text.string as NSString).range(of: "第\(index % 2 == 0 ? 1200 : 2399)行").location
        text.setSelectedRange(NSRange(location: target, length: 0))
        text.insertText("输入", replacementRange: text.selectedRange())
        text.layoutSubtreeIfNeeded()
        text.layoutManager!.ensureLayout(for: text.textContainer!)
        precondition(text.frame.height >= text.layoutManager!.usedRect(for: text.textContainer!).maxY)
    }
    let editMS = Int((ProcessInfo.processInfo.systemUptime - editStart) * 1000)
    text.loadBody(longText, richText: nil)
    text.fitScrollViewport()
    text.undoManager?.removeAllActions()
    text.setSelectedRange(NSRange(location: 2, length: 0))
    let beforeMarked = text.string
    text.setMarkedText(
        "zhong", selectedRange: NSRange(location: 5, length: 0),
        replacementRange: NSRange(location: 2, length: 0))
    precondition(text.hasMarkedText())
    let oldSaved = store.library.prompts[0].body
    precondition(!host.finishEditing(), "Navigation must preserve uncommitted IME text")
    draft.save(keepingOpen: true)
    precondition(store.library.prompts[0].body == oldSaved && host.editor === draft)
    text.insertText("中文", replacementRange: text.markedRange())
    text.unmarkText()
    draft.save(keepingOpen: true)
    precondition(host.editor === draft && host.editPanel!.firstResponder === text)
    precondition(store.library.prompts[0].body != beforeMarked)
    text.setSelectedRange(NSRange(location: 4, length: 0))
    text.insertText("继续编辑", replacementRange: text.selectedRange())
    draft.save(keepingOpen: true)
    let exact = text.string
    precondition(store.library.prompts[0].body == exact)
    precondition(host.finishEditing())
    host.openEditor(store.library.prompts[0])
    precondition(host.editor!.bodyField.string == exact, "Reopening must preserve all long text exactly")

    let input = host.editor!.bodyField
    host.editPanel!.makeFirstResponder(input)
    input.string = ""
    input.setSelectedRange(NSRange(location: 0, length: 0))
    input.insertText("/h2", replacementRange: input.selectedRange())
    input.updateCommands()
    precondition(input.commandMenu != nil && input.commandChoices.first?.kind == .heading(2))
    let enter = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: host.editPanel!.windowNumber, context: nil, characters: "\r",
        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    input.keyDown(with: enter)
    precondition(input.string.isEmpty && input.selectedRange() == NSRange(location: 0, length: 0))
    input.insertText("中文标题😀", replacementRange: input.selectedRange())
    precondition((input.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize == 20)
    input.insertNewline(nil)
    input.insertText("/python", replacementRange: input.selectedRange())
    input.updateCommands()
    precondition(input.commandChoices.count == 1 && input.commandMenu != nil)
    input.keyDown(with: enter)
    input.insertText("print('中文😀')", replacementRange: input.selectedRange())
    precondition(input.string == "中文标题😀\nprint('中文😀')\n", "Commands render styles without Markdown markers")
    let codeRange = (input.string as NSString).range(of: "print('中文😀')")
    let blockID =
        input.textStorage!.attribute(.promptCodeID, at: codeRange.location, effectiveRange: nil) as! String
    input.setCodeLanguage("swift", blockID: blockID)
    precondition(
        input.textStorage!.attribute(.promptCode, at: codeRange.location, effectiveRange: nil) as? String
            == "swift")
    input.dismissCommands()
    input.setSelectedRange(codeRange)
    input.typingAttributes = input.semanticTypingAttributes(at: codeRange.location)
    precondition(input.exitCodeBlock())
    input.insertText("普通正文", replacementRange: input.selectedRange())
    let plainRange = (input.string as NSString).range(of: "普通正文")
    precondition(
        input.textStorage!.attribute(.promptCodeID, at: plainRange.location, effectiveRange: nil) == nil)
    input.setSelectedRange(plainRange)
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    input.undoManager?.removeAllActions()
    input.applyCommand(EditorCommand.all[2])
    precondition(
        input.textStorage!.attribute(.promptBold, at: plainRange.location, effectiveRange: nil) as? Bool
            == true)
    let richBody = input.string
    let richSnapshot = input.richTextSnapshot()!
    precondition(richSnapshot.valid(for: richBody))
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    input.undoManager?.undo()
    precondition(
        input.string == richBody
            && input.textStorage!.attribute(.promptBold, at: plainRange.location, effectiveRange: nil) == nil)
    input.undoManager?.redo()
    precondition(input.richTextSnapshot() == richSnapshot, "Undo/redo restores actual semantic styles")
    input.selectAll(nil)
    let clipboard = NSPasteboard.withUniqueName()
    clipboard.declareTypes([.string], owner: nil)
    precondition(input.writeSelection(to: clipboard, types: input.writablePasteboardTypes))
    precondition(
        clipboard.string(forType: .string) == richBody,
        "Clipboard returns exact prompt text without format markers")
    clipboard.releaseGlobally()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    input.breakUndoCoalescing()
    input.setSelectedRange(NSRange(location: input.string.utf16.count, length: 0))
    input.insertText("\n继续", replacementRange: input.selectedRange())
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    input.undoManager?.undo()
    precondition(input.string == richBody && input.richTextSnapshot() == richSnapshot)
    host.editor!.save(keepingOpen: true)
    precondition(store.library.prompts[0].richText == richSnapshot)
    precondition(host.finishEditing())
    host.openEditor(store.library.prompts[0])
    precondition(
        host.editor!.bodyField.string == richBody && host.editor!.bodyField.richTextSnapshot() == richSnapshot
    )
    let restored = PromptStore(directory: root.appendingPathComponent("imported"))
    try restored.restore(PromptStore.encode(store.library))
    precondition(
        restored.library.prompts[0].body == richBody && restored.library.prompts[0].richText == richSnapshot)
    for literal in ["https://example.com/a", "正文 /code", "/path/to/file", "\n/", "中文"] {
        let ns = literal as NSString
        if literal != "\n/" {
            precondition(
                EditorCommand.trigger(in: ns, selection: NSRange(location: ns.length, length: 0)) == nil)
        }
    }

    for visible in [
        NSRect(x: 0, y: 0, width: 1440, height: 900), NSRect(x: -1920, y: 0, width: 1920, height: 1080),
    ] {
        let initial = NSRect(x: visible.minX + 300, y: 200, width: 360, height: 240)
        for edge in EditorResizeView.Edge.allCases {
            let result = EditorResizeView.resized(
                initial, delta: NSPoint(x: 60, y: 50), edge: edge, visible: visible)
            precondition(visible.contains(result) && result.width >= 240 && result.height >= 180)
            if edge.left { precondition(result.maxX == initial.maxX) }
            if edge.bottom { precondition(result.maxY == initial.maxY) }
            let minimum = EditorResizeView.resized(
                initial, delta: NSPoint(x: 10000, y: -10000), edge: edge, visible: visible)
            precondition(visible.contains(minimum) && minimum.width >= 240 && minimum.height >= 180)
        }
    }
    let lastDraft = host.editor!
    let cursor = NSRange(location: 0, length: 2)
    lastDraft.bodyField.setSelectedRange(cursor)
    host.beginDrag(at: host.anchor)
    let rows = host.rows
    let mounted = host.panel.contentView
    let dragStart = ProcessInfo.processInfo.systemUptime
    for index in 0..<2000 {
        host.drag(
            to: NSPoint(
                x: host.dragStartMouse.x + CGFloat(index % 40), y: host.dragStartMouse.y + CGFloat(index % 30)
            ))
    }
    let dragMS = Int((ProcessInfo.processInfo.systemUptime - dragStart) * 1000)
    precondition(host.panel.contentView === mounted && zip(rows, host.rows).allSatisfy { $0 === $1 })
    precondition(lastDraft.bodyField.selectedRange() == cursor)
    host.savePosition()
    precondition(host.liveAnchor == nil && host.movingScreen == nil)
    precondition(PromptStore(directory: root).library.positionX == store.library.positionX)
    precondition(host.finishEditing())
    host.openEditor(nil)
    let newDraft = host.editor!
    newDraft.bodyField.string = "新提示词"
    newDraft.titleField.stringValue = "连续保存"
    let countBeforeCreate = store.library.prompts.count
    newDraft.save(keepingOpen: true)
    precondition(newDraft.promptID != nil && store.library.prompts.count == countBeforeCreate + 1)
    newDraft.bodyField.string += "\n再次保存"
    newDraft.save(keepingOpen: true)
    precondition(
        store.library.prompts.count == countBeforeCreate + 1
            && store.library.prompts.last!.body == newDraft.bodyField.string)
    let newlySaved = store.library.prompts.last!
    try store.change { $0.prompts.removeAll { $0.id == newlySaved.id } }
    newDraft.save(keepingOpen: true)
    precondition(!newDraft.validation.stringValue.isEmpty && host.editor === newDraft)
    precondition(newDraft.bodyField.string == newlySaved.body)
    try store.change { $0.prompts.append(newlySaved) }
    let manager = ManagerController(host: host, preferences: prefs)
    manager.load(store.library.prompts[0])
    precondition(manager.body.richTextSnapshot() == richSnapshot)
    manager.body.setSelectedRange((manager.body.string as NSString).range(of: "普通正文"))
    manager.body.applyCommand(EditorCommand.all[1])
    let managerRich = manager.body.richTextSnapshot()
    manager.dirty = true
    precondition(manager.flush() && store.library.prompts[0].richText == managerRich)
    let managerUndo = manager.body.undoManager
    manager.refresh()
    precondition(manager.body.richTextSnapshot() == managerRich && manager.body.undoManager === managerUndo)
    manager.load(store.library.prompts[0])
    precondition(manager.body.richTextSnapshot() == managerRich)
    manager.body.setMarkedText(
        "pin", selectedRange: NSRange(location: 3, length: 0),
        replacementRange: NSRange(location: 0, length: 0))
    manager.dirty = true
    precondition(!manager.flush(), "The control panel must also block navigation while composing")
    manager.body.insertText("拼", replacementRange: manager.body.markedRange())
    manager.body.unmarkText()
    precondition(manager.flush())
    manager.timer?.invalidate()
    manager.groupTable.delegate = nil
    manager.groupTable.dataSource = nil
    manager.promptTable.delegate = nil
    manager.promptTable.dataSource = nil
    manager.window?.close()
    print(
        "PASS: \(longText.utf16.count) UTF-16 units, native glyph/caret + scrolled hit tests at 3 sizes in \(geometryMS) ms; 30 native insert+viewport layout operations \(editMS) ms; composition guard, save-and-continue, WYSIWYG headings/bold/code language, Unicode/clipboard/undo+redo/import/reopen"
    )
    print(
        "PASS: eight resize edges and negative display origins; 2000 native window moves in \(dragMS) ms with view identity and selection preserved (CPU submission time, not display latency)"
    )
}

// Optional artifacts use sample text and AppKit view rendering. They are not
// desktop screenshots or evidence of an external input method/mouse session.
@MainActor
func renderInteractionSamples() throws {
    guard let path = ProcessInfo.processInfo.environment["PROMPTSHELF_QA_DIRECTORY"] else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let originalDark = Palette.dark
    defer { Palette.dark = originalDark }
    for dark in [false, true] {
        Palette.dark = dark
        let body =
            "写作助手\n\n请保留原始格式和中文内容。\n\nprint('你好，PromptShelf')\nprint('正在编辑代码块')\n\n输出要求\n先给出结论，再解释关键步骤。\n\n/"
        let ns = body as NSString
        var spans: [RichTextSpan] = []
        let heading = ns.range(of: "写作助手\n")
        spans.append(RichTextSpan(location: heading.location, length: heading.length, heading: 1))
        let bold = ns.range(of: "原始格式")
        spans.append(RichTextSpan(location: bold.location, length: bold.length, bold: true))
        let code = ns.range(of: "print('你好，PromptShelf')\nprint('正在编辑代码块')\n")
        spans.append(
            RichTextSpan(
                location: code.location, length: code.length, codeLanguage: "python",
                codeID: UUID().uuidString))
        let h2 = ns.range(of: "输出要求\n")
        spans.append(RichTextSpan(location: h2.location, length: h2.length, heading: 2))
        let sample = Prompt(
            title: "编辑提示词 · 1.7.3", body: body, group: "测试",
            richText: RichTextDocument(bodyFingerprint: RichTextDocument.fingerprint(body), spans: spans))
        let draft = InlineEditor(prompt: sample, selectedGroup: nil)
        let window = ShelfPanel(
            contentRect: NSRect(x: 200, y: 180, width: 560, height: 600),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = draft
        draft.frame = NSRect(x: 0, y: 0, width: 560, height: 600)
        draft.layoutSubtreeIfNeeded()
        window.makeFirstResponder(draft.bodyField)
        draft.bodyField.setSelectedRange(NSRange(location: sample.body.utf16.count, length: 0))
        draft.bodyField.updateCommands()
        draft.layoutSubtreeIfNeeded()
        draft.bodyField.commandMenu?.layoutSubtreeIfNeeded()
        guard let bitmap = draft.bitmapImageRepForCachingDisplay(in: draft.bounds) else {
            preconditionFailure("Missing bitmap")
        }
        draft.cacheDisplay(in: draft.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(
            to: directory.appendingPathComponent(dark ? "editor-dark.png" : "editor-light.png"))
        window.contentView = nil
        window.close()
    }
    print(
        "PASS: native sample-view renders (light/dark); physical displays: \(NSScreen.screens.map { "\($0.frame) @\($0.backingScaleFactor)x" }.joined(separator: "; "))"
    )
}

@MainActor
func runPointerHandlerChecks() {
    let window = ShelfPanel(
        contentRect: NSRect(x: 100, y: 300, width: 300, height: 240),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer {
        window.contentView = nil
        window.close()
    }
    let handle = HandleView(frame: .zero)
    window.contentView = handle
    var clicks = 0
    var finishes = 0
    var moves: [NSPoint] = []
    handle.toggle = { clicks += 1 }
    handle.moved = { moves.append($0) }
    handle.finished = { finishes += 1 }
    func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }
    handle.mouseDown(with: event(.leftMouseDown, NSPoint(x: 20, y: 20)))
    handle.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 22, y: 22)))
    handle.mouseUp(with: event(.leftMouseUp, NSPoint(x: 22, y: 22)))
    precondition(clicks == 1 && finishes == 0 && moves.isEmpty)
    handle.mouseDown(with: event(.leftMouseDown, NSPoint(x: 20, y: 20)))
    handle.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 50, y: 60)))
    handle.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 20, y: 20)))
    handle.mouseUp(with: event(.leftMouseUp, NSPoint(x: 23, y: 24)))
    precondition(clicks == 1 && finishes == 1 && moves.count == 3)
    precondition(moves.last == window.convertPoint(toScreen: NSPoint(x: 23, y: 24)))
    handle.mouseUp(with: event(.leftMouseUp, NSPoint(x: 23, y: 24)))
    precondition(clicks == 1 && finishes == 1, "Release must end tracking exactly once")
    let grip = EditorResizeView(edge: .bottomRight)
    window.contentView = grip
    var finalFrame: NSRect?
    var finalCount = 0
    grip.changed = { frame, finished in
        if finished {
            finalFrame = frame
            finalCount += 1
        }
    }
    grip.mouseDown(with: event(.leftMouseDown, NSPoint(x: 290, y: 10)))
    grip.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 330, y: -30)))
    grip.mouseUp(with: event(.leftMouseUp, NSPoint(x: 330, y: -30)))
    precondition(
        finalFrame?.size == NSSize(width: 340, height: 280) && finalCount == 1,
        "Corner handler must submit final size exactly once")
    print(
        "PASS: internal native pointer handlers: click threshold, rapid reversal, final release point, duplicate release suppression and corner resize; no desktop mouse synthesis"
    )
}
