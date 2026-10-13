import AppKit

enum PanelPage: Int, CaseIterable { case library, general, data }

final class ManagerController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate, NSSplitViewDelegate
{
    unowned let host: AppDelegate
    let preferences: UserDefaults
    let root = ManagerRoot()
    let split = ManagerSplit()
    var currentPage = PanelPage.library
    var navigation: [GroupNavigationButton] = []
    let groupHeading = NSTextField(labelWithString: "")
    let version = NSTextField(
        labelWithString: "PromptShelf-Open "
            + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.7.3"))
    let settingsScroll = NSScrollView()
    lazy var settings = ControlSettingsView(host: host, preferences: preferences)
    lazy var dataPage = DataPage(host: host)
    let navigationPane = FlippedView()
    let searchIcon = NSImageView()
    let groupsPane = FlippedView(), listPane = FlippedView(), editorPane = FlippedView()
    let groupTable = ManagerTable(), promptTable = ManagerTable()
    let groupScroll = NSScrollView(), listScroll = NSScrollView(), bodyScroll = NSScrollView()
    let search = PromptSearchField()
    let titleField = NSTextField()
    let body = GuidedTextView()
    let issue = NSTextField(labelWithString: "")
    let empty = NSTextField(labelWithString: "选择一条提示词，开始编辑")
    let listEmpty = NSTextField(wrappingLabelWithString: "")
    let batchBar = FlippedView()
    let batchLabel = NSTextField(labelWithString: "")
    let movePopup = NSPopUpButton()
    var renamingGroup: String?
    var selectedGroup: String?
    var selectedID: UUID?
    var filtered: [Prompt] = []
    var dirty = false, loading = false, saving = false, bulk = false, newDraft = false
    var draftGroup = ""
    var timer: Timer?
    var monitor: Any?
    var menuHandlers: [MenuAction] = []
    var drafts: [String: (String, String, RichTextDocument?)] = [:]
    var partials: [UUID: (String, String, RichTextDocument?)] = [:]
    let addGroup = ActionButton(symbol: "plus", label: "新建分组") {}
    let addPrompt = ActionButton(symbol: "plus", label: "新建提示词") {}
    let bulkButton = ActionButton(symbol: "checklist", label: "批量选择") {}
    let importButton = ActionButton(symbol: "square.and.arrow.down", label: "导入提示词") {}
    let exportButton = ActionButton(symbol: "square.and.arrow.up", label: "导出全部提示词") {}
    let moreButton = ActionButton(symbol: "ellipsis", label: "更多") {}
    let deleteBatch = ActionButton(symbol: "trash", label: "删除选中的提示词") {}
    let cancelBatch = ActionButton(symbol: "xmark", label: "退出批量选择") {}

    init(host: AppDelegate, preferences: UserDefaults = OpenEnvironment.preferences) {
        self.host = host
        self.preferences = preferences
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "PromptShelf-Open"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 460)
        window.titlebarAppearsTransparent = true
        window.delegate = self
        window.center()
        if host.presentsWindows { window.setFrameAutosaveName("PromptShelfOpen.PromptLibrary") }
        window.contentView = root
        root.wantsLayer = true
        root.resized = { [weak self] in self?.layoutPanes() }
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        // Divider hit areas remain available for resizing; color blends into the canvas.
        split.addArrangedSubview(listPane)
        split.addArrangedSubview(editorPane)
        root.addSubview(split)
        root.addSubview(navigationPane)
        root.addSubview(groupsPane)
        navigationPane.wantsLayer = true
        groupsPane.wantsLayer = true
        let links = [
            ("提示词库", "text.quote"), ("通用设置", "slider.horizontal.3"),
            ("数据与备份", "externaldrive"),
        ]
        for (index, link) in links.enumerated() {
            let button = GroupNavigationButton(
                title: link.0, icon: link.1, frame: .zero, selected: index == 0, fontSize: 12
            ) { [weak self] in self?.navigate(PanelPage(rawValue: index)!) }
            navigation.append(button)
            navigationPane.addSubview(button)
        }
        settingsScroll.drawsBackground = false
        settingsScroll.hasVerticalScroller = false
        settingsScroll.autohidesScrollers = true
        settingsScroll.borderType = .noBorder
        settingsScroll.scrollerStyle = .overlay
        settingsScroll.documentView = settings
        settingsScroll.isHidden = true
        settings.changed = { [weak self] in self?.refresh() }
        root.addSubview(settingsScroll)
        setupTable(groupTable, in: groupScroll, pane: groupsPane)
        setupTable(promptTable, in: listScroll, pane: listPane)
        groupTable.rowHeight = 34
        groupTable.allowsMultipleSelection = false
        groupTable.doubleClickRow = { [weak self] row in
            guard let self, row >= 2, row < self.numberOfRows(in: self.groupTable), self.flush() else {
                return
            }
            self.groupTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            self.renameSelectedGroup()
        }
        groupTable.registerForDraggedTypes([ManagerDragType.group, ManagerDragType.prompt])
        promptTable.registerForDraggedTypes([ManagerDragType.prompt])
        groupTable.setDraggingSourceOperationMask(.move, forLocal: true)
        promptTable.setDraggingSourceOperationMask(.move, forLocal: true)
        groupTable.contextMenu = { [weak self] row in self?.groupMenu(row) }
        promptTable.contextMenu = { [weak self] row in self?.promptMenu(row) }
        search.placeholderString = "搜索提示词"
        search.font = .systemFont(ofSize: 12)
        search.isBordered = false
        search.delegate = self
        search.setAccessibilityLabel("搜索当前分组的标题或正文")
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.setAccessibilityElement(false)
        listPane.addSubview(searchIcon)
        listPane.addSubview(search)
        listPane.addSubview(addPrompt)
        listPane.addSubview(bulkButton)
        listEmpty.font = .systemFont(ofSize: 12)
        listEmpty.textColor = Palette.secondary
        listPane.addSubview(listEmpty)
        groupHeading.font = .systemFont(ofSize: 11, weight: .medium)
        groupsPane.addSubview(groupHeading)
        groupsPane.addSubview(addGroup)
        version.font = .systemFont(ofSize: 10)
        navigationPane.addSubview(version)
        for view in [importButton, exportButton, moreButton] {
            root.addSubview(view)
        }
        titleField.placeholderString = "给提示词起个名字"
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.delegate = self
        titleField.setAccessibilityLabel("管理面板标题")
        body.isRichText = true
        body.font = .systemFont(ofSize: 13)
        body.allowsUndo = true
        body.isAutomaticQuoteSubstitutionEnabled = false
        body.isAutomaticDashSubstitutionEnabled = false
        body.isAutomaticTextReplacementEnabled = false
        body.isAutomaticSpellingCorrectionEnabled = false
        body.isVerticallyResizable = true
        body.isHorizontallyResizable = false
        body.autoresizingMask = [.width]
        body.textContainerInset = NSSize(width: 0, height: 4)
        body.textContainer?.widthTracksTextView = true
        body.delegate = self
        body.setAccessibilityLabel("管理面板正文")
        bodyScroll.borderType = .noBorder
        bodyScroll.drawsBackground = false
        bodyScroll.hasVerticalScroller = false
        bodyScroll.autohidesScrollers = true
        bodyScroll.scrollerStyle = .overlay
        bodyScroll.documentView = body
        issue.font = .systemFont(ofSize: 11)
        issue.textColor = .systemRed
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = Palette.secondary
        for view in [titleField, bodyScroll, issue, empty] {
            editorPane.addSubview(view)
        }
        batchLabel.font = .systemFont(ofSize: 11)
        batchLabel.textColor = Palette.secondary
        for view in [batchLabel, movePopup, deleteBatch, cancelBatch] {
            batchBar.addSubview(view)
        }
        listPane.addSubview(batchBar)
        batchBar.isHidden = true
        movePopup.font = .systemFont(ofSize: 11)
        movePopup.isBordered = false
        movePopup.target = self
        movePopup.action = #selector(batchMove)
        addGroup.actionBlock = { [weak self] in self?.createGroup() }
        addPrompt.actionBlock = { [weak self] in self?.createPrompt() }
        bulkButton.actionBlock = { [weak self] in self?.toggleBulk() }
        cancelBatch.actionBlock = { [weak self] in self?.toggleBulk() }
        deleteBatch.actionBlock = { [weak self] in self?.deleteSelected() }
        importButton.actionBlock = { [weak self] in
            guard let self, self.flush() else { return }
            self.host.importLibrary()
        }
        exportButton.actionBlock = { [weak self] in
            guard let self, self.flush() else { return }
            self.host.exportLibrary()
        }
        moreButton.actionBlock = { [weak self] in self?.showMore() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(libraryChanged), name: PromptStore.didChange, object: host.store)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self, self.currentPage == .library, self.dirty, event.window === self.window else {
                return event
            }
            let point = self.editorPane.convert(event.locationInWindow, from: nil)
            if !self.editorPane.bounds.contains(point), !self.flush() { return nil }
            return event
        }
        layoutPanes()
        let prefs = preferences
        split.setPosition(
            prefs.object(forKey: "Manager.listWidth") == nil
                ? 236 : CGFloat(prefs.double(forKey: "Manager.listWidth")), ofDividerAt: 0)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        timer?.invalidate()
        if let monitor { NSEvent.removeMonitor(monitor) }
        NotificationCenter.default.removeObserver(self)
    }
    func setupTable(_ table: NSTableView, in scroll: NSScrollView, pane: NSView) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        pane.addSubview(scroll)
    }
    func layoutPanes() {
        guard root.bounds.width > 0 else { return }
        let contentFrame = NSRect(x: 150, y: 0, width: root.bounds.width - 150, height: root.bounds.height)
        navigationPane.frame = NSRect(x: 0, y: 0, width: 150, height: root.bounds.height)
        groupsPane.frame = NSRect(x: 150, y: 0, width: 140, height: root.bounds.height)
        split.frame = NSRect(x: 290, y: 0, width: root.bounds.width - 290, height: root.bounds.height)
        settingsScroll.frame = contentFrame
        if let page = settingsScroll.documentView as? FormPage {
            page.frame.size = NSSize(
                width: contentFrame.width, height: max(page.contentHeight, contentFrame.height))
            page.needsLayout = true
        }
        for (index, button) in navigation.enumerated() {
            button.frame = NSRect(x: 8, y: 78 + CGFloat(index) * 34, width: 134, height: 30)
        }
        version.frame = NSRect(x: 16, y: root.bounds.height - 24, width: 128, height: 16)
        layoutColumns()
    }
    func layoutColumns() {
        groupHeading.frame = NSRect(x: 12, y: 12 + labelOpticalOffset, width: 90, height: 18)
        groupScroll.frame = NSRect(
            x: 0, y: 42, width: groupsPane.bounds.width, height: max(0, groupsPane.bounds.height - 42))
        addGroup.frame = NSRect(x: groupsPane.bounds.width - 34, y: 8, width: 26, height: 26)
        let w = listPane.bounds.width
        let h = listPane.bounds.height
        searchIcon.frame = NSRect(x: 12, y: 14, width: 14, height: 14)
        search.frame = NSRect(x: 32, y: 11 + labelOpticalOffset, width: max(70, w - 102), height: 20)
        addPrompt.frame = NSRect(x: w - 66, y: 7, width: 28, height: 28)
        bulkButton.frame = NSRect(x: w - 34, y: 7, width: 28, height: 28)
        listScroll.frame = NSRect(x: 0, y: 42, width: w, height: max(0, h - 42 - (bulk ? 74 : 0)))
        listEmpty.frame = NSRect(x: 12, y: 59, width: w - 24, height: 44)
        batchBar.frame = NSRect(x: 0, y: h - 74, width: w, height: 74)
        batchLabel.frame = NSRect(x: 10, y: 4, width: w - 20, height: 19)
        movePopup.frame = NSRect(x: 6, y: 32, width: w - 78, height: 26)
        deleteBatch.frame = NSRect(x: w - 64, y: 32, width: 26, height: 26)
        cancelBatch.frame = NSRect(x: w - 34, y: 32, width: 26, height: 26)
        let ew = editorPane.bounds.width
        let eh = editorPane.bounds.height
        titleField.frame = NSRect(x: 16, y: 8.5 + labelOpticalOffset, width: max(80, ew - 124), height: 25)
        bodyScroll.frame = NSRect(x: 16, y: 46, width: max(80, ew - 32), height: max(80, eh - 78))
        body.fitScrollViewport()
        issue.frame = NSRect(x: 16, y: eh - 28, width: ew - 32, height: 20)
        empty.frame = NSRect(x: 16, y: 10 + labelOpticalOffset, width: ew - 32, height: 22)
        let right = root.bounds.width
        importButton.frame = NSRect(x: right - 100, y: 9, width: 24, height: 24)
        exportButton.frame = NSRect(x: right - 70, y: 9, width: 24, height: 24)
        moreButton.frame = NSRect(x: right - 40, y: 9, width: 24, height: 24)
    }
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        let total = splitView.bounds.width - splitView.dividerThickness
        let listWidth = min(
            max(220, listPane.frame.width > 0 ? listPane.frame.width : 236), max(220, total - 280))
        let h = splitView.bounds.height
        let d = splitView.dividerThickness
        listPane.frame = NSRect(x: 0, y: 0, width: listWidth, height: h)
        editorPane.frame = NSRect(x: listWidth + d, y: 0, width: total - listWidth, height: h)
        layoutColumns()
    }
    func splitViewDidResizeSubviews(_ notification: Notification) { layoutColumns() }
    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        220
    }
    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        splitView.bounds.width - 280
    }
    func windowDidResize(_ notification: Notification) { layoutPanes() }
    func windowWillClose(_ notification: Notification) { settings.pets.animationEnabled = false }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard flush() else { return false }
        parkDraft()
        rememberLayout()
        return true
    }
    func rememberLayout() {
        preferences.set(Double(listPane.frame.width), forKey: "Manager.listWidth")
    }
    func windowDidResignKey(_ notification: Notification) { _ = flush() }
    func present() {
        refresh()
        window?.makeKeyAndOrderFront(nil)
        settings.pets.animationEnabled = currentPage == .general
        NSApp.activate(ignoringOtherApps: true)
    }
    func navigate(_ page: PanelPage) {
        window?.endEditing(for: nil)
        guard flush() else { return }
        window?.makeFirstResponder(nil)
        currentPage = page
        settings.pets.animationEnabled = page == .general
        split.isHidden = page != .library
        settingsScroll.isHidden = page == .library
        groupsPane.isHidden = page != .library
        groupScroll.isHidden = page != .library
        groupHeading.isHidden = page != .library
        addGroup.isHidden = page != .library
        for view in [importButton, exportButton, moreButton] {
            view.isHidden = page != .library
        }
        for (index, button) in navigation.enumerated() { button.select(index == page.rawValue) }
        switch page {
        case .library: break
        case .general:
            settingsScroll.documentView = settings
            settings.refresh()
        case .data:
            settingsScroll.documentView = dataPage
            dataPage.refresh()
        }
        settingsScroll.contentView.scroll(to: .zero)
        layoutPanes()
    }
    func showSettings() {
        navigate(.general)
        present()
    }
    func setEditorVisible(_ value: Bool) {
        titleField.isHidden = !value
        bodyScroll.isHidden = !value
        empty.isHidden = value
        if !value { issue.stringValue = "" }
    }
    @objc func libraryChanged() {
        if saving { return }
        if let group = selectedGroup, !group.isEmpty, !host.store.library.groups.contains(group) {
            selectedGroup = nil
        }
        refresh()
    }
    func updateEmptyState() {
        listEmpty.isHidden = !filtered.isEmpty
        listEmpty.stringValue = search.stringValue.isEmpty ? "点击 ＋，添加你的第一条提示词" : "没有找到相关提示词"
    }
    func refresh() {
        let ids = selectedPromptIDs
        loading = true
        let library = host.store.library
        filtered = library.prompts.filter { prompt in
            (selectedGroup == nil || prompt.group == selectedGroup)
                && (search.stringValue.isEmpty || prompt.title.localizedStandardContains(search.stringValue)
                    || prompt.body.localizedStandardContains(search.stringValue))
        }
        if !dirty && !newDraft && !bulk, !filtered.contains(where: { $0.id == selectedID }) {
            selectedID = filtered.first?.id
        }
        updateEmptyState()
        if renamingGroup == nil { groupTable.reloadData() }
        promptTable.reloadData()
        let groupRow =
            selectedGroup == nil
            ? 0 : selectedGroup == "" ? 1 : (library.groups.firstIndex(of: selectedGroup!) ?? -2) + 2
        if groupRow >= 0 {
            groupTable.selectRowIndexes(IndexSet(integer: groupRow), byExtendingSelection: false)
        }
        let selected = bulk ? Set(ids) : Set(selectedID.map { [$0] } ?? [])
        let indexes = IndexSet(
            filtered.enumerated().compactMap { selected.contains($0.element.id) ? $0.offset : nil })
        promptTable.selectRowIndexes(indexes, byExtendingSelection: false)
        if !dirty && !newDraft {
            if let id = selectedID, let prompt = library.prompts.first(where: { $0.id == id }) {
                if titleField.stringValue != prompt.title || body.string != prompt.body
                    || body.richTextSnapshot() != prompt.richText
                {
                    load(prompt)
                }
            } else {
                selectedID = nil
                setEditorVisible(false)
            }
        }
        root.layer?.backgroundColor = Palette.background.cgColor
        navigationPane.layer?.backgroundColor = Palette.hover.withAlphaComponent(0.6).cgColor
        groupsPane.layer?.backgroundColor = Palette.background.cgColor
        search.textColor = Palette.ink
        searchIcon.contentTintColor = Palette.secondary
        groupHeading.textColor = Palette.secondary
        version.textColor = Palette.secondary
        for (index, button) in navigation.enumerated() { button.select(index == currentPage.rawValue) }
        window?.backgroundColor = Palette.background
        window?.appearance = host.panel.appearance
        groupTable.backgroundColor = Palette.background
        promptTable.backgroundColor = Palette.background
        titleField.textColor = Palette.ink
        body.backgroundColor = Palette.background
        body.textColor = Palette.ink
        body.insertionPointColor = Palette.ink
        loading = false
        updateBatch()
        settings.refresh()
        dataPage.refresh()
        layoutPanes()
    }


    var selectedPromptIDs: [UUID] {
        promptTable.selectedRowIndexes.compactMap { $0 < filtered.count ? filtered[$0].id : nil }
    }

}
