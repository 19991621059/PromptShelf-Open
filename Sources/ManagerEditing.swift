import AppKit

extension ManagerController {
    func load(_ prompt: Prompt) {
        window?.endEditing(for: nil)
        let wasLoading = loading
        loading = true
        newDraft = false
        selectedID = prompt.id
        draftGroup = prompt.group
        let partial = partials.removeValue(forKey: prompt.id)
        titleField.stringValue = partial?.0 ?? prompt.title
        body.loadBody(partial?.1 ?? prompt.body, richText: partial != nil ? partial?.2 : prompt.richText)
        dirty = partial != nil
        issue.stringValue = ""
        body.undoManager?.removeAllActions()
        setEditorVisible(true)
        window?.makeFirstResponder(promptTable)
        body.enclosingScrollView?.contentView.scroll(to: .zero)
        loading = wasLoading
    }
    func parkDraft() {
        if newDraft {
            let title = titleField.currentEditor()?.string ?? titleField.stringValue
            if !title.isEmpty || !body.string.isEmpty {
                drafts[draftGroup] = (title, body.string, body.richTextSnapshot())
            }
            newDraft = false
            dirty = false
        } else if dirty, let id = selectedID {
            partials[id] = (
                titleField.currentEditor()?.string ?? titleField.stringValue, body.string,
                body.richTextSnapshot()
            )
            dirty = false
        }
    }
    func createPrompt() {
        guard flush(), host.finishEditing() else { return }
        parkDraft()
        selectedID = nil
        newDraft = true
        draftGroup = selectedGroup ?? ""
        let draft = drafts.removeValue(forKey: draftGroup)
        loading = true
        titleField.stringValue = draft?.0 ?? ""
        body.loadBody(draft?.1 ?? "", richText: draft?.2)
        loading = false
        dirty = draft != nil
        issue.stringValue = ""
        setEditorVisible(true)
        loading = true
        promptTable.deselectAll(nil)
        loading = false
        window?.makeFirstResponder(titleField)
    }
    func textDidChange(_ notification: Notification) { if !loading { scheduleSave() } }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? PromptSearchField === search {
            guard flush() else { return }
            parkDraft()
            selectedID = nil
            newDraft = false
            refresh()
        } else if notification.object as? NSTextField === titleField, !loading {
            scheduleSave()
        }
    }
    func scheduleSave() {
        dirty = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            _ = self?.flush()
        }
    }
    @discardableResult func flush() -> Bool {
        timer?.invalidate()
        timer = nil
        guard dirty, !saving else { return true }
        guard !body.hasMarkedText(), (titleField.currentEditor() as? NSTextView)?.hasMarkedText() != true
        else { return false }
        let rawTitle = titleField.currentEditor()?.string ?? titleField.stringValue
        let text = body.string
        let trimmedBody = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Incomplete edits are retained in this controller, and are never written as empty prompts.
        if trimmedBody.isEmpty { return true }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let actualTitle =
            title.isEmpty
            ? String(
                trimmedBody.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(20)
                    ?? trimmedBody.prefix(20)) : title
        let selectedBeforeSave = selectedPromptIDs
        saving = true
        defer { saving = false }
        do {
            if newDraft {
                let prompt = Prompt(
                    title: actualTitle, body: text, group: draftGroup, richText: body.richTextSnapshot())
                try host.store.change { $0.prompts.append(prompt) }
                selectedID = prompt.id
                newDraft = false
                drafts.removeValue(forKey: draftGroup)
            } else if let id = selectedID {
                guard host.store.library.prompts.contains(where: { $0.id == id }) else {
                    issue.stringValue = "这条提示词已删除，当前文字已保留。可新建后粘贴。"
                    return false
                }
                try host.store.change { library in
                    if let index = library.prompts.firstIndex(where: { $0.id == id }) {
                        library.prompts[index].title = actualTitle
                        library.prompts[index].body = text
                        library.prompts[index].richText = body.richTextSnapshot()
                    }
                }
            }
            dirty = false
            issue.stringValue = ""
            // Refresh the lists without replacing the active text editor or its undo history.
            loading = true
            filtered = host.store.library.prompts.filter {
                (selectedGroup == nil || $0.group == selectedGroup)
                    && (search.stringValue.isEmpty || $0.title.localizedStandardContains(search.stringValue)
                        || $0.body.localizedStandardContains(search.stringValue) || $0.id == selectedID)
            }
            updateEmptyState()
            if renamingGroup == nil { groupTable.reloadData() }
            promptTable.reloadData()
            if bulk {
                promptTable.selectRowIndexes(
                    IndexSet(
                        filtered.enumerated().compactMap {
                            selectedBeforeSave.contains($0.element.id) ? $0.offset : nil
                        }), byExtendingSelection: false)
            } else if let i = filtered.firstIndex(where: { $0.id == selectedID }) {
                promptTable.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
            }
            loading = false
            updateBatch()
            return true
        } catch {
            issue.stringValue = "保存失败：\(error.localizedDescription)"
            return false
        }
    }
    @discardableResult func change(_ block: (inout Library) -> Void) -> Bool {
        guard flush(), host.finishEditing() else { return false }
        do {
            try host.store.change(block)
            refresh()
            return true
        } catch {
            issue.stringValue = "保存失败：\(error.localizedDescription)"
            return false
        }
    }
}
