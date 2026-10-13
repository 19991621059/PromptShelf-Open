import AppKit

@MainActor
func runWorkflowWindowChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PromptShelfOpen-window-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let host = AppDelegate(store: PromptStore(directory: root.appendingPathComponent("prompts")), presentsWindows: false)
    let workspace = try WorkflowWorkspace(directory: root.appendingPathComponent("tasks"))
    let controller = WorkflowWindowController(host: host, workspace: workspace)
    defer {
        workspace.changed = nil
        for table in [controller.flows, controller.steps, controller.executions] { table.delegate = nil; table.dataSource = nil }
        controller.window?.contentView = nil; controller.window?.close()
    }
    for size in [NSSize(width: 1060, height: 640), NSSize(width: 1220, height: 780)] {
        controller.window?.setContentSize(size)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        precondition(controller.instruction.enclosingScrollView!.bounds.height >= 76)
        precondition(controller.output.enclosingScrollView!.bounds.height >= 250)
        precondition(controller.steps.numberOfRows == 3 && controller.steps.selectedRow == 0)
        precondition(controller.history.isHidden && controller.executionScroll.isHidden && controller.cancelButton.isHidden)
    }
    controller.note.string = "中文测试材料"
    controller.runWorkflow()
    precondition(!controller.issue.stringValue.isEmpty && !controller.issue.isHidden, "Missing model validation must remain visible")
    precondition(!workspace.running && workspace.snapshot.history.isEmpty, "Validation must not start a task")
    controller.issue.stringValue = ""; precondition(controller.issue.isHidden)
    controller.issue.stringValue = "结果已复制"; precondition(!controller.issue.isHidden)
    print("PASS: compact workflow window at minimum/default sizes, initial selection, empty state and visible action/validation feedback")
}
