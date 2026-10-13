import AppKit

extension ManagerController {
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ManagerSelectionRow()
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === groupTable ? host.store.library.groups.count + 2 : filtered.count
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        tableView === groupTable ? 30 : selectedGroup == nil ? 72 : 64
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === groupTable {
            let cell = ManagerGroupCell()
            let groups = host.store.library.groups
            cell.group = row == 0 ? nil : row == 1 ? "" : groups[row - 2]
            cell.name.stringValue = row == 0 ? "全部" : row == 1 ? "未分组" : groups[row - 2]
            cell.name.delegate = self
            cell.name.setAccessibilityLabel("分组：\(cell.name.stringValue)")
            cell.count.stringValue = String(
                host.store.library.prompts.filter { cell.group == nil || $0.group == cell.group }.count)
            return cell
        }
        let prompt = filtered[row]
        let cell = ManagerCell()
        cell.heading.stringValue = prompt.title
        cell.preview.stringValue = PromptRow.preview(prompt)
        cell.checkbox.isHidden = !bulk
        cell.checkbox.state = promptTable.selectedRowIndexes.contains(row) ? .on : .off
        cell.checkbox.setAccessibilityLabel("选择：\(prompt.title)")
        cell.choose = { [weak self] in
            guard let self else { return }
            if self.promptTable.selectedRowIndexes.contains(row) {
                self.promptTable.deselectRow(row)
            } else {
                self.promptTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: true)
            }
            self.updateBatch()
        }
        cell.showGroup = selectedGroup == nil
        cell.detail.stringValue = prompt.group.isEmpty ? "未分组" : prompt.group
        cell.copyButton.actionBlock = { [weak cell] in
            OpenEnvironment.pasteboard.clearContents()
            if OpenEnvironment.pasteboard.setString(prompt.body, forType: .string) { cell?.showCopied() }
        }
        cell.setAccessibilityLabel("\(prompt.title)，\(prompt.group.isEmpty ? "未分组" : prompt.group)")
        return cell
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { loading || flush() }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !loading else { return }
        if notification.object as? NSTableView === groupTable {
            guard flush() else { return }
            parkDraft()
            let row = groupTable.selectedRow
            guard row >= 0 else { return }
            selectedGroup = row == 0 ? nil : row == 1 ? "" : host.store.library.groups[row - 2]
            selectedID = nil
            newDraft = false
            search.stringValue = ""
            refresh()
        } else {
            guard flush() else { return }
            parkDraft()
            if !bulk, let id = selectedPromptIDs.first,
                let prompt = host.store.library.prompts.first(where: { $0.id == id })
            {
                load(prompt)
            } else if !bulk {
                selectedID = nil
                newDraft = false
                setEditorVisible(false)
            }
            if bulk {
                for row in 0..<filtered.count {
                    (promptTable.view(atColumn: 0, row: row, makeIfNecessary: false) as? ManagerCell)?
                        .checkbox.state = promptTable.selectedRowIndexes.contains(row) ? .on : .off
                }
            }
            updateBatch()
        }
    }
}
