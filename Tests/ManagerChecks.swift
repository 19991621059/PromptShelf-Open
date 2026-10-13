import AppKit

@MainActor
func runManagerChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "PromptShelf-manager-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PromptStore(directory: root)
    try store.change { $0.prompts = Library.retiredExamples }
    let host = AppDelegate(store: store, presentsWindows: false)
    host.panel = ShelfPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    host.panel.isReleasedWhenClosed = false
    host.render()
    let suite = "PromptShelf-check-\(UUID().uuidString)"
    let prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    let manager = ManagerController(host: host, preferences: prefs)
    defer {
        manager.window?.close()
        // AppKit can defer table layout past this fixture's host lifetime.
        // Detach callbacks before the WebKit checks pump the run loop.
        manager.groupTable.delegate = nil
        manager.groupTable.dataSource = nil
        manager.promptTable.delegate = nil
        manager.promptTable.dataSource = nil
        manager.window?.delegate = nil
        manager.window?.contentView = nil
        host.panel.close()
    }
    precondition(manager.window?.title == "PromptShelf-Open")
    let initialFrame = manager.window!.frame
    manager.navigate(.general)
    precondition(manager.window!.frame == initialFrame)
    precondition(!manager.settingsScroll.hasVerticalScroller)
    precondition(manager.split.isHidden && !manager.settingsScroll.isHidden && manager.importButton.isHidden)
    manager.settings.theme.selectItem(at: 1)
    manager.settings.changeTheme()
    precondition(PromptStore(directory: root).library.theme == "dark")
    manager.settings.pin.state = .on
    manager.settings.changePin()
    precondition(PromptStore(directory: root).library.pinned == true)
    host.expanded = true
    manager.settings.widthField.doubleValue = 424
    manager.settings.heightField.doubleValue = 286
    manager.settings.changeSize()
    precondition(store.library.panelWidth == 424 && store.library.panelHeight == 286)
    precondition(host.width == 424 && host.expandedHeight == 286)
    manager.settings.widthField.doubleValue = 100
    manager.settings.changeSize()
    manager.settings.layoutSubtreeIfNeeded()
    precondition(
        store.library.panelWidth == 424 && !manager.settings.issue.stringValue.isEmpty
            && !manager.settings.issue.isHidden)
    manager.settings.resetFloatingWindow()
    precondition(
        store.library.panelWidth == nil && store.library.panelHeight == nil
            && store.library.dockEdge == "left")
    host.expanded = false
    host.render()
    manager.navigate(.data)
    precondition(manager.window!.frame == initialFrame)
    precondition(manager.currentPage == .data)
    precondition(manager.navigation.count == 3, "Only local library, settings and backups are available")
    manager.navigate(.library)
    precondition(!manager.split.isHidden && manager.settingsScroll.isHidden && !manager.importButton.isHidden)
    precondition(manager.window!.frame == initialFrame)
    precondition(manager.groupsPane.frame.minX == manager.navigationPane.frame.maxX)
    precondition(manager.split.frame.minX == manager.groupsPane.frame.maxX)
    precondition(manager.groupScroll.frame.minY == 42)
    precondition(manager.search.isEditable && manager.search.isSelectable)
    let previewCell = ManagerCell(frame: NSRect(x: 0, y: 0, width: 236, height: 72))
    previewCell.showGroup = true
    previewCell.layout()
    let previewLineHeight = NSLayoutManager().defaultLineHeight(for: previewCell.preview.font!)
    precondition(previewCell.preview.frame.height >= previewLineHeight * 2)
    precondition(previewCell.heading.frame.minY >= previewCell.preview.frame.maxY + 2)
    precondition(previewCell.detail.frame.maxY <= previewCell.preview.frame.minY)
    let first = store.library.prompts[0]
    let second = store.library.prompts[1]
    manager.load(first)
    let exact = "第一行\n\n  空格不能丢失\n第二行"
    manager.body.string = exact
    manager.dirty = true
    precondition(manager.flush())
    precondition(PromptStore(directory: root).library.prompts.first?.body == exact)
    manager.body.string = ""
    manager.dirty = true
    manager.parkDraft()
    manager.load(second)
    manager.load(first)
    precondition(manager.body.string == "" && manager.dirty)
    manager.body.string = exact
    precondition(manager.flush())
    manager.selectedGroup = "常用"
    manager.refresh()
    manager.createPrompt()
    precondition(manager.newDraft && manager.draftGroup == "常用")
    manager.titleField.stringValue = "草稿标题"
    manager.dirty = true
    precondition(manager.flush() && store.library.prompts.count == 3)
    manager.parkDraft()
    manager.createPrompt()
    precondition(manager.titleField.stringValue == "草稿标题")
    manager.body.string = exact
    manager.dirty = true
    precondition(manager.flush() && store.library.prompts.last?.title == "草稿标题")
    precondition(store.library.prompts.last?.group == "常用")
    let addedID = manager.selectedID!
    let exported = try Data(contentsOf: store.file)
    manager.body.string = "保存失败时保留文字"
    manager.dirty = true
    try Data("bad-data".utf8).write(to: store.file)
    precondition(!manager.flush() && manager.dirty && manager.body.string == "保存失败时保留文字")
    try exported.write(to: store.file, options: .atomic)
    precondition(manager.flush())
    try store.change { $0.groups.append(contentsOf: ["分析", "web"]) }
    precondition(manager.reorderGroup("web", before: 0))
    precondition(store.library.groups.first == "web")
    manager.move([first.id, second.id], to: "分析")
    precondition(store.library.prompts.filter { $0.group == "分析" }.count == 2)
    manager.selectedGroup = "分析"
    manager.refresh()
    precondition(manager.reorderPrompts([second.id], before: first.id))
    precondition(store.library.prompts.first { $0.group == "分析" }?.id == second.id)
    manager.selectedGroup = nil
    manager.search.stringValue = "草稿标题"
    manager.refresh()
    precondition(manager.filtered.count == 1 && manager.filtered.first?.id == addedID)
    manager.search.stringValue = "空格不能丢失"
    manager.refresh()
    precondition(manager.filtered.contains { $0.id == first.id })
    manager.search.stringValue = ""
    manager.refresh()
    manager.toggleBulk()
    manager.promptTable.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
    precondition(manager.selectedPromptIDs.count == 2)
    let cell = manager.promptTable.view(atColumn: 0, row: 2, makeIfNecessary: true) as! ManagerCell
    cell.choose?()
    precondition(manager.selectedPromptIDs.count == 3)
    cell.choose?()
    precondition(manager.selectedPromptIDs.count == 2)
    let selected = manager.selectedPromptIDs
    manager.move(selected, to: "web")
    precondition(store.library.prompts.filter { selected.contains($0.id) && $0.group == "web" }.count == 2)
    manager.load(store.library.prompts[0])
    let selectionID = manager.selectedID!
    try store.change { library in library.prompts[0].body = "悬浮框同步来的修改" }
    precondition(manager.selectedID == selectionID && manager.body.string == "悬浮框同步来的修改")
    manager.window?.makeKeyAndOrderFront(nil)
    manager.selectedGroup = "web"
    manager.refresh()
    let renameRow = store.library.groups.firstIndex(of: "web")! + 2
    manager.groupTable.doubleClickRow?(renameRow)
    let renameCell =
        manager.groupTable.view(atColumn: 0, row: renameRow, makeIfNecessary: true) as! ManagerGroupCell
    precondition(renameCell.name.isEditable && renameCell.name.isSelectable)

    renameCell.name.stringValue = "网页提示词"
    manager.controlTextDidEndEditing(
        Notification(name: NSControl.textDidEndEditingNotification, object: renameCell.name))
    precondition(store.library.groups.contains("网页提示词") && !store.library.groups.contains("web"))
    precondition(store.library.prompts.filter { selected.contains($0.id) && $0.group == "网页提示词" }.count == 2)
    precondition(PromptStore(directory: root).library.groups.contains("网页提示词"))
    manager.split.setPosition(270, ofDividerAt: 0)
    precondition(manager.windowShouldClose(manager.window!))
    precondition(abs(prefs.double(forKey: "Manager.listWidth") - 270) < 2)
    // Saving the first prompt must remove the empty hint immediately, without reopening the page.
    try store.change { $0.prompts = [] }
    manager.bulk = false
    manager.selectedGroup = nil
    manager.search.stringValue = ""
    manager.refresh()
    precondition(!manager.listEmpty.isHidden)
    manager.createPrompt()
    manager.titleField.stringValue = "第一条"
    manager.body.string = "自动保存后隐藏空列表提示"
    manager.dirty = true
    precondition(manager.flush() && manager.filtered.count == 1 && manager.listEmpty.isHidden)
    print(
        "PASS: manager exact autosave, partial drafts, failed-save retention, search, group/prompt ordering, batch move, shared-store updates, split width persistence"
    )
}
