import AppKit

final class MenuAction: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func invoke() { block() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    let store: PromptStore
    let presentsWindows: Bool
    let editorPreferences: UserDefaults
    init(
        store: PromptStore = PromptStore(), presentsWindows: Bool = true,
        editorPreferences: UserDefaults = OpenEnvironment.preferences
    ) {
        self.store = store
        self.presentsWindows = presentsWindows
        self.editorPreferences = editorPreferences
        super.init()
    }
    var hotKey: HotKeyController?
    var workflowWorkspace: WorkflowWorkspace?
    var workflowWindow: WorkflowWindowController?
    var manager: ManagerController?
    var panel: ShelfPanel!
    var statusItem: NSStatusItem!
    var directoryPanel: NSPanel?
    var editPanel: ShelfPanel?
    var editor: InlineEditor?
    var pendingNewEditors: [String: InlineEditor] = [:]
    var pendingEditors: [UUID: InlineEditor] = [:]
    var outsideClickMonitor: Any?
    var localClickMonitor: Any?
    var directoryControlFrames: [NSRect] = []
    var settlingEditor = false
    var lastClickedPromptID: UUID?
    var lastClickPoint = NSPoint.zero
    var lastClickTime: TimeInterval = 0
    var shelfBulk = false
    var shelfSelection = Set<UUID>()
    var searchVisible = false
    var cachedShelf: ShelfPresentation?
    var expanded = false
    var selectedGroup: String?
    var directoryOverride: Bool?
    var searchText = ""
    let searchField = PromptSearchField()
    var selectedPromptID: UUID?
    var pendingRevealID: UUID?
    var rowFrames: [UUID: NSRect] = [:]
    var liveAnchor: NSPoint?
    var movingScreen: NSScreen?
    var dragStartMouse = NSPoint.zero
    var dragStartAnchor = NSPoint.zero
    var dragStartFrame = NSRect.zero
    let orbView = HandleView(frame: .zero)
    var menuActions: [MenuAction] = []
    var rows: [PromptRow] = []
    var screen: NSScreen {
        movingScreen ?? NSScreen.screens.first { displayID($0) == store.library.screenID } ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
    var expandedHeight: CGFloat = 220
    var scrollOffset: CGFloat = 0
    var scrollView: NSScrollView?
    var notice: NSTextField?
    var noticeTimer: Timer?
    var liveEditorWidth: CGFloat?
    var editorWidth: CGFloat {
        if let liveEditorWidth { return liveEditorWidth }
        let saved = editorPreferences.double(forKey: "PromptShelfOpenEditorWidth")
        return saved.isFinite && saved > 0 ? CGFloat(min(2000, max(240, saved))) : 300
    }
    var liveGroupRailWidth: CGFloat?
    let groupRailResize = GroupRailResize(frame: .zero)
    var liveWidth: CGFloat?
    var liveHeight: CGFloat?
    var layingOut = false
    var renderedWindowSize = NSSize.zero
    let rightResize = ResizeView(edge: .right)
    let bottomResize = ResizeView(edge: .bottom)
    let cornerResize = ResizeView(edge: .corner)
    var width: CGFloat {
        min(screen.visibleFrame.width - 8, liveWidth ?? CGFloat(store.library.panelWidth ?? 352))
    }
    var editorExtra: CGFloat { 0 }
    var anchor: NSPoint {
        liveAnchor ?? ShelfGeometry.anchor(store.library, screen: screen.frame, visible: screen.visibleFrame)
    }
    var directoryVisible: Bool { directoryOverride ?? (contextPrompts.count >= 6) }
    var contextPrompts: [Prompt] {
        store.library.prompts.filter { selectedGroup == nil || $0.group == selectedGroup }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMainMenu()
        NotificationCenter.default.addObserver(
            self, selector: #selector(libraryDidChange), name: PromptStore.didChange, object: store)
        selectedGroup = store.library.activeGroup
        searchField.delegate = self
        searchField.placeholderString = "查找"
        searchField.font = .systemFont(ofSize: 11)
        searchField.isBordered = false
        searchField.setAccessibilityLabel("查找提示词标题或正文")
        orbView.context = { [weak self] in self?.settingsMenu() }
        orbView.toggle = { [weak self] in
            guard let self else { return }
            self.expanded ? self.collapse() : self.expand()
        }
        orbView.began = { [weak self] in self?.beginDrag(at: $0) }
        orbView.moved = { [weak self] in self?.drag(to: $0) }
        orbView.finished = { [weak self] in self?.savePosition() }
        panel = ShelfPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        panel.title = "PromptShelf-Open"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        if #available(macOS 13.0, *) { panel.collectionBehavior.insert(.canJoinAllApplications) }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.onEscape = { [weak self] in
            guard let self else { return }
            if self.editor != nil {
                self.editor = nil
                self.render()
            } else {
                self.collapse()
            }
        }
        panel.routePointer = { [weak self] event in
            guard let self else { return false }
            let point = self.panel.convertPoint(toScreen: event.locationInWindow)
            if !self.shelfBulk, event.clickCount >= 2,
                event.timestamp - self.lastClickTime <= NSEvent.doubleClickInterval + 0.1,
                hypot(point.x - self.lastClickPoint.x, point.y - self.lastClickPoint.y) < 6,
                let id = self.lastClickedPromptID,
                let prompt = self.store.library.prompts.first(where: { $0.id == id })
            {
                self.openEditor(prompt)
                return true
            }
            self.lastClickedPromptID =
                self.rows.first { row in
                    guard let host = row.window else { return false }
                    return host.convertToScreen(row.convert(row.bounds, to: nil)).contains(point)
                }?.prompt.id
            self.lastClickPoint = point
            self.lastClickTime = event.timestamp
            return false
        }
        panel.pointerCompletion = { [weak self] event in
            guard let self, let draft = self.editor, let host = draft.window else { return nil }
            let point = host.convertPoint(toScreen: event.locationInWindow)
            let frame = host.convertToScreen(draft.convert(draft.bounds, to: nil))
            guard !frame.contains(point) else { return nil }
            return { [weak self, weak draft] in
                guard let self, let draft, self.editor === draft else { return }
                _ = self.finishEditing()
            }
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
        ]) { [weak self] _ in
            self?.outsidePointerDown()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
        ]) { [weak self] event in
            if let self, self.searchVisible, !self.isInsideSearch(event) {
                DispatchQueue.main.async { [weak self] in self?.dismissSearch() }
            }
            if let self, event.window !== self.panel, event.window !== self.editPanel,
                event.window !== self.directoryPanel
            {
                DispatchQueue.main.async { [weak self] in self?.outsidePointerDown() }
            } else if let self, self.shouldDismissDirectory(for: event) {
                // Let the clicked control finish its action before rebuilding the panels.
                DispatchQueue.main.async { [weak self] in self?.dismissDirectory() }
            }
            return event
        }
        for grip in [rightResize, bottomResize, cornerResize] {
            grip.changed = { [weak self] size, finished in self?.resize(to: size, finished: finished) }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "text.quote", accessibilityDescription: "PromptShelf-Open")
        statusItem.button?.toolTip = "PromptShelf-Open"
        rebuildStatusMenu()
        hotKey = HotKeyController { [weak self] in self?.showManager() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSApp.addObserver(self, forKeyPath: "effectiveAppearance", options: [.new], context: nil)
        render()
        panel.orderFrontRegardless()
        if let warning = store.loadWarning { DispatchQueue.main.async { self.showError(warning) } }
        if !CommandLine.arguments.contains("--background"),
            OpenEnvironment.preferences.object(forKey: "openControlPanelOnLaunch") as? Bool != false
        {
            DispatchQueue.main.async { self.showWorkflows() }
        }
    }

    func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    func selectGroup(_ group: String?) {
        guard prepareContextChange() else { return }
        directoryOverride = false
        selectedGroup = group
        searchText = ""
        selectedPromptID = nil
        scrollOffset = 0
        scrollView = nil
        do {
            try store.change { $0.activeGroup = group }
            render()
        } catch { showError(error.localizedDescription) }
    }
    @discardableResult func finishEditing() -> Bool {
        guard !settlingEditor else { return false }
        guard let draft = editor else { return true }
        guard !draft.bodyField.hasMarkedText(),
            (draft.titleField.currentEditor() as? NSTextView)?.hasMarkedText() != true
        else { return false }
        settlingEditor = true
        defer { settlingEditor = false }
        if let fieldEditor = draft.titleField.currentEditor() {
            draft.titleField.stringValue = fieldEditor.string
        }
        draft.window?.endEditing(for: nil)
        panel.endEditing(for: nil)
        let title = draft.titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = draft.bodyField.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty && body.isEmpty && draft.promptID == nil {
            editor = nil
            pendingNewEditors.removeValue(forKey: draft.group)
            render()
            return true
        }
        if body.isEmpty {
            // Keep an unfinished draft without blocking navigation or writing an empty prompt.
            if let id = draft.promptID {
                pendingEditors[id] = draft
            } else {
                pendingNewEditors[draft.group] = draft
            }
            editor = nil
            render()
            return true
        }
        if title.isEmpty {
            draft.titleField.stringValue =
                draft.promptID.flatMap { id in store.library.prompts.first { $0.id == id }?.title }
                ?? String(
                    body.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(20)
                        ?? body.prefix(20))
        }
        draft.save()
        return editor == nil
    }
    func prepareContextChange() -> Bool { finishEditing() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard (manager?.flush() ?? true) && finishEditing() else { return .terminateCancel }
        manager?.rememberLayout()
        if let workspace = workflowWorkspace {
            if workspace.running {
                let alert = NSAlert()
                alert.messageText = "取消正在运行的任务并退出？"
                alert.informativeText = "已完成的步骤结果会保存到本机。"
                alert.addButton(withTitle: "取消任务并退出")
                alert.addButton(withTitle: "继续运行")
                guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            }
            Task {
                do { try await workspace.finishForTermination(); NSApp.reply(toApplicationShouldTerminate: true) }
                catch { showError("退出前保存失败：" + error.localizedDescription); NSApp.reply(toApplicationShouldTerminate: false) }
            }
            return .terminateLater
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
    }
    func reveal(_ id: UUID) {
        guard finishEditing() else { return }
        selectedPromptID = id
        pendingRevealID = id
        render()
    }
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? PromptSearchField === searchField else { return }
        searchText = searchField.stringValue
        scrollOffset = 0
        scrollView = nil
        render()
    }

    func resize(to size: NSSize, finished: Bool) {
        liveWidth = min(screen.visibleFrame.width - 8, max(312, size.width))
        liveHeight = min(screen.visibleFrame.height - editorExtra - 12, max(140, size.height - editorExtra))
        render()
        if finished {
            do {
                try store.change {
                    $0.panelWidth = Double(width)
                    $0.panelHeight = Double(expandedHeight)
                }
            } catch { showError(error.localizedDescription) }
            liveWidth = nil
            liveHeight = nil
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard expanded, !layingOut, panel.inLiveResize else { return }
        liveWidth = max(312, width + panel.frame.width - renderedWindowSize.width)
        liveHeight = max(140, expandedHeight + panel.frame.height - renderedWindowSize.height)
        render()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard expanded, !layingOut else { return }
        resize(to: NSSize(width: width, height: expandedHeight + editorExtra), finished: true)
    }

    func beginDrag(at point: NSPoint) {
        dragStartMouse = point
        dragStartAnchor = anchor
        dragStartFrame = panel.frame
    }
    func drag(to point: NSPoint) {
        let proposed = NSPoint(
            x: dragStartAnchor.x + point.x - dragStartMouse.x,
            y: dragStartAnchor.y + point.y - dragStartMouse.y)
        let target = NSScreen.screens.first { $0.frame.contains(point) } ?? screen
        movingScreen = target
        liveAnchor = ShelfGeometry.clamp(proposed, screen: target.frame, visible: target.visibleFrame)
        // Child windows follow their parent. Keep text views, lists and WebGL canvases
        // mounted during tracking; perform docking and full layout only on release.
        cachedShelf = nil
        panel.setFrameOrigin(
            NSPoint(
                x: dragStartFrame.minX + anchor.x - dragStartAnchor.x,
                y: dragStartFrame.minY + anchor.y - dragStartAnchor.y))
    }
    func savePosition() {
        editor?.preferredFrame = nil
        let target = screen
        let (snapped, edge) = ShelfGeometry.snap(anchor, screen: target.frame, visible: target.visibleFrame)
        do {
            try store.change { library in
                library.screenID = displayID(target)
                library.positionX = Double((snapped.x - target.frame.minX) / (target.frame.width - 38))
                library.positionY = Double((target.frame.maxY - snapped.y - 38) / (target.frame.height - 38))
                library.dockEdge = edge
            }
            liveAnchor = nil
            movingScreen = nil
            render()
        } catch { showError(error.localizedDescription) }
    }

    func expand() {
        expanded = true
        if !restoreShelfPresentation() { render() }
        panel.orderFrontRegardless()
    }
    func collapse() {
        guard expanded || editor != nil else { return }
        guard finishEditing() else { return }
        panel.endEditing(for: nil)
        expanded = false
        directoryOverride = false
        searchText = ""
        searchVisible = false
        shelfBulk = false
        shelfSelection.removeAll()
        if !restoreShelfPresentation() { render() }
        panel.orderFrontRegardless()
    }
    func togglePin() {
        mutate { $0.pinned = !($0.pinned ?? false) }
        rebuildStatusMenu()
    }
    func automaticallyCollapse() {
        // App activation and input-method transitions must not finish an active draft.
        guard editor == nil else { return }
        directoryOverride = false
        searchText = ""
        if store.library.pinned == true {
            guard finishEditing() else { return }
            panel.endEditing(for: nil)
            render()
        } else {
            collapse()
        }
    }
    func shouldDismissDirectory(for event: NSEvent) -> Bool {
        guard expanded, directoryVisible, let window = event.window, window !== directoryPanel else {
            return false
        }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        return window !== panel || !directoryControlFrames.contains { $0.contains(point) }
    }
    func dismissDirectory() {
        guard expanded, directoryVisible else { return }
        directoryOverride = false
        render()
    }
    @objc func newPrompt() { openEditor(nil) }
    @objc func screenChanged() {
        render()
        panel.orderFrontRegardless()
    }
    @objc func spaceChanged() { automaticallyCollapse() }
    @objc func activeApplicationChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        automaticallyCollapse()
    }
    func applicationDidResignActive(_ notification: Notification) { automaticallyCollapse() }
    override func observeValue(
        forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        if keyPath == "effectiveAppearance", store.library.theme == "system", panel != nil { render() }
    }

    func copy(_ prompt: Prompt, row: PromptRow?) {
        let pasteboard = OpenEnvironment.pasteboard
        pasteboard.clearContents()
        guard pasteboard.setString(prompt.body, forType: .string) else {
            showError("复制失败，请重试")
            return
        }
        dismissDirectory()
        let copiedRow = rows.first { $0.prompt.id == prompt.id } ?? row
        for row in rows {
            row.copied = false
        }
        copiedRow?.copied = true
        copiedRow?.setAccessibilityLabel("\(prompt.title)，已复制")
        copiedRow?.displayIfNeeded()
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak copiedRow] _ in
            copiedRow?.copied = false
            copiedRow?.setAccessibilityLabel("\(prompt.title)，单击复制，双击编辑")
        }
    }

    func mutate(_ update: (inout Library) -> Void) {
        guard finishEditing() else { return }
        do {
            try store.change(update)
            render()
        } catch { showError(error.localizedDescription) }
    }

    func focusEditor(_ field: NSTextField) {
        guard presentsWindows else { return }
        let host = field.window ?? panel!
        host.makeKeyAndOrderFront(nil)
        host.makeFirstResponder(field)
    }

    func focusDraft(_ draft: InlineEditor) {
        guard presentsWindows else { return }
        guard let host = draft.window else { return }
        host.makeKeyAndOrderFront(nil)
        if draft.promptID != nil {
            host.makeFirstResponder(host)
            draft.scroll.contentView.scroll(to: .zero)
            draft.scroll.reflectScrolledClipView(draft.scroll.contentView)
        } else {
            host.makeFirstResponder(draft.titleField)
            (draft.titleField.currentEditor() as? NSTextView)?.setSelectedRange(
                NSRange(location: draft.titleField.stringValue.utf16.count, length: 0))
        }
    }

    @objc func libraryDidChange() {
        guard panel != nil else { return }
        if let group = selectedGroup, !group.isEmpty, !store.library.groups.contains(group) {
            selectedGroup = store.library.activeGroup
        }
        render()
        workflowWindow?.window?.appearance = panel.appearance
    }




    @objc func showManager() {
        guard finishEditing() else { return }
        collapse()
        if manager == nil { manager = ManagerController(host: self) }
        manager?.present()
    }
    @objc func showSettings() {
        showManager()
        manager?.showSettings()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWorkflows()
        return true
    }

    @objc func showWorkflows() {
        do {
            if workflowWorkspace == nil { workflowWorkspace = try WorkflowWorkspace(directory: store.root) }
            if workflowWindow == nil { workflowWindow = WorkflowWindowController(host: self, workspace: workflowWorkspace!) }
            workflowWindow?.present()
        } catch { showError("工作流数据无法读取，原文件保留：" + error.localizedDescription) }
    }

    func openEditor(_ prompt: Prompt?) {
        guard manager?.flush() ?? true else { return }
        if let editor, editor.promptID == prompt?.id {
            if !expanded { expand() }
            focusDraft(editor)
            return
        }
        guard finishEditing() else { return }
        directoryOverride = false
        searchText = ""
        expanded = true
        let draft: InlineEditor
        if let prompt, let pending = pendingEditors.removeValue(forKey: prompt.id) {
            draft = pending
        } else if prompt == nil, let pending = pendingNewEditors.removeValue(forKey: selectedGroup ?? "") {
            draft = pending
        } else {
            draft = InlineEditor(prompt: prompt, selectedGroup: selectedGroup)
        }
        if let prompt {
            draft.savedBody = prompt.body
            draft.savedRichText = prompt.richText
            let size = (prompt.body as NSString).boundingRect(
                with: NSSize(width: max(150, width - 130), height: 600), options: [.usesLineFragmentOrigin],
                attributes: [.font: NSFont.systemFont(ofSize: 12)])
            draft.preferredHeight = min(260, max(180, ceil(size.height) + 48))
        }
        let savedHeight = editorPreferences.double(forKey: "PromptShelfEditorHeight")
        if savedHeight.isFinite && savedHeight >= 180 { draft.preferredHeight = CGFloat(savedHeight) }
        draft.saved = { [weak self, weak draft] title, body, group in
            guard let self, let draft else { return }
            if let id = draft.promptID, !self.store.library.prompts.contains(where: { $0.id == id }) {
                throw StoreError.invalid("这条提示词已删除，当前编辑内容仍然保留。请复制后新建提示词。")
            }
            var savedID = draft.promptID
            try self.store.change { library in
                if let id = draft.promptID {
                    guard let index = library.prompts.firstIndex(where: { $0.id == id }) else { return }
                    library.prompts[index].title = title
                    library.prompts[index].body = body
                    library.prompts[index].richText = draft.bodyField.richTextSnapshot()
                } else {
                    let prompt = Prompt(
                        title: title, body: body, group: group, richText: draft.bodyField.richTextSnapshot())
                    savedID = prompt.id
                    library.prompts.append(prompt)
                }
            }
            draft.promptID = savedID
            draft.savedBody = body
            draft.savedRichText = draft.bodyField.richTextSnapshot()
            if draft.keepsOpenAfterSave {
                draft.validation.stringValue = ""
                draft.needsLayout = true
                return
            }
            draft.window?.endEditing(for: nil)
            self.panel.endEditing(for: nil)
            self.editor = nil
            self.searchText = ""
            self.render()
        }
        draft.closed = { [weak self] in
            self?.panel.endEditing(for: nil)
            self?.editor = nil
            self?.render()
        }
        draft.relayout = { [weak self] in self?.render() }
        editor = draft
        // Opening a side editor preserves the list scroll position.
        render()
        focusDraft(draft)
    }

}
