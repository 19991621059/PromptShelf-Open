import AppKit
import UniformTypeIdentifiers

final class WorkflowMessageField: NSTextField {
    override var stringValue: String { didSet { isHidden = stringValue.isEmpty } }
}

@MainActor
final class WorkflowWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate {
    unowned let host: AppDelegate
    let workspace: WorkflowWorkspace
    let flows = NSTableView(), steps = NSTableView(), executions = NSTableView()
    let stepName = NSTextField(), input = NSPopUpButton()
    let instruction = NSTextView(), note = NSTextView(), output = NSTextView()
    let filesLabel = WorkflowUI.label("尚未选择文件", size: 12)
    let runStatus = WorkflowUI.label("", size: 12)
    let issue = WorkflowMessageField(wrappingLabelWithString: "")
    let resultTitle = WorkflowUI.label("步骤结果", size: 14, weight: .semibold)
    let history = NSPopUpButton()
    let prompts = NSPopUpButton(frame: .zero, pullsDown: true)
    let spinner = NSProgressIndicator()
    var runButton: NSButton!, cancelButton: NSButton!, saveResult: NSButton!, copyResult: NSButton!
    var retry: NSButton!, add: NSButton!, remove: NSButton!, up: NSButton!, down: NSButton!
    var modelButton: NSButton!, clearFilesButton: NSButton!, executionScroll: NSScrollView!
    var models: ModelSettingsWindowController?
    var selectedFlowID: UUID?
    var currentRunID: UUID?
    var fileURLs: [URL] = []
    private var loading = true
    private var lastShownRunID: UUID?
    private var lastFinishedStep: UUID?
    private var handlers: [MenuAction] = []
    var currentFlowIndex: Int? { workspace.snapshot.workflows.firstIndex(where: { $0.id == selectedFlowID }) }
    var currentFlow: WorkflowDefinition? { currentFlowIndex.map { workspace.snapshot.workflows[$0] } }
    var currentRun: WorkflowExecution? { workspace.snapshot.history.first(where: { $0.id == currentRunID }) }

    init(host: AppDelegate, workspace: WorkflowWorkspace) {
        self.host = host; self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "PromptShelf-Open · AI 工作流"
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 1060, height: 640)
        window.appearance = host.panel?.appearance
        window.titlebarAppearsTransparent = true
        super.init(window: window)
        window.delegate = self; window.center()
        if OpenEnvironment.sandbox == nil { window.setFrameAutosaveName("PromptShelfOpen.Workflows") }
        issue.font = .systemFont(ofSize: 12)
        for table in [flows, steps, executions] { table.dataSource = self; table.delegate = self; table.allowsEmptySelection = false }
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
        let heading = WorkflowUI.label("工作流", size: 14, weight: .semibold)
        let flowScroll = WorkflowUI.table(flows, label: "工作流列表"); flows.rowHeight = 38
        let more = NSPopUpButton(frame: .zero, pullsDown: true)
        more.addItem(withTitle: "更多")
        more.setAccessibilityLabel("工作流操作")
        for (title, action) in [("重命名", #selector(renameWorkflow)), ("复制工作流", #selector(duplicateWorkflow)), ("删除工作流", #selector(deleteWorkflow))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; more.menu?.addItem(item)
        }
        let actions = WorkflowUI.stack([
            WorkflowUI.button("新建", target: self, action: #selector(newWorkflow), symbol: "plus"),
            more
        ], vertical: false, spacing: 8)
        let library = WorkflowUI.button("提示词库", target: self, action: #selector(showPrompts), symbol: "text.quote")
        modelButton = WorkflowUI.button("连接模型…", target: self, action: #selector(showModels), symbol: "slider.horizontal.3")
        let stack = WorkflowUI.stack([heading, flowScroll, actions, WorkflowUI.separator(), library, modelButton!], spacing: 12)
        WorkflowUI.embed(stack, in: pane, inset: 16)
        for view in [flowScroll, library, modelButton!] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        flowScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return pane
    }
    private func buildEditor() -> NSView {
        let pane = NSView()
        let sourceHeading = WorkflowUI.label("材料", size: 14, weight: .semibold)
        clearFilesButton = WorkflowUI.button("移除文件", target: self, action: #selector(clearFiles), symbol: "xmark")
        clearFilesButton.imagePosition = .imageOnly; clearFilesButton.toolTip = "移除所选文件"; clearFilesButton.isHidden = true
        let sourceButtons = WorkflowUI.stack([
            WorkflowUI.button("选择文件…", target: self, action: #selector(chooseFiles), symbol: "doc.badge.plus"),
            clearFilesButton!
        ], vertical: false)
        filesLabel.isHidden = true
        let noteScroll = WorkflowUI.scroll(text: note, editable: true)
        noteScroll.heightAnchor.constraint(equalToConstant: 50).isActive = true
        let noteLabel = WorkflowUI.label("文字 / 补充说明", size: 11); noteLabel.textColor = WorkflowUI.secondary
        let stepHeading = WorkflowUI.label("步骤", size: 14, weight: .semibold)
        let stepScroll = WorkflowUI.table(steps, label: "工作流步骤"); steps.rowHeight = 32
        steps.style = .plain; steps.backgroundColor = .textBackgroundColor
        stepScroll.heightAnchor.constraint(equalToConstant: 112).isActive = true
        add = WorkflowUI.button("添加步骤", target: self, action: #selector(addStep), symbol: "plus")
        remove = WorkflowUI.button("删除步骤", target: self, action: #selector(removeStep), symbol: "trash")
        up = WorkflowUI.button("上移步骤", target: self, action: #selector(stepUp), symbol: "arrow.up")
        down = WorkflowUI.button("下移步骤", target: self, action: #selector(stepDown), symbol: "arrow.down")
        for button in [remove!, up!, down!] { button.imagePosition = .imageOnly; button.toolTip = button.title }
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
        let stack = WorkflowUI.stack([sourceHeading, sourceButtons,
            filesLabel, noteLabel, noteScroll, stepHeading, stepScroll, tools, stepFields, instructionScroll, prompts, runActions], spacing: 6)
        WorkflowUI.embed(stack, in: pane, inset: 22)
        for view in [filesLabel, noteScroll, stepScroll, stepFields, instructionScroll] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stepName.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return pane
    }
    private func buildResults() -> NSView {
        let pane = NSView()
        let heading = WorkflowUI.label("结果", size: 14, weight: .semibold)
        history.target = self; history.action = #selector(selectHistory); history.setAccessibilityLabel("选择执行记录")
        history.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let statusRow = WorkflowUI.stack([heading, NSView(), spinner, runStatus], vertical: false)
        executionScroll = WorkflowUI.table(executions, label: "各步骤执行状态")
        executions.style = .plain; executions.backgroundColor = .textBackgroundColor; executions.rowHeight = 44
        executionScroll.heightAnchor.constraint(equalToConstant: 136).isActive = true
        let outputScroll = WorkflowUI.scroll(text: output, editable: false)
        outputScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        copyResult = WorkflowUI.button("复制结果", target: self, action: #selector(copyOutput), symbol: "doc.on.doc")
        saveResult = WorkflowUI.button("预览并保存…", target: self, action: #selector(saveOutput), symbol: "square.and.arrow.up")
        retry = WorkflowUI.button("重新运行", target: self, action: #selector(retryRun), symbol: "arrow.clockwise")
        let actions = WorkflowUI.stack([copyResult, saveResult], vertical: false)
        let stack = WorkflowUI.stack([statusRow, history, executionScroll!, outputScroll, actions, retry, issue], spacing: 12)
        WorkflowUI.embed(stack, in: pane, inset: 22)
        for view in [statusRow, history, executionScroll!, outputScroll, issue] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
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
            text = workspace.snapshot.workflows[row].name
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
        cell.toolTip = text
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
            || (stepName.currentEditor() as? NSTextView)?.hasMarkedText() == true {
            issue.stringValue = "请先完成中文输入，再切换步骤或运行。"
            return false
        }
        if instruction.string.count > 8000 || stepName.stringValue.count > 100 {
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
        guard !loading, let field = notification.object as? NSTextField,
            (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if field === stepName { updateStep() }
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
        loadFlow(); renameWorkflow()
    }
    @objc func renameWorkflow() {
        guard readyForAction(), let index = currentFlowIndex else { return }
        let field = NSTextField(string: workspace.snapshot.workflows[index].name)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 26); field.setAccessibilityLabel("工作流名称")
        let alert = NSAlert(); alert.messageText = "工作流名称"; alert.accessoryView = field
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 120 else { issue.stringValue = "名称需要 1–120 字"; issue.isHidden = false; return }
        workspace.edit { $0.workflows[index].name = value }; loadFlow(selectStep: max(0, steps.selectedRow))
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
        prompts.removeAllItems(); prompts.addItem(withTitle: "从提示词库添加…")
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
        filesLabel.isHidden = fileURLs.isEmpty; clearFilesButton.isHidden = fileURLs.isEmpty
    }
    @objc func clearFiles() { fileURLs = []; filesLabel.isHidden = true; clearFilesButton.isHidden = true }
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
        modelButton.title = config.model.isEmpty ? "连接模型…" : config.model
        modelButton.setAccessibilityLabel(config.model.isEmpty ? "连接模型" : "模型设置 · " + config.model)
        modelButton.toolTip = config.provider.title + " · " + config.baseURL
        if let active = workspace.activeRunID, workspace.running { currentRunID = active }
        let selected = workspace.snapshot.history.firstIndex(where: { $0.id == currentRunID }) ?? 0
        history.removeAllItems()
        let format = DateFormatter(); format.dateFormat = "MM-dd HH:mm"
        for run in workspace.snapshot.history { history.addItem(withTitle: "\(format.string(from: run.startedAt)) · \(run.definition.name) · \(run.status.title)") }
        history.isHidden = history.numberOfItems == 0
        if history.numberOfItems == 0 { history.isEnabled = false }
        else { history.isEnabled = true; history.selectItem(at: min(selected, history.numberOfItems - 1)) }
        runButton.isEnabled = !workspace.running; cancelButton.isEnabled = workspace.running; cancelButton.isHidden = !workspace.running
        retry.isEnabled = !workspace.running && currentRun != nil
        retry.isHidden = workspace.running || currentRun == nil || currentRun?.status == .succeeded
        executionScroll.isHidden = currentRun == nil
        if workspace.running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        runStatus.stringValue = currentRun?.status.title ?? ""
        runStatus.textColor = currentRun?.status == .failed ? WorkflowUI.error : WorkflowUI.secondary
        let redundant = workspace.issue == "模型设置已保存" || workspace.issue == "任务完成，结果已保存在本机"
            || (workspace.running && (workspace.issue == "读取所选文件…" || workspace.issue.hasPrefix("第 ")))
        issue.stringValue = redundant ? "" : workspace.issue
        issue.isHidden = issue.stringValue.isEmpty
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
            resultTitle.stringValue = "步骤结果"; text = ""
            saveResult.isEnabled = false; copyResult.isEnabled = false
        }
        // Status updates preserve selection and scrolling when the displayed result is unchanged.
        if output.string != text { output.string = text; output.scrollRangeToVisible(NSRange(location: 0, length: 0)) }
        saveResult.isHidden = !saveResult.isEnabled; copyResult.isHidden = !copyResult.isEnabled
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
