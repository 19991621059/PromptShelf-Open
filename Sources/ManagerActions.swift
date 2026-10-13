import AppKit

extension ManagerController {
    func createGroup() {
        guard flush() else { return }
        var name = "新分组"
        var i = 2
        while host.store.library.groups.contains(name) {
            name = "新分组 \(i)"
            i += 1
        }
        guard change({ $0.groups.append(name) }) else { return }
        selectedGroup = name
        refresh()
        renameSelectedGroup()
    }
    @objc func renameSelectedGroup() {
        let row = groupTable.selectedRow
        guard row >= 2,
            let cell = groupTable.view(atColumn: 0, row: row, makeIfNecessary: true) as? ManagerGroupCell
        else { return }
        renamingGroup = cell.group
        cell.name.isEditable = true
        cell.name.isSelectable = true
        cell.name.isEnabled = true
        cell.name.selectText(nil)
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
            let cell = field.superview as? ManagerGroupCell, let old = cell.group
        else { return }
        renamingGroup = nil
        field.isEditable = false
        field.isSelectable = false
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host.store.library.groups.contains(old), !name.isEmpty, name != old, name != "全部",
            name != "未分组", !host.store.library.groups.contains(name)
        else {
            refresh()
            return
        }
        selectedGroup = name
        if !change({ library in
            if let i = library.groups.firstIndex(of: old) { library.groups[i] = name }
            for i in library.prompts.indices where library.prompts[i].group == old {
                library.prompts[i].group = name
            }
            if library.activeGroup == old { library.activeGroup = name }
        }) {
            selectedGroup = old
        } else {
            if let draft = drafts.removeValue(forKey: old) { drafts[name] = draft }
            if draftGroup == old { draftGroup = name }
        }
        host.selectedGroup = host.store.library.activeGroup
        host.render()
        refresh()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let field = control as? GroupNameField, let cell = field.superview as? ManagerGroupCell else {
            return false
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            field.stringValue = cell.group ?? ""
            window?.makeFirstResponder(groupTable)
            return true
        }
        return false
    }
    func toggleBulk() {
        guard flush() else { return }
        parkDraft()
        let selection = promptTable.selectedRowIndexes
        bulk.toggle()
        loading = true
        promptTable.allowsMultipleSelection = bulk
        batchBar.isHidden = !bulk
        if !bulk { promptTable.deselectAll(nil) }
        promptTable.reloadData()
        if bulk { promptTable.selectRowIndexes(selection, byExtendingSelection: false) }
        loading = false
        layoutColumns()
        updateBatch()
    }
    func updateBatch() {
        batchLabel.stringValue = "已选 \(selectedPromptIDs.count) 条"
        deleteBatch.isEnabled = !selectedPromptIDs.isEmpty
        movePopup.removeAllItems()
        movePopup.addItems(withTitles: ["移动到分组…", "未分组"] + host.store.library.groups)
        movePopup.isEnabled = !selectedPromptIDs.isEmpty
    }
    @objc func batchMove() {
        let i = movePopup.indexOfSelectedItem
        guard i > 0 else { return }
        move(selectedPromptIDs, to: i == 1 ? "" : host.store.library.groups[i - 2])
    }
    func move(_ ids: [UUID], to group: String) {
        let ids = Set(ids)
        _ = change { library in
            for i in library.prompts.indices where ids.contains(library.prompts[i].id) {
                library.prompts[i].group = group
            }
        }
    }
    func deleteSelected() { delete(selectedPromptIDs) }
    func delete(_ ids: [UUID]) {
        guard !ids.isEmpty, flush() else { return }
        let alert = NSAlert()
        alert.messageText = "删除 \(ids.count) 条提示词？"
        alert.informativeText = "删除前会保留数据备份。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let file = host.store.file.deletingLastPathComponent().appendingPathComponent(
                "library.before-delete-\(UUID().uuidString).json")
            try PromptStore.encode(host.store.library).write(to: file, options: .atomic)
        } catch {
            issue.stringValue = "备份失败：\(error.localizedDescription)"
            return
        }
        let set = Set(ids)
        _ = change { $0.prompts.removeAll { set.contains($0.id) } }
    }
    func menuItem(_ title: String, in menu: NSMenu, block: @escaping () -> Void) {
        let handler = MenuAction(block)
        menuHandlers.append(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke), keyEquivalent: "")
        item.target = handler
        menu.addItem(item)
    }
    func groupMenu(_ row: Int) -> NSMenu? {
        guard row >= 2 else { return nil }
        let name = host.store.library.groups[row - 2]
        let menu = NSMenu()
        menuHandlers.removeAll()
        menuItem("重命名", in: menu) { [weak self] in
            self?.groupTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            self?.renameSelectedGroup()
        }
        menuItem("删除分组", in: menu) { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "删除“\(name)”分组？"
            alert.informativeText = "其中的提示词将移到未分组。"
            alert.addButton(withTitle: "删除分组")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            _ = self.change { library in
                library.groups.removeAll { $0 == name }
                for i in library.prompts.indices where library.prompts[i].group == name {
                    library.prompts[i].group = ""
                }
                if library.activeGroup == name { library.activeGroup = nil }
            }
            if self.selectedGroup == name { self.selectedGroup = nil }
            self.host.selectedGroup = self.host.store.library.activeGroup
            self.host.render()
            self.refresh()
        }
        menuItem("删除分组及全部提示词…", in: menu) { [weak self] in self?.host.deleteGroupAndContents(name) }
        return menu
    }
    func promptMenu(_ row: Int) -> NSMenu? {
        guard row < filtered.count else { return nil }
        let prompt = filtered[row]
        let menu = NSMenu()
        menuHandlers.removeAll()
        menuItem("复制", in: menu) {
            OpenEnvironment.pasteboard.clearContents()
            OpenEnvironment.pasteboard.setString(prompt.body, forType: .string)
        }
        let sub = NSMenu()
        for group in [""] + host.store.library.groups {
            menuItem(group.isEmpty ? "未分组" : group, in: sub) { [weak self] in
                self?.move([prompt.id], to: group)
            }
        }
        let move = NSMenuItem(title: "移动到分组", action: nil, keyEquivalent: "")
        move.submenu = sub
        menu.addItem(move)
        menuItem("上移", in: menu) { [weak self] in self?.shift(prompt.id, by: -1) }
        menuItem("下移", in: menu) { [weak self] in self?.shift(prompt.id, by: 1) }
        menuItem("删除", in: menu) { [weak self] in self?.delete([prompt.id]) }
        return menu
    }
    func shift(_ id: UUID, by offset: Int) {
        guard let row = filtered.firstIndex(where: { $0.id == id }), filtered.indices.contains(row + offset)
        else { return }
        let other = filtered[row + offset].id
        _ = change { library in
            if let a = library.prompts.firstIndex(where: { $0.id == id }),
                let b = library.prompts.firstIndex(where: { $0.id == other })
            {
                library.prompts.swapAt(a, b)
            }
        }
    }
    func showMore() {
        let menu = NSMenu()
        menuHandlers.removeAll()
        for (label, value) in [("浅色", "light"), ("深色", "dark"), ("跟随系统", "system")] {
            menuItem(label, in: menu) { [weak self] in _ = self?.change { $0.theme = value } }
            menu.items.last?.state = host.store.library.theme == value ? .on : .off
        }
        menu.addItem(.separator())
        menuItem("打开数据文件夹", in: menu) { [weak self] in
            if let self { NSWorkspace.shared.open(self.host.store.file.deletingLastPathComponent()) }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.maxY), in: moreButton)
    }
}
