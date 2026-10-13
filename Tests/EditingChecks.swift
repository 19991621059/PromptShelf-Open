import AppKit

@MainActor
func runEditingChecks() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "PromptShelf-edit-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PromptStore(directory: root)
    try store.change { $0.prompts = Library.retiredExamples }
    let delegate = AppDelegate(store: store, presentsWindows: false)
    delegate.panel = ShelfPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    delegate.panel.isReleasedWhenClosed = false
    defer { delegate.panel.close() }
    var immediateClicks = 0
    let responseHandle = HandleView(frame: .zero)
    responseHandle.toggle = { immediateClicks += 1 }
    responseHandle.activate(clickCount: 1)
    precondition(immediateClicks == 1, "Single click must respond synchronously")
    responseHandle.activate(clickCount: 2)
    precondition(
        immediateClicks == 2, "Rapid repeated clicks must toggle synchronously")
    delegate.selectedGroup = "常用"
    for edge in ["left", "right", "top", "bottom"] {
        try store.change {
            $0.panelWidth = 424
            $0.panelHeight = 266
            $0.dockEdge = edge
            $0.positionX = 0.5
            $0.positionY = 0.5
        }
        delegate.expanded = true
        delegate.render()
        precondition(delegate.cornerResize.panelSize == NSSize(width: 424, height: 266))
        delegate.resize(to: NSSize(width: 444, height: 286), finished: true)
        precondition(store.library.panelWidth == 444 && store.library.panelHeight == 286)
    }
    delegate.directoryOverride = false
    delegate.render()
    let cachedRows = delegate.rows
    let cachedFrame = delegate.panel.frame
    let toggleStart = ProcessInfo.processInfo.systemUptime
    for _ in 0..<100 {
        delegate.collapse()
        delegate.expand()
    }
    precondition(delegate.panel.frame == cachedFrame)
    precondition(
        zip(cachedRows, delegate.rows).allSatisfy { $0 === $1 }, "Visibility switches reuse prompt rows")
    print(
        "PASS: 200 cached visibility switches in \(Int((ProcessInfo.processInfo.systemUptime - toggleStart) * 1000)) ms"
    )
    let mountedRoot = delegate.panel.contentView!
    let mountedHandle = delegate.orbView.superview!
    delegate.collapse()
    delegate.expand()
    precondition(
        delegate.panel.contentView === mountedRoot && delegate.orbView.superview === mountedHandle,
        "Expanding preserves the handle and its 3D canvas attachment")
    let shelf = delegate.panel.contentView!.subviews.first { $0 !== delegate.orbView }!
    let brand = shelf.subviews.first { $0.identifier?.rawValue == "shelf.brand" } as! NSTextField
    precondition(brand.stringValue == "PromptShelf-Open" && brand.alignment == .center)
    precondition(abs(brand.frame.midX - delegate.groupRailWidth(in: shelf.bounds.width) / 2) < 0.5)
    delegate.resizeGroupRail(to: 140, finished: true)
    precondition(delegate.groupRailResize.columnWidth == 140)
    precondition(PromptStore(directory: root).library.groupRailWidth == 140)
    precondition(delegate.groupRailWidth(in: 260) == 100)
    delegate.resizeGroupRail(to: 86, finished: true)
    delegate.directoryOverride = false
    delegate.render()
    let contentWidth = delegate.panel.contentView!.subviews.last!.frame.width
    delegate.directoryOverride = true
    delegate.render()
    precondition(delegate.panel.contentView!.subviews.last!.frame.width == contentWidth)
    precondition(delegate.directoryPanel != nil)
    let floatingBody = delegate.panel.contentView!.subviews.last!
    let bodyOnScreen = delegate.panel.convertToScreen(floatingBody.convert(floatingBody.bounds, to: nil))
    precondition(delegate.directoryPanel!.frame.minX == bodyOnScreen.maxX + 6)
    func clickEvent(in window: NSWindow, screenPoint: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: window.convertPoint(fromScreen: screenPoint), modifierFlags: [],
            timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: 1)!
    }
    precondition(
        !delegate.shouldDismissDirectory(
            for: clickEvent(in: delegate.directoryPanel!, screenPoint: delegate.directoryPanel!.frame.origin))
    )
    for frame in delegate.directoryControlFrames {
        precondition(
            !delegate.shouldDismissDirectory(
                for: clickEvent(in: delegate.panel, screenPoint: NSPoint(x: frame.midX, y: frame.midY))))
    }
    precondition(
        delegate.shouldDismissDirectory(
            for: clickEvent(
                in: delegate.panel, screenPoint: NSPoint(x: bodyOnScreen.midX, y: bodyOnScreen.midY))))
    delegate.dismissDirectory()
    precondition(delegate.expanded && !delegate.directoryVisible)
    delegate.directoryOverride = true
    delegate.render()
    delegate.collapse()
    precondition(!delegate.expanded && delegate.directoryPanel?.isVisible == false)
    delegate.expanded = true
    delegate.directoryOverride = true
    delegate.render()
    let first = store.library.prompts[0]
    let second = store.library.prompts[1]
    let changed = "第一行\n\n  保留空格\n修改后的内容"
    let clickRow = PromptRow(prompt: first, frame: NSRect(x: 0, y: 0, width: 240, height: 60))
    var copyCount = 0
    var editCount = 0
    clickRow.onCopy = { copyCount += 1 }
    clickRow.onEdit = { editCount += 1 }
    clickRow.activate(clickCount: 1)
    precondition(copyCount == 1, "No double-click delay for copying")
    clickRow.activate(clickCount: 2)
    RunLoop.main.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.1))
    precondition(copyCount == 1 && editCount == 1, "First click copies immediately; second opens editor")
    clickRow.activate(clickCount: 1)
    RunLoop.main.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.1))
    precondition(copyCount == 2 && editCount == 1, "Single click must copy immediately")

    delegate.openEditor(first)
    precondition(
        delegate.editor!.bodyField.string == first.body, "Opening an existing prompt must populate its body")
    delegate.render()
    precondition(delegate.editor!.bodyField.string == first.body, "Rendering must preserve the loaded body")
    precondition(delegate.editor!.window === delegate.editPanel)
    precondition(!delegate.directoryVisible)
    let activeDraft = delegate.editor!
    activeDraft.bodyField.setSelectedRange(NSRange(location: 2, length: 0))
    delegate.editPanel!.makeFirstResponder(activeDraft.bodyField)
    delegate.render()
    precondition(delegate.editor === activeDraft && delegate.editPanel!.contentView === activeDraft)
    precondition(delegate.editPanel!.firstResponder === activeDraft.bodyField)
    precondition(activeDraft.bodyField.selectedRange() == NSRange(location: 2, length: 0))
    delegate.automaticallyCollapse()
    precondition(delegate.expanded && delegate.editor === activeDraft)
    var savedByReturn = false
    let input = PromptTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    input.string = "正文"
    input.setSelectedRange(NSRange(location: 2, length: 0))
    input.saveAction = { savedByReturn = true }
    func returnEvent(_ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 1, windowNumber: 0, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    }
    input.keyDown(with: returnEvent([]))
    precondition(!savedByReturn && input.string == "正文\n")
    input.keyDown(with: returnEvent(.command))
    precondition(savedByReturn)
    delegate.directoryOverride = true
    delegate.render()
    precondition(!delegate.editPanel!.frame.intersects(delegate.directoryPanel!.frame))
    precondition(delegate.rows.count == delegate.filtered.count)
    precondition(
        delegate.editor!.cancel.superview == nil && delegate.editor!.saveButton.superview == nil
            && delegate.editor!.stretch.superview == nil)
    delegate.editor!.bodyField.string = ""
    precondition(delegate.finishEditing())
    precondition(store.library.prompts.first { $0.id == first.id }!.body == first.body)
    delegate.openEditor(first)
    precondition(
        delegate.editor!.hasEmptyExistingDraft && !delegate.editor!.restoreButton.isHidden
            && !delegate.editor!.draftNotice.isHidden)
    delegate.editor!.restoreSavedBody()
    delegate.editor!.layoutSubtreeIfNeeded()
    precondition(delegate.editor!.bodyField.string == first.body && delegate.editor!.restoreButton.isHidden)
    delegate.editor!.bodyField.string = changed
    delegate.openEditor(second)
    precondition(delegate.editor?.promptID == second.id)
    precondition(PromptStore(directory: root).library.prompts.first { $0.id == first.id }?.body == changed)
    delegate.selectGroup("分析")
    precondition(delegate.editor == nil && delegate.selectedGroup == "分析")
    let count = store.library.prompts.count
    delegate.openEditor(nil)
    precondition(delegate.finishEditing() && delegate.editor == nil && store.library.prompts.count == count)
    delegate.openEditor(nil)
    precondition(delegate.editor!.window === delegate.editPanel && delegate.editorExtra == 0)
    let newDraft = delegate.editor!
    delegate.render()
    delegate.automaticallyCollapse()
    precondition(delegate.editor === newDraft && delegate.expanded)
    delegate.editor!.titleField.stringValue = "自动保存"
    delegate.editor!.bodyField.string = changed
    precondition(delegate.finishEditing())
    precondition(store.library.prompts.last?.body == changed && store.library.prompts.last?.group == "分析")
    delegate.openEditor(nil)
    delegate.editor!.titleField.stringValue = "未写完的标题"
    precondition(delegate.finishEditing() && delegate.editor == nil)
    precondition(store.library.prompts.count == count + 1)
    delegate.selectGroup("常用")
    delegate.openEditor(nil)
    precondition(delegate.editor?.titleField.stringValue == "" && delegate.editor?.group == "常用")
    precondition(delegate.finishEditing())
    delegate.selectGroup("分析")
    delegate.openEditor(nil)
    precondition(delegate.editor?.titleField.stringValue == "未写完的标题" && delegate.editor?.group == "分析")
    delegate.editor!.bodyField.string = "继续完成的正文"
    precondition(delegate.finishEditing())
    delegate.openEditor(nil)
    delegate.editor!.bodyField.string = "只有正文也能保存\n第二行"
    precondition(delegate.finishEditing() && store.library.prompts.last?.title == "只有正文也能保存")
    delegate.openEditor(first)
    delegate.editor!.bodyField.string = "点击屏幕保存并收起"
    try store.change { $0.pinned = true }
    delegate.outsidePointerDown()
    precondition(delegate.expanded && delegate.editor != nil, "Pinned editor stays open")
    try store.change { $0.pinned = false }
    delegate.outsidePointerDown()
    precondition(!delegate.expanded && delegate.editor == nil)
    precondition(store.library.prompts.first { $0.id == first.id }?.body == "点击屏幕保存并收起")
    delegate.selectGroup(nil)
    delegate.expand()
    delegate.toggleShelfBulk()
    let bulkRow = delegate.rows.first { $0.prompt.id == first.id }!
    precondition(bulkRow.accessibilityPerformPress())
    precondition(
        delegate.shelfSelection == [first.id], "Accessible press selects instead of copying in bulk mode")
    delegate.shelfSelection = [first.id, second.id]
    delegate.moveShelfSelection(to: "分析")
    precondition(
        store.library.prompts.filter { [first.id, second.id].contains($0.id) }.allSatisfy { $0.group == "分析" }
    )
    precondition(delegate.shelfSelection.isEmpty)
    delegate.toggleShelfBulk()
    let savedFile = try Data(contentsOf: store.file)
    delegate.openEditor(first)
    delegate.editor!.bodyField.string = "存储失败时需要保留的内容"
    try Data("damaged".utf8).write(to: store.file)
    precondition(!delegate.finishEditing() && delegate.editor?.bodyField.string == "存储失败时需要保留的内容")
    try savedFile.write(to: store.file, options: .atomic)
    precondition(delegate.finishEditing())
    let exported = try PromptStore.encode(store.library)
    let imported = PromptStore(directory: root.appendingPathComponent("imported"))
    try imported.change {
        $0.theme = "dark"
        $0.panelWidth = 400
        $0.positionX = 0.3
        $0.dockEdge = ""
    }
    try imported.restore(exported)
    precondition(
        imported.library.theme == "dark" && imported.library.panelWidth == 400
            && imported.library.positionX == 0.3)
    precondition(
        imported.library.prompts == store.library.prompts && imported.library.groups == store.library.groups)
    print(
        "PASS: autosave before switching prompts/groups, empty creation dismissal, incomplete draft recovery, failed-save retention, complete-library export/import"
    )
}
