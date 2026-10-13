import AppKit
import UniformTypeIdentifiers

@MainActor
final class WorkflowWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate {
    unowned let host: AppDelegate
    let workspace: WorkflowWorkspace
    let flows = NSTableView(), steps = NSTableView(), executions = NSTableView()
    let name = NSTextField(), stepName = NSTextField(), input = NSPopUpButton()
    let instruction = NSTextView(), note = NSTextView(), output = NSTextView()
    let filesLabel = WorkflowUI.label("尚未选择文件", size: 12)
    let modelLabel = WorkflowUI.label("先在模型设置中连接模型", size: 12)
    let runStatus = WorkflowUI.label("准备运行", size: 18, weight: .semibold)
    let issue = WorkflowUI.label("", size: 12)
    let resultTitle = WorkflowUI.label("步骤结果", size: 14, weight: .semibold)
    let history = NSPopUpButton()
    let prompts = NSPopUpButton(frame: .zero, pullsDown: true)
    let spinner = NSProgressIndicator()
    var runButton: NSButton!, cancelButton: NSButton!, saveResult: NSButton!, copyResult: NSButton!
    var retry: NSButton!, add: NSButton!, remove: NSButton!, up: NSButton!, down: NSButton!
    var models: ModelSettingsWindowController?
    var selectedFlowID: UUID?
    var currentRunID: UUID?
    var fileURLs: [URL] = []
    private var loading = true
    private var lastShownRunID: UUID?
    private var lastFinishedStep: UUID?
    private var handlers: [MenuAction] = []
    private var sourceDisplay = ""
    var currentFlowIndex: Int? { workspace.snapshot.workflows.firstIndex(where: { $0.id == selectedFlowID }) }
    var currentFlow: WorkflowDefinition? { currentFlowIndex.map { workspace.snapshot.workflows[$0] } }
    var currentRun: WorkflowExecution? { workspace.snapshot.history.first(where: { $0.id == currentRunID }) }

    init(host: AppDelegate, workspace: WorkflowWorkspace) {
        self.host = host; self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "PromptShelf-Open · AI 工作流"
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 1100, height: 730)
        window.appearance = host.panel?.appearance
        window.titlebarAppearsTransparent = true
        super.init(window: window)
        window.delegate = self; window.center()
        window.setFrameAutosaveName("PromptShelfOpen.Workflows")
        for table in [flows, steps, executions] { table.dataSource = self; table.delegate = self; table.allowsEmptySelection = false }
        name.font = .systemFont(ofSize: 23, weight: .semibold); name.isBezeled = false; name.drawsBackground = false
        name.delegate = self; name.setAccessibilityLabel("工作流名称")
        stepName.delegate = self; stepName.setAccessibilityLabel("步骤名称")
        input.addItems(withTitles: StepInput.allCases.map(\.title)); input.target = self; input.action = #selector(changeStepInput)
        input.setAccessibilityLabel("本步骤的输入来源")
        instruction.delegate = self; instruction.setAccessibilityLabel("步骤提示词")
        note.setAccessibilityLabel("任务补充说明")
        output.setAccessibilityLabel("当前步骤的执行结果")
        let sidebar = buildSidebar()
        let editor = buildEditor()
        let results = buildResults()
        let layout = WorkflowUI.stack([sidebar, editor, results], vertical: false, spacing: 0)
        layout.alignment = .top
        WorkflowUI.embed(layout, in: window.contentView!)
        sidebar.widthAnchor.constraint(equalToConstant: 200).isActive = true
        editor.widthAnchor.constraint(equalTo: results.widthAnchor, multiplier: 1.08).isActive = true
        for view in [sidebar, editor, results] { view.heightAnchor.constraint(equalTo: layout.heightAnchor).isActive = true }
        workspace.changed = { [weak self] in self?.refreshRuntime() }
        NotificationCenter.default.addObserver(forName: PromptStore.didChange, object: host.store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPromptMenu() }
        }
        refreshPromptMenu()
        if let first = workspace.snapshot.workflows.first {
            selectedFlowID = first.id; flows.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        currentRunID = workspace.snapshot.history.first?.id
        loadFlow(); refreshRuntime()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildSidebar() -> NSView {
        let pane = NSView(); pane.wantsLayer = true
        let title = WorkflowUI.label("PromptShelf", size: 21, weight: .bold)
        let open = WorkflowUI.label("OPEN  /  本机工作空间", size: 11, weight: .medium); open.textColor = WorkflowUI.secondary
        let heading = WorkflowUI.label("工作流", size: 13, weight: .semibold)
        let flowScroll = WorkflowUI.table(flows, label: "工作流列表"); flows.rowHeight = 52
        let actions = WorkflowUI.stack([
            WorkflowUI.button("新建", target: self, action: #selector(newWorkflow), symbol: "plus"),
            WorkflowUI.button("复制", target: self, action: #selector(duplicateWorkflow), symbol: "doc.on.doc")
        ], vertical: false, spacing: 8)
        let trash = WorkflowUI.button("删除工作流", target: self, action: #selector(deleteWorkflow), symbol: "trash")
        let library = WorkflowUI.button("提示词库", target: self, action: #selector(showPrompts), symbol: "text.quote")
        let settings = WorkflowUI.button("模型设置", target: self, action: #selector(showModels), symbol: "slider.horizontal.3")
        let footer = WorkflowUI.label("0.1.0 · macOS\n开源 · 自带模型", size: 11); footer.textColor = WorkflowUI.secondary
        let stack = WorkflowUI.stack([title, open, WorkflowUI.separator(), heading, flowScroll, actions, trash, WorkflowUI.separator(), library, settings, footer], spacing: 14)
        WorkflowUI.embed(stack, in: pane, inset: 18)
        for view in [flowScroll, library, settings] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        flowScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return pane
    }
    private func buildEditor() -> NSView {
        let pane = NSView()
        let intro = WorkflowUI.label("把提示词组合成任务", size: 12); intro.textColor = WorkflowUI.secondary
        let sourceHeading = WorkflowUI.label("1  选择材料", size: 14, weight: .semibold)
        let sourceButtons = WorkflowUI.stack([
            WorkflowUI.button("选择文件…", target: self, action: #selector(chooseFiles), symbol: "doc.badge.plus"),
            WorkflowUI.button("清空", target: self, action: #selector(clearFiles))
        ], vertical: false)
        let noteScroll = WorkflowUI.scroll(text: note, editable: true)
        noteScroll.heightAnchor.constraint(equalToConstant: 50).isActive = true
        let noteLabel = WorkflowUI.label("补充说明（也可以直接输入要处理的文字）", size: 11); noteLabel.textColor = WorkflowUI.secondary
        let stepHeading = WorkflowUI.label("2  组合步骤", size: 14, weight: .semibold)
        let stepScroll = WorkflowUI.table(steps, label: "工作流步骤"); steps.rowHeight = 32
        stepScroll.heightAnchor.constraint(equalToConstant: 112).isActive = true
        add = WorkflowUI.button("添加", target: self, action: #selector(addStep), symbol: "plus")
        remove = WorkflowUI.button("删除", target: self, action: #selector(removeStep))
        up = WorkflowUI.button("上移", target: self, action: #selector(stepUp))
        down = WorkflowUI.button("下移", target: self, action: #selector(stepDown))
        let tools = WorkflowUI.stack([add, remove, up, down], vertical: false, spacing: 6)
        let stepFields = WorkflowUI.stack([stepName, input], vertical: false, spacing: 8)
        input.widthAnchor.constraint(equalToConstant: 190).isActive = true
        let instructionScroll = WorkflowUI.scroll(text: instruction, editable: true)
        instructionScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
        prompts.target = self; prompts.action = #selector(addPromptStep); prompts.setAccessibilityLabel("从提示词库添加步骤")
        runButton = WorkflowUI.button("运行工作流", target: self, action: #selector(runWorkflow), symbol: "play.fill")
        runButton.keyEquivalent = "\r"; runButton.keyEquivalentModifierMask = [.command]
        runButton.bezelColor = .controlAccentColor
        cancelButton = WorkflowUI.button("取消运行", target: self, action: #selector(cancelRun))
        let runActions = WorkflowUI.stack([runButton, cancelButton], vertical: false)
        let stack = WorkflowUI.stack([intro, name, modelLabel, WorkflowUI.separator(), sourceHeading, sourceButtons,
            filesLabel, noteLabel, noteScroll, stepHeading, stepScroll, tools, stepFields, instructionScroll, prompts, runActions], spacing: 6)
        WorkflowUI.embed(stack, in: pane, inset: 22)
        for view in [name, modelLabel, filesLabel, noteScroll, stepScroll, stepFields, instructionScroll] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stepName.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return pane
    }
    private func buildResults() -> NSView {
        let pane = NSView()
        let heading = WorkflowUI.label("执行过程与结果", size: 22, weight: .semibold)
        history.target = self; history.action = #selector(selectHistory); history.setAccessibilityLabel("选择执行记录")
        history.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let statusRow = WorkflowUI.stack([spinner, runStatus], vertical: false)
        let executionScroll = WorkflowUI.table(executions, label: "各步骤执行状态")
        executionScroll.heightAnchor.constraint(equalToConstant: 168).isActive = true
        let outputScroll = WorkflowUI.scroll(text: output, editable: false)
        outputScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        copyResult = WorkflowUI.button("复制结果", target: self, action: #selector(copyOutput), symbol: "doc.on.doc")
        saveResult = WorkflowUI.button("预览并保存…", target: self, action: #selector(saveOutput), symbol: "square.and.arrow.up")
        retry = WorkflowUI.button("重新运行", target: self, action: #selector(retryRun), symbol: "arrow.clockwise")
        let actions = WorkflowUI.stack([copyResult, saveResult], vertical: false)
        let stack = WorkflowUI.stack([heading, history, statusRow, executionScroll, resultTitle, outputScroll, actions, retry, issue], spacing: 14)
        WorkflowUI.embed(stack, in: pane, inset: 22)
        for view in [history, executionScroll, outputScroll, issue] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return pane
    }
    func present() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func showPrompts() { host.showManager() }
    @objc func showModels() {
        if models == nil { models = ModelSettingsWindowController(workspace: workspace) }
        models?.window?.appearance = window?.appearance
        models?.present()
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === flows { return workspace.snapshot.workflows.count }
        if tableView === steps { return currentFlow?.steps.count ?? 0 }
        return currentRun?.steps.count ?? 0
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView === flows {
            guard workspace.snapshot.workflows.indices.contains(row) else { return nil }
            let flow = workspace.snapshot.workflows[row]; text = "\(flow.name)\n\(flow.steps.count) 个步骤"
        } else if tableView === steps {
            guard let flow = currentFlow, flow.steps.indices.contains(row) else { return nil }
            text = "\(row + 1)   \(flow.steps[row].title)"
        } else {
            guard let run = currentRun, run.steps.indices.contains(row) else { return nil }
            let step = run.steps[row]
            let elapsed = step.elapsed.map { String(format: " · %.1f 秒", $0) } ?? ""
            text = "\(row + 1)   \(step.title)\n\(step.status.title)\(elapsed)"
        }
        let id = NSUserInterfaceItemIdentifier("workflow-cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? NSTableCellView()
        cell.identifier = id
        if cell.textField == nil {
            let label = WorkflowUI.label("", size: 12)
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byTruncatingTail
            WorkflowUI.embed(label, in: cell, inset: 6)
            cell.textField = label
        }
        cell.textField?.stringValue = text
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !loading, let table = notification.object as? NSTableView else { return }
        if table === flows {
            guard workspace.snapshot.workflows.indices.contains(flows.selectedRow) else { return }
            selectedFlowID = workspace.snapshot.workflows[flows.selectedRow].id; loadFlow()
        } else if table === steps { loadStep() }
        else { showSelectedOutput() }
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { readyForAction() }
    private func readyForAction() -> Bool {
        if instruction.hasMarkedText() || note.hasMarkedText()
            || (name.currentEditor() as? NSTextView)?.hasMarkedText() == true
            || (stepName.currentEditor() as? NSTextView)?.hasMarkedText() == true {
            issue.stringValue = "请先完成中文输入，再切换步骤或运行。"
            return false
        }
        if instruction.string.count > 8000 || stepName.stringValue.count > 100 || name.stringValue.count > 120 {
            issue.stringValue = "名称或提示词超过上限，请精简后继续。"
            issue.textColor = WorkflowUI.error
            return false
        }
        return true
    }
    private func loadFlow(selectStep: Int = 0) {
        loading = true
        if let index = currentFlowIndex {
            flows.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
        }
        name.stringValue = currentFlow?.name ?? ""
        steps.reloadData()
        if let flow = currentFlow, !flow.steps.isEmpty {
            steps.selectRowIndexes(IndexSet(integer: min(max(0, selectStep), flow.steps.count - 1)), byExtendingSelection: false)
        }
        loading = false; loadStep()
    }
    private func loadStep() {
        loading = true
        defer { loading = false }
        if let flow = currentFlow, flow.steps.indices.contains(steps.selectedRow) {
            let step = flow.steps[steps.selectedRow]
            stepName.stringValue = step.title
            instruction.string = step.instruction
            instruction.undoManager?.removeAllActions()
            input.selectItem(at: StepInput.allCases.firstIndex(of: step.input)!)
            instruction.isEditable = true; stepName.isEnabled = true; input.isEnabled = true
            up.isEnabled = steps.selectedRow > 0; down.isEnabled = steps.selectedRow < flow.steps.count - 1
            remove.isEnabled = flow.steps.count > 1
        } else {
            stepName.stringValue = ""; instruction.string = ""; instruction.isEditable = false; stepName.isEnabled = false; input.isEnabled = false
            up.isEnabled = false; down.isEnabled = false; remove.isEnabled = false
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard !loading, let index = currentFlowIndex, let field = notification.object as? NSTextField,
            (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if field === name {
            guard name.stringValue.count <= 120 else { issue.stringValue = "工作流名称最多 120 字"; return }
            workspace.edit { $0.workflows[index].name = name.stringValue }
            flows.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
        } else if field === stepName { updateStep() }
    }
    func textDidChange(_ notification: Notification) { if notification.object as? NSTextView === instruction { updateStep() } }
    private func updateStep() {
        guard !loading, !instruction.hasMarkedText(), (stepName.currentEditor() as? NSTextView)?.hasMarkedText() != true,
            instruction.string.count <= 8000, stepName.stringValue.count <= 100,
            let index = currentFlowIndex, workspace.snapshot.workflows[index].steps.indices.contains(steps.selectedRow) else { return }
        let step = steps.selectedRow
        workspace.edit { snapshot in
            snapshot.workflows[index].steps[step].title = stepName.stringValue
            snapshot.workflows[index].steps[step].instruction = instruction.string
            snapshot.workflows[index].steps[step].input = StepInput.allCases[input.indexOfSelectedItem]
        }
        steps.reloadData(forRowIndexes: IndexSet(integer: step), columnIndexes: IndexSet(integer: 0))
    }
    @objc func changeStepInput() { updateStep() }
    @objc func newWorkflow() {
        guard readyForAction(), workspace.snapshot.workflows.count < 100 else { return }
        let flow = WorkflowDefinition(name: "新工作流", steps: [WorkflowStep(title: "处理材料", instruction: "请用中文总结以下材料，保留关键事实。", input: .files)])
        workspace.edit { $0.workflows.append(flow) }; selectedFlowID = flow.id
        flows.reloadData(); flows.selectRowIndexes(IndexSet(integer: workspace.snapshot.workflows.count - 1), byExtendingSelection: false)
        loadFlow(); window?.makeFirstResponder(name)
    }
    @objc func duplicateWorkflow() {
        guard readyForAction(), workspace.snapshot.workflows.count < 100 else { return }
        guard var flow = currentFlow else { return }
        flow.id = UUID(); flow.name = String((flow.name + " 副本").prefix(120))
        for index in flow.steps.indices { flow.steps[index].id = UUID() }
        workspace.edit { $0.workflows.append(flow) }; selectedFlowID = flow.id
        flows.reloadData(); flows.selectRowIndexes(IndexSet(integer: workspace.snapshot.workflows.count - 1), byExtendingSelection: false); loadFlow()
    }
    @objc func deleteWorkflow() {
        guard readyForAction() else { return }
        guard let id = selectedFlowID else { return }
        let alert = NSAlert(); alert.messageText = "删除这个工作流？"; alert.informativeText = "已有执行记录会保留。"
        alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        workspace.edit { $0.workflows.removeAll { $0.id == id } }
        selectedFlowID = workspace.snapshot.workflows.first?.id
        flows.reloadData(); if selectedFlowID != nil { flows.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }; loadFlow()
    }
    @objc func addStep() {
        guard readyForAction() else { return }
        guard let index = currentFlowIndex, workspace.snapshot.workflows[index].steps.count < 20 else { return }
        workspace.edit { $0.workflows[index].steps.append(WorkflowStep(title: "新步骤", instruction: "请根据输入材料完成这一步。", input: .previous)) }
        loadFlow(selectStep: workspace.snapshot.workflows[index].steps.count - 1)
    }
    @objc func removeStep() {
        guard readyForAction() else { return }
        guard let index = currentFlowIndex, workspace.snapshot.workflows[index].steps.count > 1, steps.selectedRow >= 0 else { return }
        let row = steps.selectedRow
        workspace.edit { $0.workflows[index].steps.remove(at: row) }
        loadFlow(selectStep: max(0, row - 1))
    }
    @objc func stepUp() { moveStep(-1) }
    @objc func stepDown() { moveStep(1) }
    private func moveStep(_ offset: Int) {
        guard readyForAction() else { return }
        guard let index = currentFlowIndex else { return }
        let from = steps.selectedRow, to = from + offset
        guard workspace.snapshot.workflows[index].steps.indices.contains(to) else { return }
        workspace.edit { $0.workflows[index].steps.swapAt(from, to) }
        loadFlow(selectStep: to)
    }
    func refreshPromptMenu() {
        prompts.removeAllItems(); prompts.addItem(withTitle: "从提示词库添加步骤…")
        for prompt in host.store.library.prompts.prefix(200) { prompts.addItem(withTitle: prompt.title); prompts.lastItem?.representedObject = prompt.id.uuidString }
        prompts.isEnabled = !host.store.library.prompts.isEmpty
    }
    @objc func addPromptStep() {
        guard readyForAction() else { return }
        guard let value = prompts.selectedItem?.representedObject as? String, let id = UUID(uuidString: value),
            let prompt = host.store.library.prompts.first(where: { $0.id == id }), let index = currentFlowIndex,
            workspace.snapshot.workflows[index].steps.count < 20 else { return }
        guard prompt.body.count <= 8000 else { issue.stringValue = "这条提示词超过 8000 字，请先在提示词库中精简。"; return }
        let source: StepInput = workspace.snapshot.workflows[index].steps.isEmpty ? .files : .previous
        workspace.edit { $0.workflows[index].steps.append(WorkflowStep(title: prompt.title, instruction: prompt.body, input: source)) }
        loadFlow(selectStep: workspace.snapshot.workflows[index].steps.count - 1)
    }
    @objc func chooseFiles() {
        let open = NSOpenPanel(); open.canChooseDirectories = false; open.allowsMultipleSelection = true
        open.message = "选择要处理的文本、Markdown、CSV、JSON 或文字 PDF。"
        guard open.runModal() == .OK else { return }
        fileURLs = open.urls
        filesLabel.stringValue = "\(fileURLs.count) 个文件 · " + fileURLs.map(\.lastPathComponent).joined(separator: "、")
    }
    @objc func clearFiles() { fileURLs = []; filesLabel.stringValue = "尚未选择文件" }
    @objc func runWorkflow() {
        guard readyForAction() else { return }
        guard let flow = currentFlow else { return }
        window?.endEditing(for: nil)
        do { try workspace.start(definition: flow, urls: fileURLs, note: note.string); currentRunID = workspace.activeRunID; refreshRuntime() }
        catch { issue.stringValue = error.localizedDescription; issue.textColor = WorkflowUI.error }
    }
    @objc func cancelRun() { workspace.cancel() }
    @objc func retryRun() {
        guard readyForAction() else { return }
        guard let flow = currentRun?.definition else { return }
        do { try workspace.start(definition: flow, urls: fileURLs, note: note.string); currentRunID = workspace.activeRunID; refreshRuntime() }
        catch { issue.stringValue = error.localizedDescription; issue.textColor = WorkflowUI.error }
    }
    @objc func selectHistory() {
        guard workspace.snapshot.history.indices.contains(history.indexOfSelectedItem) else { return }
        currentRunID = workspace.snapshot.history[history.indexOfSelectedItem].id; refreshRuntime()
    }
    func refreshRuntime() {
        let config = workspace.configuration
        modelLabel.stringValue = config.model.isEmpty ? "先在模型设置中连接模型" : config.provider.title + " · " + config.model
        modelLabel.textColor = WorkflowUI.secondary
        if let active = workspace.activeRunID, workspace.running { currentRunID = active }
        let selected = workspace.snapshot.history.firstIndex(where: { $0.id == currentRunID }) ?? 0
        history.removeAllItems()
        let format = DateFormatter(); format.dateFormat = "MM-dd HH:mm"
        for run in workspace.snapshot.history { history.addItem(withTitle: "\(format.string(from: run.startedAt)) · \(run.definition.name) · \(run.status.title)") }
        if history.numberOfItems == 0 { history.addItem(withTitle: "运行后会保留执行记录"); history.isEnabled = false }
        else { history.isEnabled = true; history.selectItem(at: min(selected, history.numberOfItems - 1)) }
        runButton.isEnabled = !workspace.running; cancelButton.isEnabled = workspace.running; retry.isEnabled = !workspace.running && currentRun != nil
        if workspace.running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        runStatus.stringValue = currentRun?.status.title ?? "准备运行"
        runStatus.textColor = currentRun?.status == .failed ? WorkflowUI.error : .labelColor
        issue.stringValue = workspace.issue
        issue.textColor = currentRun?.status == .failed || workspace.issue.contains("保存失败") ? WorkflowUI.error : WorkflowUI.secondary
        loading = true
        let row = executions.selectedRow
        executions.reloadData()
        if let run = currentRun, !run.steps.isEmpty {
            let finished = run.steps.last(where: { $0.status == .succeeded })
            let desired: Int
            if run.id != lastShownRunID || (workspace.running && finished?.id != lastFinishedStep) {
                desired = run.steps.lastIndex(where: { $0.status == .succeeded }) ?? run.steps.firstIndex(where: { $0.status == .running }) ?? 0
            } else { desired = min(max(0, row), run.steps.count - 1) }
            executions.selectRowIndexes(IndexSet(integer: desired), byExtendingSelection: false)
            lastShownRunID = run.id; lastFinishedStep = finished?.id
        }
        loading = false
        showSelectedOutput()
    }
    private func showSelectedOutput() {
        let text: String
        if let run = currentRun, run.steps.indices.contains(executions.selectedRow) {
            let step = run.steps[executions.selectedRow]
            resultTitle.stringValue = step.title
            text = !step.output.isEmpty ? step.output : step.error ?? (step.status == .running ? "模型正在处理这一步…" : "这一步还没有输出。")
            saveResult.isEnabled = !step.output.isEmpty; copyResult.isEnabled = !step.output.isEmpty
        } else {
            resultTitle.stringValue = "步骤结果"; text = "运行一个工作流后，可在这里查看每一步的输出。"
            saveResult.isEnabled = false; copyResult.isEnabled = false
        }
        // Status updates preserve selection and scrolling when the displayed result is unchanged.
        if output.string != text { output.string = text; output.scrollRangeToVisible(NSRange(location: 0, length: 0)) }
    }
    @objc func copyOutput() {
        OpenEnvironment.pasteboard.clearContents()
        if OpenEnvironment.pasteboard.setString(output.string, forType: .string) { issue.stringValue = "结果已复制" }
    }
    @objc func saveOutput() {
        guard saveResult.isEnabled else { return }
        let save = NSSavePanel(); save.nameFieldStringValue = "工作流结果.md"; save.allowedContentTypes = [.plainText, UTType(filenameExtension: "md")!]
        guard save.runModal() == .OK, let target = save.url else { return }
        let content = output.string
        Task { [weak self] in
            guard let self else { return }
            do {
                let proposal = try await Task.detached { try FileWriteProposal(target: target, content: content) }.value
                let alert = NSAlert(); alert.messageText = proposal.original == nil ? "确认新建文件？" : "确认替换文件内容？"
                alert.informativeText = target.lastPathComponent + "\n确认前不会写入文件。"
                let preview = NSTextView(); let scroll = WorkflowUI.scroll(text: preview, editable: false)
                scroll.frame = NSRect(x: 0, y: 0, width: 560, height: 330); preview.string = proposal.preview
                preview.setAccessibilityLabel("文件修改预览")
                alert.accessoryView = scroll; alert.addButton(withTitle: "确认写入"); alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else { self.issue.stringValue = "已取消，文件没有修改"; return }
                try await Task.detached { try proposal.commit(approved: true) }.value
                self.issue.stringValue = "已保存：" + target.lastPathComponent
            } catch { self.issue.stringValue = error.localizedDescription; self.issue.textColor = WorkflowUI.error }
        }
    }
}
