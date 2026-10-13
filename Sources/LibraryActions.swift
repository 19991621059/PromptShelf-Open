import AppKit
import UniformTypeIdentifiers

extension AppDelegate {
    func alert(_ message: String, detail: String = "", confirm: String = "确定") -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: confirm)
        alert.window.level = .statusBar
        alert.window.collectionBehavior = panel.collectionBehavior
        alert.window.appearance = panel.appearance
        return alert
    }
    func showError(_ message: String) {
        let alert = alert("PromptShelf-Open", detail: message)
        alert.runModal()
    }
    func confirm(_ message: String, detail: String = "", action: String = "删除") -> Bool {
        let alert = alert(message, detail: detail, confirm: action)
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func groupName(_ title: String, initial: String = "") -> String? {
        let alert = alert(title, confirm: "保存")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 25))
        input.stringValue = initial
        input.placeholderString = "分组名称"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty && !["全部", "未分组"].contains(value) else {
            showError("请输入其他分组名称")
            return nil
        }
        return value
    }
    func newGroup() {
        guard prepareContextChange() else { return }
        guard let name = groupName("新分组") else { return }
        selectedGroup = name
        mutate {
            if !$0.groups.contains(name) { $0.groups.append(name) }
            $0.activeGroup = name
        }
    }
    func renameGroup(_ group: String) {
        guard prepareContextChange() else { return }
        guard let name = groupName("重命名分组", initial: group), name != group else { return }
        if store.library.groups.contains(name) {
            showError("已有同名分组")
            return
        }
        if selectedGroup == group { selectedGroup = name }
        mutate { library in
            if let index = library.groups.firstIndex(of: group) { library.groups[index] = name }
            if library.activeGroup == group { library.activeGroup = name }
            for i in library.prompts.indices where library.prompts[i].group == group {
                library.prompts[i].group = name
            }
        }
    }
    func deleteGroup(_ group: String) {
        guard prepareContextChange() else { return }
        guard confirm("删除「\(group)」？", detail: "提示词会保留，并移到未分组。") else { return }
        if selectedGroup == group { selectedGroup = nil }
        mutate { library in
            library.groups.removeAll { $0 == group }
            if library.activeGroup == group { library.activeGroup = nil }
            for i in library.prompts.indices where library.prompts[i].group == group {
                library.prompts[i].group = ""
            }
        }
    }
    func groupContextMenu(_ group: String) -> NSMenu {
        let menu = NSMenu()
        add("重命名…", to: menu) { [weak self] in self?.renameGroup(group) }
        add("只删除分组…", to: menu) { [weak self] in self?.deleteGroup(group) }
        add("删除分组及全部提示词…", to: menu) { [weak self] in self?.deleteGroupAndContents(group) }
        return menu
    }
    func deleteGroupAndContents(_ group: String) {
        guard store.library.groups.contains(group), (manager?.flush() ?? true), prepareContextChange() else { return }
        let ids = Set(store.library.prompts.filter { $0.group == group }.map(\.id))
        guard confirm("删除「\(group)」及全部提示词？",
                      detail: "将删除这个分组和其中的 \(ids.count) 条提示词。删除前会保留本机安全副本。") else { return }
        guard Set(store.library.prompts.filter { $0.group == group }.map(\.id)) == ids else {
            showError("分组内容已变化，请重新确认删除。")
            return
        }
        do {
            try store.deleteGroupAndContents(group)
            pendingNewEditors.removeValue(forKey: group)
            for id in ids { pendingEditors.removeValue(forKey: id); manager?.partials.removeValue(forKey: id) }
            manager?.drafts.removeValue(forKey: group)
            if selectedGroup == group { selectedGroup = nil }
            if manager?.selectedGroup == group { manager?.selectedGroup = nil }
            render(); manager?.refresh()
        } catch { showError(error.localizedDescription) }
    }
    func deletePrompt(_ prompt: Prompt) {
        guard confirm("删除「\(prompt.title)」？") else { return }
        mutate { $0.prompts.removeAll { $0.id == prompt.id } }
    }
    func movePrompt(_ prompt: Prompt, direction: Int) {
        let list = filtered
        guard let from = list.firstIndex(where: { $0.id == prompt.id }) else { return }
        let to = from + direction
        guard list.indices.contains(to) else { return }
        mutate { library in
            guard let a = library.prompts.firstIndex(where: { $0.id == prompt.id }),
                let b = library.prompts.firstIndex(where: { $0.id == list[to].id })
            else { return }
            library.prompts.swapAt(a, b)
        }
    }
    func exportLibrary() {
        guard finishEditing() else { return }
        let save = NSSavePanel()
        save.nameFieldStringValue = "全部提示词.json"
        save.allowedContentTypes = [.json]
        save.level = .statusBar
        save.collectionBehavior = panel.collectionBehavior
        guard save.runModal() == .OK, let url = save.url else { return }
        do { try PromptStore.encode(store.library).write(to: url, options: .atomic) } catch {
            showError(error.localizedDescription)
        }
    }
    func importLibrary() {
        guard prepareContextChange() else { return }
        let open = NSOpenPanel()
        open.allowedContentTypes = [.json]
        open.allowsMultipleSelection = false
        open.level = .statusBar
        open.collectionBehavior = panel.collectionBehavior
        guard open.runModal() == .OK, let url = open.url else { return }
        do {
            let data = try Data(contentsOf: url)
            _ = try PromptStore.decode(data)
            guard confirm("导入这份备份？", detail: "当前提示词会先备份到数据文件夹，再替换为导入内容。", action: "导入") else { return }
            try store.restore(data)
            selectedGroup = nil
            scrollOffset = 0
            scrollView = nil
            render()
        } catch { showError(error.localizedDescription) }
    }
}
