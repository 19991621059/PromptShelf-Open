import AppKit

extension AppDelegate {
    func isInsideSearch(_ event: NSEvent) -> Bool {
        guard let box = searchField.superview, let window = box.window else { return false }
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        return window.convertToScreen(box.convert(box.bounds, to: nil)).contains(point)
    }

    func dismissSearch() {
        guard searchVisible else { return }
        panel.endEditing(for: nil)
        searchVisible = false
        searchText = ""
        searchField.stringValue = ""
        render()
    }

    func outsidePointerDown() {
        guard expanded, panel.attachedSheet == nil,
            manager?.window?.attachedSheet == nil, NSApp.modalWindow == nil
        else { return }
        if store.library.pinned != true { collapse() } else { dismissSearch() }
    }

    func toggleShelfBulk() {
        guard finishEditing() else { return }
        shelfBulk.toggle()
        shelfSelection.removeAll()
        directoryOverride = false
        render()
    }

    func shelfBatchBar(frame: NSRect) -> NSView {
        shelfSelection.formIntersection(store.library.prompts.map(\.id))
        let bar = FlippedView(frame: frame)
        let label = NSTextField(labelWithString: "已选 \(shelfSelection.count) 条")
        label.font = .systemFont(ofSize: 11)
        label.textColor = Palette.secondary
        label.frame = NSRect(x: 10, y: 3, width: max(50, frame.width - 70), height: 18)
        bar.addSubview(label)
        let all = TextActionButton(
            title: "全选", frame: NSRect(x: frame.width - 54, y: 0, width: 48, height: 24)
        ) { [weak self] in
            guard let self else { return }
            let visible = Set(self.filtered.map(\.id))
            if visible.isSubset(of: self.shelfSelection) {
                self.shelfSelection.subtract(visible)
            } else {
                self.shelfSelection.formUnion(visible)
            }
            self.render()
        }
        bar.addSubview(all)
        let move = ActionButton(
            symbol: "folder", label: "移动所选提示词到分组",
            frame: NSRect(x: 8, y: 28, width: 28, height: 25)
        ) {}
        move.isEnabled = !shelfSelection.isEmpty
        move.actionBlock = { [weak self, weak move] in
            guard let self, let move else { return }
            let menu = NSMenu()
            for group in [""] + self.store.library.groups {
                self.add(group.isEmpty ? "未分组" : group, to: menu) { [weak self] in
                    self?.moveShelfSelection(to: group)
                }
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 25), in: move)
        }
        bar.addSubview(move)
        let delete = ActionButton(
            symbol: "trash", label: "删除所选提示词",
            frame: NSRect(x: 42, y: 28, width: 28, height: 25)
        ) { [weak self] in self?.deleteShelfSelection() }
        delete.isEnabled = !shelfSelection.isEmpty
        bar.addSubview(delete)
        bar.addSubview(
            TextActionButton(title: "完成", frame: NSRect(x: frame.width - 54, y: 28, width: 48, height: 25)) {
                [weak self] in self?.toggleShelfBulk()
            })
        return bar
    }

    func moveShelfSelection(to group: String) {
        let ids = shelfSelection
        mutate { library in
            for i in library.prompts.indices where ids.contains(library.prompts[i].id) {
                library.prompts[i].group = group
            }
        }
        shelfSelection.removeAll()
        render()
    }

    func deleteShelfSelection() {
        let ids = shelfSelection
        guard !ids.isEmpty, confirm("删除 \(ids.count) 条提示词？", detail: "删除前会保留本机数据备份。") else { return }
        do {
            let backup = store.file.deletingLastPathComponent().appendingPathComponent(
                "library.before-delete-\(UUID().uuidString).json")
            try PromptStore.encode(store.library).write(to: backup, options: .atomic)
            try store.change { $0.prompts.removeAll { ids.contains($0.id) } }
            shelfSelection.removeAll()
            render()
        } catch { showError(error.localizedDescription) }
    }
}
