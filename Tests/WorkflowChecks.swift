import AppKit

private func ensure(_ value: @autoclosure () throws -> Bool, _ message: String = "check failed") throws {
    let valid = try value()
    precondition(valid, message)
}

@MainActor
func runWorkflowChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PromptShelfOpen-workflow-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("fixture.md")
    try Data("原文：中文 😀 保留空格  \n".utf8).write(to: file)
    let original = try Data(contentsOf: file)
    let proposal = try FileWriteProposal(target: file, content: "新文稿 😀\n")
    try ensure(try Data(contentsOf: file) == original, "Preview must not write")
    do { try proposal.commit(approved: false); preconditionFailure("Unapproved write must fail") } catch {}
    try ensure(try Data(contentsOf: file) == original)
    try Data("他人更新".utf8).write(to: file)
    do { try proposal.commit(approved: true); preconditionFailure("Stale preview must fail") } catch {}
    try ensure(try String(contentsOf: file, encoding: .utf8) == "他人更新")
    let fresh = try FileWriteProposal(target: file, content: "新文稿 😀\n")
    try fresh.commit(approved: true)
    try ensure(try String(contentsOf: file, encoding: .utf8) == "新文稿 😀\n")
    let newTarget = root.appendingPathComponent("new.md")
    let newProposal = try FileWriteProposal(target: newTarget, content: "新文件")
    precondition(!FileManager.default.fileExists(atPath: newTarget.path))
    try newProposal.commit(approved: true)
    try ensure(try String(contentsOf: newTarget, encoding: .utf8) == "新文件")
    let link = root.appendingPathComponent("link.md")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    do { _ = try FileWriteProposal(target: link, content: "bad"); preconditionFailure("Symlink preview must fail") } catch {}
    let source = try WorkflowFiles.read([file], note: "补充说明")
    precondition(source.contains("新文稿 😀") && source.contains("补充说明"))
    do { _ = try WorkflowFiles.read([], note: ""); preconditionFailure("Empty input must fail") } catch {}
    for invalid in ["http://example.com", "https://user:password@example.com/v1", "https://example.com/v1?key=secret"] {
        do { _ = try ModelConfiguration(baseURL: invalid, model: "test").validated(); preconditionFailure("Unsafe model address must fail") } catch {}
    }
    for flow in WorkflowDefinition.examples { try flow.validate() }
    let invalid = WorkflowDefinition(name: "invalid", steps: [WorkflowStep(title: "first", instruction: "test", input: .previous)])
    do { try invalid.validate(); preconditionFailure("First step needs real input") } catch {}
    let combined = WorkflowFiles.input(for: WorkflowStep(title: "x", instruction: "x", input: .filesAndPrevious), source: "原始", previous: "摘要")
    precondition(combined.contains("原始") && combined.contains("摘要"))
    print("PASS: file reads, empty input, safe endpoints, input chaining, no-write preview, denied/stale/symlink writes and approved exact Unicode save")
}

@MainActor
func runAsyncWorkflowChecks(directory: URL, realModel: String?) async throws {
    try runWorkflowChecks()
    let disk = WorkflowDiskStore(directory: directory.appendingPathComponent("ordered"))
    var old = WorkflowSnapshot(); old.revision = 1
    var newest = old; newest.revision = 3; newest.workflows[0].name = "最新快照"
    try await disk.save(newest); try await disk.save(old)
    let reopened = try WorkflowDiskStore.load(directory: directory.appendingPathComponent("ordered"))
    precondition(reopened == newest, "Older commits cannot overwrite a newer revision")
    let blocked = directory.appendingPathComponent("not-a-directory")
    try Data("block".utf8).write(to: blocked)
    do { try await WorkflowDiskStore(directory: blocked).save(newest); preconditionFailure("Save failure must be surfaced") } catch {}
    if ProcessInfo.processInfo.environment["PROMPTSHELF_OPEN_SKIP_KEYCHAIN_TEST"] != "1" {
    let secretService = "io.github.promptshelf.open.qa.\(UUID())"
    try await Task.detached {
        try ModelSecrets.write("synthetic-fixture-key", account: "test", service: secretService)
        let value = try ModelSecrets.read("test", service: secretService)
        precondition(value == "synthetic-fixture-key")
        try ModelSecrets.write("", account: "test", service: secretService)
        try ensure(try ModelSecrets.read("test", service: secretService) == nil)
    }.value
    } else { print("SKIP: isolated Keychain round-trip (CI without a graphical login session)") }
    print("PASS: ordered immutable snapshots, reopen and save-error propagation")
    guard let realModel else { return }
    let config = ModelConfiguration(provider: .ollama, baseURL: "http://127.0.0.1:11434", model: realModel, maxOutputTokens: 1536, timeout: 180)
    let apiConfig = ModelConfiguration(provider: .compatible, baseURL: "http://127.0.0.1:11434/v1", model: realModel, maxOutputTokens: 128, timeout: 180, reasoningEffort: "none")
    let apiResponse = try await ModelClient(configuration: apiConfig).generate(instruction: "只回复：API 连接成功", input: "连接验证")
    guard !apiResponse.isEmpty else { throw WorkflowError.invalid("兼容 API 实测失败。") }
    print("PASS: real OpenAI-compatible /v1/chat/completions generation: \(apiResponse)")
    let source = directory.appendingPathComponent("demo-meeting.md")
    let material = """
    # 项目会议记录（虚构示例）
    2026年10月14日，团队讨论社区阅读活动。
    决定：10月18日举办第一场活动，预算为320元，最多20人参加。
    小林负责10月16日前完成报名表，小周负责10月17日前准备场地。
    目标：让参与者交换读书心得。未确定是否开展第二场活动。
    """
    try Data(material.utf8).write(to: source)
    let bytes = try Data(contentsOf: source)
    let workspace = try WorkflowWorkspace(directory: directory.appendingPathComponent("real"))
    workspace.edit { $0.configuration = config }
    try workspace.start(definition: WorkflowDefinition.examples[0], urls: [source], note: "请保留日期、预算和负责人。")
    let deadline = Date().addingTimeInterval(420)
    while workspace.running && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
    if workspace.running { try await workspace.finishForTermination(); throw WorkflowError.invalid("真实工作流验证超时。") }
    guard let run = workspace.snapshot.history.first, run.status == .succeeded, run.steps.allSatisfy({ $0.status == .succeeded && !$0.output.isEmpty }) else {
        throw WorkflowError.invalid("真实工作流失败：" + workspace.issue)
    }
    guard run.steps[0].output.contains("320"), run.result.contains("320"), run.result.contains("小林") else { throw WorkflowError.invalid("真实文稿没有保留关键事实。") }
    let unchanged = try Data(contentsOf: source); precondition(unchanged == bytes)
    try await workspace.flush()
    let saved = try WorkflowDiskStore.load(directory: directory.appendingPathComponent("real"))
    precondition(saved.history.first?.result == run.result)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(run).write(to: directory.appendingPathComponent("real-execution.json"), options: .atomic)
    print("PASS: real file → extraction → summary → document; all 3 outputs and facts checked, source unchanged and restart persistence exact")
    print("RESULT:\n" + run.result)
    var missing = config; missing.model = "promptshelf-test-missing-\(UUID())"
    workspace.edit { $0.configuration = missing }
    try workspace.start(definition: WorkflowDefinition.examples[1], urls: [source], note: "")
    while workspace.running { try await Task.sleep(nanoseconds: 100_000_000) }
    precondition(workspace.snapshot.history.first?.status == .failed)
    precondition(workspace.snapshot.history.first?.steps.first?.status == .failed)
    workspace.edit { $0.configuration = config }
    var long = WorkflowDefinition.examples[1]; long.steps[0].instruction = "详细讲解材料，用3000字中文展开，保持事实准确。"
    try workspace.start(definition: long, urls: [source], note: "")
    while workspace.snapshot.history.first?.steps.first?.status != .running && workspace.running { try await Task.sleep(nanoseconds: 10_000_000) }
    try await Task.sleep(nanoseconds: 100_000_000)
    try await workspace.finishForTermination()
    precondition(workspace.snapshot.history.first?.status == .cancelled)
    let final = try WorkflowDiskStore.load(directory: directory.appendingPathComponent("real"))
    precondition(final.history.first?.status == .cancelled && final.history.contains(where: { $0.id == run.id && $0.status == .succeeded }))
    print("PASS: real missing-model failure, network task cancellation and shutdown flush; previous successful results preserved")
}
