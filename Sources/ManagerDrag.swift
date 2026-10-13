import AppKit

extension ManagerController {
    func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pasteboard: NSPasteboard)
        -> Bool
    {
        if tableView === groupTable {
            guard rowIndexes.count == 1, let row = rowIndexes.first, row >= 2 else { return false }
            pasteboard.declareTypes([ManagerDragType.group], owner: nil)
            return pasteboard.setString(host.store.library.groups[row - 2], forType: ManagerDragType.group)
        }
        let ids = rowIndexes.compactMap { $0 < filtered.count ? filtered[$0].id.uuidString : nil }
        pasteboard.declareTypes([ManagerDragType.prompt], owner: nil)
        return pasteboard.setString(ids.joined(separator: ","), forType: ManagerDragType.prompt)
    }
    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation operation: NSTableView.DropOperation
    ) -> NSDragOperation {
        if tableView === groupTable {
            if info.draggingPasteboard.string(forType: ManagerDragType.group) != nil {
                return row >= 2 && operation == .above ? .move : []
            }
            return row >= 1 && row < numberOfRows(in: groupTable) && operation == .on ? .move : []
        }
        return info.draggingPasteboard.string(forType: ManagerDragType.prompt) != nil && operation == .above
            && search.stringValue.isEmpty ? .move : []
    }
    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        if tableView === groupTable, let name = info.draggingPasteboard.string(forType: ManagerDragType.group)
        {
            return reorderGroup(name, before: row - 2)
        }
        guard let string = info.draggingPasteboard.string(forType: ManagerDragType.prompt) else {
            return false
        }
        let ids = string.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        if tableView === groupTable {
            move(ids, to: row == 1 ? "" : host.store.library.groups[row - 2])
            return true
        }
        return reorderPrompts(ids, before: row < filtered.count ? filtered[row].id : nil)
    }
    func reorderGroup(_ name: String, before row: Int) -> Bool {
        change { library in
            guard let old = library.groups.firstIndex(of: name) else { return }
            library.groups.remove(at: old)
            library.groups.insert(name, at: min(library.groups.count, max(0, row - (old < row ? 1 : 0))))
        }
    }
    func reorderPrompts(_ ids: [UUID], before target: UUID?) -> Bool {
        guard target == nil || !ids.contains(target!) else { return true }
        return change { library in
            let moved = library.prompts.filter { ids.contains($0.id) }
            library.prompts.removeAll { ids.contains($0.id) }
            let index =
                target.flatMap { id in library.prompts.firstIndex(where: { $0.id == id }) }
                ?? (selectedGroup.flatMap { group in
                    library.prompts.lastIndex(where: { $0.group == group }).map { $0 + 1 }
                } ?? library.prompts.count)
            library.prompts.insert(contentsOf: moved, at: index)
        }
    }
}
