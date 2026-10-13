import AppKit

struct ShelfPresentation {
    let generation: UInt64
    let group: String?
    let selection: UUID?
    let anchor: NSPoint
    let screen: NSRect
    let directory: Bool
    let frame: NSRect
    let orb: NSRect
}

extension AppDelegate {
    // Keep unchanged controls mounted: switching visibility must not recreate the list.
    func restoreShelfPresentation() -> Bool {
        guard let cached = cachedShelf, let root = panel.contentView,
            editor == nil, !searchVisible, searchText.isEmpty, !shelfBulk, !directoryVisible,
            cached.generation == store.generation, cached.group == selectedGroup,
            cached.selection == selectedPromptID, cached.anchor == anchor,
            cached.screen == screen.visibleFrame, cached.directory == directoryVisible
        else { return false }
        let frame =
            expanded ? cached.frame : NSRect(origin: cached.anchor, size: NSSize(width: 38, height: 38))
        for view in root.subviews where view !== orbView { view.isHidden = !expanded }
        root.setFrameSize(frame.size)
        orbView.frame = expanded ? cached.orb : NSRect(x: 0, y: 0, width: 38, height: 38)
        orbView.setAccessibilityLabel(
            expanded ? "收起 PromptShelf；拖动到任意位置，靠边吸附" : "展开 PromptShelf；拖动到任意位置，靠边吸附")
        if expanded {
            panel.styleMask.insert(.resizable)
            panel.minSize = NSSize(width: 312, height: 140)
        } else {
            panel.styleMask.remove(.resizable)
            panel.minSize = NSSize(width: 38, height: 38)
        }
        renderedWindowSize = frame.size
        panel.setFrame(frame, display: true)
        if expanded && directoryVisible {
            directoryPanel?.orderFrontRegardless()
        } else {
            directoryPanel?.orderOut(nil)
        }
        return true
    }

    func applyAppearance() {
        orbView.petStyle = PetCatalog.normalize(
            OpenEnvironment.preferences.string(forKey: "PromptShelfOpenPet") ?? "classic")
        Palette.dark =
            store.library.theme == "dark"
            || (store.library.theme == "system"
                && NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        panel.appearance = NSAppearance(named: Palette.dark ? .darkAqua : .aqua)
    }

    var filtered: [Prompt] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return contextPrompts.filter {
            query.isEmpty || $0.title.localizedStandardContains(query)
                || $0.body.localizedStandardContains(query) || $0.id == editor?.promptID
        }
    }

    func render() {
        guard !layingOut else { return }
        cachedShelf = nil
        layingOut = true
        defer { layingOut = false }
        applyAppearance()
        var oldFocus: NSView?
        // The side editor stays mounted, including its field editor and marked text.
        if searchField.currentEditor() != nil {
            oldFocus = searchField
            panel.endEditing(for: nil)
        }
        expandedHeight = min(
            screen.visibleFrame.height - editorExtra - 12,
            liveHeight ?? CGFloat(store.library.panelHeight ?? 260))
        if expanded {
            panel.styleMask.insert(.resizable)
            panel.minSize = NSSize(width: 312, height: 140 + editorExtra)
            panel.maxSize = NSSize(
                width: screen.visibleFrame.width - 8, height: screen.visibleFrame.height - 12)
        } else {
            panel.styleMask.remove(.resizable)
            panel.minSize = NSSize(width: 38, height: 38)
        }
        if let scrollView { scrollOffset = scrollView.contentView.bounds.origin.y }
        rows.removeAll()
        rowFrames.removeAll()
        scrollView = nil
        directoryControlFrames.removeAll()
        let geometry = ShelfGeometry.layout(
            anchor: anchor, width: width, height: expandedHeight, creationHeight: expanded ? editorExtra : 0,
            screen: screen.frame, visible: screen.visibleFrame,
            directoryWidth: expanded && directoryVisible ? 104 : 0,
            editingWidth: expanded && editor != nil ? editorWidth : 0)
        let windowFrame = expanded ? geometry.window : geometry.orb
        // Keep the handle and its 3D canvas attached while rebuilding the shelf content.
        let root = panel.contentView as? FlippedView ?? FlippedView(frame: .zero)
        for view in root.subviews where view !== orbView { view.removeFromSuperview() }
        root.setFrameSize(windowFrame.size)
        orbView.frame =
            expanded ? geometry.local(geometry.orb) : NSRect(origin: .zero, size: geometry.orb.size)
        orbView.setAccessibilityLabel(
            expanded ? "收起 PromptShelf；拖动到任意位置，靠边吸附" : "展开 PromptShelf；拖动到任意位置，靠边吸附")
        if orbView.superview !== root {
            orbView.removeFromSuperview()
            root.addSubview(orbView)
        }
        if expanded {
            let container = FlippedView(frame: geometry.local(geometry.panel))
            container.wantsLayer = true
            container.layer?.backgroundColor = Palette.background.cgColor
            container.layer?.cornerRadius = 8
            container.layer?.masksToBounds = true
            root.addSubview(container)
            let railWidth = groupRailWidth(in: container.bounds.width)
            let brand = NSTextField(labelWithString: "PromptShelf-Open")
            brand.identifier = NSUserInterfaceItemIdentifier("shelf.brand")
            brand.font = .systemFont(ofSize: 12, weight: .semibold)
            brand.textColor = Palette.ink
            brand.alignment = .center
            brand.frame = NSRect(x: 6, y: 10, width: railWidth - 12, height: 17)
            container.addSubview(brand)
            let rail = NSScrollView(
                frame: NSRect(x: 6, y: 38, width: railWidth - 12, height: expandedHeight - 46))
            rail.drawsBackground = false
            rail.hasVerticalScroller = true
            rail.autohidesScrollers = true
            rail.scrollerStyle = .overlay
            let groups: [(String, String?)] =
                [("全部", nil)] + store.library.groups.map { ($0, Optional($0)) } + [("未分组", Optional(""))]
            let directory = FlippedView(frame: NSRect(x: 0, y: 0, width: rail.bounds.width, height: 0))
            var directoryY: CGFloat = 0
            for entry in groups {
                let icon = entry.1 == nil ? "square.grid.2x2" : entry.1 == "" ? "tray" : "folder"
                let groupButton = GroupNavigationButton(
                    title: entry.0, icon: icon,
                    frame: NSRect(x: 0, y: directoryY, width: rail.bounds.width, height: 28),
                    selected: selectedGroup == entry.1
                ) { [weak self] in self?.selectGroup(entry.1) }
                if let name = entry.1, !name.isEmpty {
                    groupButton.contextMenuBuilder = { [weak self] in self?.groupContextMenu(name) ?? NSMenu()
                    }
                }
                directory.addSubview(groupButton)
                directoryY += 32
            }
            directory.addSubview(
                ActionButton(
                    symbol: "plus", label: "新分组",
                    frame: NSRect(x: (rail.bounds.width - 24) / 2, y: directoryY, width: 24, height: 24)
                ) { [weak self] in self?.newGroup() })
            directoryY += 28
            directory.setFrameSize(NSSize(width: rail.bounds.width, height: directoryY))
            rail.documentView = directory
            container.addSubview(rail)
            let headerWidth = container.bounds.width - railWidth
            let listWidth = headerWidth
            let header = HeaderView(frame: NSRect(x: railWidth, y: 0, width: headerWidth, height: 35))
            header.began = { [weak self] in self?.beginDrag(at: $0) }
            header.moved = { [weak self] in self?.drag(to: $0) }
            header.finished = { [weak self] in self?.savePosition() }
            container.addSubview(header)
            let compactTools = headerWidth < 278
            let narrowTools = headerWidth < 224
            let toolsWidth: CGFloat = narrowTools ? 90 : compactTools ? 119 : 177
            let textWidth = min(160, max(30, headerWidth - toolsWidth - 18))
            if searchVisible {
                directoryControlFrames.append(
                    NSRect(
                        x: geometry.panel.minX + railWidth + 8, y: geometry.panel.maxY - 30, width: textWidth,
                        height: 24))
                searchField.removeFromSuperview()
                searchField.stringValue = searchText
                let searchBox = SearchActivationView(frame: NSRect(x: 8, y: 6, width: textWidth, height: 24))
                searchBox.activate = { [weak self] in
                    guard let self else { return }
                    self.focusEditor(self.searchField)
                }
                searchBox.wantsLayer = true
                searchBox.layer?.backgroundColor = Palette.hover.cgColor
                searchBox.layer?.cornerRadius = 5
                let icon = NSImageView(frame: NSRect(x: 7, y: 6, width: 12, height: 12))
                icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
                icon.contentTintColor = Palette.secondary
                icon.setAccessibilityElement(false)
                searchBox.addSubview(icon)
                searchField.isBordered = false
                searchField.drawsBackground = false
                searchField.font = .systemFont(ofSize: 11)
                searchField.placeholderString = "查找"
                let inputHeight = min(24, ceil(searchField.fittingSize.height))
                searchField.frame = NSRect(
                    x: 25, y: (24 - inputHeight) / 2, width: max(0, textWidth - 29), height: inputHeight)
                searchBox.addSubview(searchField)
                header.addSubview(searchBox)
            } else {
                let searchBox = SearchActivationView(frame: NSRect(x: 8, y: 6, width: textWidth, height: 24))
                searchBox.activate = { [weak self] in
                    guard let self, self.finishEditing() else { return }
                    self.searchVisible = true
                    self.render()
                    self.focusEditor(self.searchField)
                }
                header.addSubview(searchBox)
                searchBox.addSubview(
                    ActionButton(
                        symbol: "magnifyingglass", label: "查找提示词",
                        frame: NSRect(x: 0, y: 0, width: 24, height: 24)
                    ) { [weak self] in
                        guard let self, self.finishEditing() else { return }
                        self.searchVisible = true
                        self.render()
                        self.focusEditor(self.searchField)
                    })
            }
            let pin = ActionButton(
                symbol: store.library.pinned == true ? "pin.fill" : "pin",
                label: store.library.pinned == true ? "取消固定展开" : "固定展开",
                frame: NSRect(x: headerWidth - toolsWidth, y: 6, width: 25, height: 25)
            ) { [weak self] in self?.togglePin() }
            pin.contentTintColor = store.library.pinned == true ? Palette.ink : Palette.secondary
            pin.setAccessibilityValue(store.library.pinned == true ? "已固定" : "未固定")
            header.addSubview(pin)
            directoryControlFrames.append(
                NSRect(
                    x: geometry.panel.minX + railWidth + headerWidth - toolsWidth + 29,
                    y: geometry.panel.maxY - 31, width: 25, height: 25))
            header.addSubview(
                ActionButton(
                    symbol: "list.bullet", label: directoryVisible ? "收起提示词目录" : "展开提示词目录",
                    frame: NSRect(x: headerWidth - toolsWidth + 29, y: 6, width: 25, height: 25)
                ) { [weak self] in
                    guard let self, self.finishEditing() else { return }
                    self.directoryOverride = !self.directoryVisible
                    if !self.directoryVisible { self.searchText = "" }
                    self.render()
                })
            if !narrowTools {
                header.addSubview(
                    ActionButton(
                        symbol: "plus", label: "在当前分组新建提示词",
                        frame: NSRect(x: headerWidth - toolsWidth + 58, y: 6, width: 25, height: 25)
                    ) { [weak self] in self?.openEditor(nil) })
            }
            if !compactTools {
                header.addSubview(
                    ActionButton(
                        symbol: shelfBulk ? "checklist.checked" : "checklist",
                        label: shelfBulk ? "完成批量管理" : "批量管理",
                        frame: NSRect(x: headerWidth - 90, y: 6, width: 25, height: 25)
                    ) { [weak self] in self?.toggleShelfBulk() })
                header.addSubview(
                    ActionButton(
                        symbol: "square.and.arrow.down", label: "导入提示词",
                        frame: NSRect(x: headerWidth - 61, y: 6, width: 25, height: 25)
                    ) { [weak self] in self?.importLibrary() })
            }
            let more = ActionButton(
                symbol: "ellipsis", label: "更多",
                frame: NSRect(x: headerWidth - 32, y: 6, width: 25, height: 25)
            ) {}
            more.actionBlock = { [weak self, weak more] in
                guard let self, let more else { return }
                self.settingsMenu().popUp(
                    positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY + 2), in: more)
            }
            header.addSubview(more)
            let list = filtered
            let batchHeight: CGFloat = shelfBulk ? 60 : 0
            if shelfBulk {
                container.addSubview(
                    shelfBatchBar(
                        frame: NSRect(x: railWidth, y: 35, width: listWidth - 5, height: batchHeight)))
            }
            let scroll = NSScrollView(
                frame: NSRect(
                    x: railWidth, y: 35 + batchHeight, width: listWidth - 5,
                    height: max(20, expandedHeight - 43 - batchHeight)))
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: listWidth - 5, height: 0))
            var rowY: CGFloat = 0
            for prompt in list {
                let height = PromptRow.height(prompt, width: listWidth - 5)
                let frame = NSRect(x: 0, y: rowY, width: listWidth - 5, height: height)
                rowFrames[prompt.id] = frame
                do {
                    let row = PromptRow(prompt: prompt, frame: frame)
                    row.located = selectedPromptID == prompt.id
                    row.bulk = shelfBulk
                    if shelfBulk {
                        row.setAccessibilityLabel("\(prompt.title)，批量选择")
                        row.setAccessibilityValue(shelfSelection.contains(prompt.id) ? "已选中" : "未选中")
                        row.toolTip = "单击选择或取消选择"
                    }
                    row.selected = shelfSelection.contains(prompt.id)
                    row.onSelect = { [weak self] in
                        guard let self else { return }
                        if !self.shelfSelection.insert(prompt.id).inserted {
                            self.shelfSelection.remove(prompt.id)
                        }
                        self.render()
                    }
                    row.onCopy = { [weak self, weak row] in self?.copy(prompt, row: row) }
                    row.onEdit = { [weak self] in self?.openEditor(prompt) }
                    row.onDelete = { [weak self] in self?.deletePrompt(prompt) }
                    row.onMove = { [weak self] in self?.movePrompt(prompt, direction: $0) }
                    row.groupOptions = store.library.groups
                    row.onGroup = { [weak self] group in
                        self?.mutate { library in
                            if let i = library.prompts.firstIndex(where: { $0.id == prompt.id }) {
                                library.prompts[i].group = group
                            }
                        }
                    }
                    doc.addSubview(row)
                    rows.append(row)
                }
                rowY += height
            }
            if list.isEmpty {
                let label = searchText.isEmpty ? "点击 ＋，添加提示词" : "没有找到相关提示词"
                let guide = NSTextField(wrappingLabelWithString: label)
                guide.font = .systemFont(ofSize: 12)
                guide.textColor = Palette.secondary
                guide.frame = NSRect(x: 11, y: 12, width: listWidth - 24, height: 40)
                doc.addSubview(guide)
            }
            doc.setFrameSize(NSSize(width: listWidth - 5, height: max(50, rowY)))
            scroll.documentView = doc
            container.addSubview(scroll)
            scrollView = scroll
            groupRailResize.removeFromSuperview()
            groupRailResize.columnWidth = railWidth
            groupRailResize.frame = NSRect(x: railWidth - 3, y: 0, width: 6, height: container.bounds.height)
            groupRailResize.changed = { [weak self] width, finished in
                self?.resizeGroupRail(to: width, finished: finished)
            }
            container.addSubview(groupRailResize)

            if let id = pendingRevealID, let frame = rowFrames[id] {
                scrollOffset = frame.minY
                pendingRevealID = nil
            }
            scroll.contentView.scroll(
                to: NSPoint(x: 0, y: min(scrollOffset, max(0, doc.frame.height - scroll.frame.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
            for grip in [rightResize, bottomResize, cornerResize] {
                grip.isHidden = false
                grip.panelSize = NSSize(width: width, height: expandedHeight + editorExtra)
                grip.removeFromSuperview()
                root.addSubview(grip)
            }
            let body = container.frame
            rightResize.frame = NSRect(
                x: body.maxX - 6, y: body.minY + 35, width: 6, height: expandedHeight - 48)
            bottomResize.frame = NSRect(x: body.minX + 8, y: body.maxY - 6, width: body.width - 23, height: 6)
            cornerResize.frame = NSRect(x: body.maxX - 16, y: body.maxY - 16, width: 16, height: 16)
            if let editor, let creation = geometry.creation {
                editor.removeFromSuperview()
                editor.frame = geometry.local(creation)
                root.addSubview(editor)
                editor.needsLayout = true
            }
        }
        if panel.contentView !== root { panel.contentView = root }
        renderedWindowSize = windowFrame.size
        panel.setFrame(windowFrame, display: true)
        updateDirectory(attachedTo: geometry.panel)
        updateSideEditor(attachedTo: geometry.panel)
        root.layoutSubtreeIfNeeded()
        if let oldFocus { oldFocus.window?.makeFirstResponder(oldFocus) }
        rebuildStatusMenu()
        if expanded, editor == nil, !searchVisible, searchText.isEmpty, !shelfBulk {
            cachedShelf = ShelfPresentation(
                generation: store.generation, group: selectedGroup, selection: selectedPromptID,
                anchor: anchor,
                screen: screen.visibleFrame, directory: directoryVisible, frame: windowFrame,
                orb: orbView.frame)
        }
    }

    func updateDirectory(attachedTo body: NSRect) {
        guard expanded, directoryVisible, !filtered.isEmpty else {
            if let directoryPanel {
                panel.removeChildWindow(directoryPanel)
                directoryPanel.orderOut(nil)
            }
            return
        }
        if directoryPanel == nil {
            let index = NSPanel(
                contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                defer: false)
            index.title = "提示词目录"
            index.isReleasedWhenClosed = false
            index.isFloatingPanel = true
            index.becomesKeyOnlyIfNeeded = true
            index.hidesOnDeactivate = false
            index.isOpaque = false
            index.backgroundColor = .clear
            index.hasShadow = true
            index.level = panel.level
            index.collectionBehavior = panel.collectionBehavior
            index.animationBehavior = .none
            directoryPanel = index
        }
        guard let index = directoryPanel else { return }
        let list = filtered
        let height = min(body.height, CGFloat(list.count) * 26 + 12)
        let frame = NSRect(x: body.maxX + 6, y: body.maxY - height, width: 104, height: height)
        let root = FlippedView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.layer?.backgroundColor = Palette.background.cgColor
        root.layer?.cornerRadius = 7
        let scroll = NSScrollView(frame: root.bounds.insetBy(dx: 4, dy: 6))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let doc = FlippedView(
            frame: NSRect(x: 0, y: 0, width: scroll.bounds.width, height: CGFloat(list.count) * 26))
        for (position, prompt) in list.enumerated() {
            let item = TextActionButton(
                title: prompt.title,
                frame: NSRect(x: 0, y: CGFloat(position) * 26, width: doc.bounds.width, height: 24),
                selected: prompt.id == selectedPromptID
            ) { [weak self] in self?.reveal(prompt.id) }
            item.setAccessibilityLabel("目录：\(prompt.title)")
            item.toolTip = prompt.title
            doc.addSubview(item)
        }
        scroll.documentView = doc
        root.addSubview(scroll)
        index.appearance = panel.appearance
        index.contentView = root
        index.setFrame(frame, display: true)
        if presentsWindows {
            if index.parent !== panel { panel.addChildWindow(index, ordered: .above) }
            index.orderFrontRegardless()
        }
    }

    func updateSideEditor(attachedTo body: NSRect) {
        guard expanded, let draft = editor else {
            if let editPanel {
                panel.removeChildWindow(editPanel)
                editPanel.orderOut(nil)
            }
            return
        }
        if editPanel == nil {
            let side = ShelfPanel(
                contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                defer: false)
            side.title = "编辑提示词"
            side.isReleasedWhenClosed = false
            side.isFloatingPanel = true
            side.becomesKeyOnlyIfNeeded = true
            side.hidesOnDeactivate = false
            side.isOpaque = false
            side.backgroundColor = .clear
            side.hasShadow = true
            side.level = panel.level
            side.collectionBehavior = panel.collectionBehavior
            side.animationBehavior = .none
            side.onEscape = { [weak self] in _ = self?.finishEditing() }
            editPanel = side
        }
        guard let side = editPanel else { return }
        let visible = screen.visibleFrame
        let w = min(editorWidth, visible.width - 8)
        let h = min(visible.height - 8, max(180, draft.preferredHeight))
        draft.resizeFrame = { [weak self, weak draft, weak side] frame, finished in
            guard let self, let draft, let side, self.editor === draft else { return }
            self.liveEditorWidth = frame.width
            draft.preferredHeight = frame.height
            draft.preferredFrame = frame
            side.setFrame(frame, display: true)
            draft.needsLayout = true
            draft.layoutSubtreeIfNeeded()
            if finished {
                self.editorPreferences.set(Double(frame.width), forKey: "PromptShelfOpenEditorWidth")
                self.editorPreferences.set(Double(frame.height), forKey: "PromptShelfEditorHeight")
                self.liveEditorWidth = nil
            }
        }

        let right = body.maxX + 6 + (directoryVisible && !filtered.isEmpty ? 110 : 0)
        let x = right + w <= visible.maxX ? right : max(visible.minX, body.minX - w - 6)
        let y = max(visible.minY + 4, min(visible.maxY - h - 4, body.maxY - h))
        var frame = draft.preferredFrame ?? NSRect(x: x, y: y, width: w, height: h)
        frame.size = NSSize(width: w, height: h)
        frame.origin.x = max(visible.minX, min(visible.maxX - w, frame.minX))
        frame.origin.y = max(visible.minY, min(visible.maxY - h, frame.minY))
        if side.contentView !== draft {
            draft.removeFromSuperview()
            side.contentView = draft
        }
        draft.frame = NSRect(x: 0, y: 0, width: w, height: h)
        side.appearance = panel.appearance
        side.setFrame(frame, display: true)
        draft.needsLayout = true
        draft.layoutSubtreeIfNeeded()
        if presentsWindows {
            if side.parent !== panel { panel.addChildWindow(side, ordered: .above) }
            side.orderFrontRegardless()
        }
    }
}
