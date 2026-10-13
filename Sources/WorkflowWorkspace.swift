import AppKit

@MainActor
final class WorkflowWorkspace {
    private(set) var snapshot: WorkflowSnapshot
    let disk: WorkflowDiskStore
    var changed: (() -> Void)?
    private(set) var issue = ""
    private(set) var activeRunID: UUID?
    private var executionTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    var running: Bool { executionTask != nil }
    var configuration: ModelConfiguration { snapshot.configuration }
    init(directory: URL) throws {
        snapshot = try WorkflowDiskStore.load(directory: directory)
        disk = WorkflowDiskStore(directory: directory)
        for index in snapshot.history.indices where [.reading, .running, .pending].contains(snapshot.history[index].status) {
            snapshot.history[index].status = .interrupted
            snapshot.history[index].error = "上次运行在应用退出时中断；选择材料后可重新运行。"
            snapshot.history[index].finishedAt = Date()
            for step in snapshot.history[index].steps.indices where [.reading, .running].contains(snapshot.history[index].steps[step].status) {
                snapshot.history[index].steps[step].status = .interrupted
            }
        }
        snapshot.revision &+= 1
    }
    func edit(_ body: (inout WorkflowSnapshot) -> Void) {
        body(&snapshot)
        snapshot.revision &+= 1
        persistSoon()
    }
    private func persistSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 350_000_000); try Task.checkCancellation() } catch { return }
            guard let self else { return }
            do { try await self.persist() } catch { self.issue = "保存失败：" + error.localizedDescription; self.changed?() }
        }
    }
    private func persist() async throws {
        let immutable = snapshot
        try await disk.save(immutable)
    }
    func flush() async throws {
        saveTask?.cancel()
        try await persist()
    }
    func saveConfiguration(_ config: ModelConfiguration, enteredKey: String?, removeKey: Bool) async throws {
        let valid = try config.validated()
        if removeKey || enteredKey?.isEmpty == false {
            let key = removeKey ? "" : enteredKey!
            try await Task.detached { try ModelSecrets.write(key, account: valid.credentialID) }.value
        }
        edit { $0.configuration = valid }
        try await flush()
        issue = "模型设置已保存"
        changed?()
    }
    func client(for config: ModelConfiguration) async throws -> ModelClient {
        let key = try await Task.detached { try ModelSecrets.read(config.credentialID) ?? "" }.value
        if config.provider == .compatible, key.isEmpty, let host = URL(string: config.baseURL)?.host,
            !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) {
            throw WorkflowError.invalid("请先在模型设置中保存 API Key。")
        }
        return ModelClient(configuration: config, key: key)
    }
    func start(definition: WorkflowDefinition, urls: [URL], note: String) throws {
        guard !running else { throw WorkflowError.invalid("已有任务正在运行。请先取消或等待完成。") }
        try definition.validate()
        let config = try snapshot.configuration.validated()
        let run = WorkflowExecution(definition: definition, model: config.model, provider: config.provider,
            sourceNames: urls.map(\.lastPathComponent), status: .reading,
            steps: definition.steps.map { StepExecution(id: $0.id, title: $0.title) })
        edit {
            $0.history.insert(run, at: 0)
            $0.history = Array($0.history.prefix(40))
        }
        activeRunID = run.id
        issue = "读取所选文件…"
        executionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.executionTask = nil; self.changed?() }
            do {
                try await self.flush()
                let extraction = Task.detached { try WorkflowFiles.read(urls, note: note) }
                let source = try await withTaskCancellationHandler(operation: { try await extraction.value }, onCancel: { extraction.cancel() })
                try Task.checkCancellation()
                let client = try await self.client(for: config)
                self.update(run.id) { $0.status = .running }
                var previous = ""
                for (index, step) in definition.steps.enumerated() {
                    try Task.checkCancellation()
                    self.update(run.id) { value in
                        value.steps[index].status = .running
                        value.steps[index].startedAt = Date()
                    }
                    self.issue = "第 \(index + 1) / \(definition.steps.count) 步：\(step.title)"
                    self.changed?()
                    try await self.flush()
                    let output = try await client.generate(instruction: step.instruction, input: WorkflowFiles.input(for: step, source: source, previous: previous))
                    try Task.checkCancellation()
                    previous = output
                    self.update(run.id) { value in
                        value.steps[index].status = .succeeded
                        value.steps[index].output = output
                        value.steps[index].finishedAt = Date()
                    }
                    self.changed?()
                    try await self.flush()
                }
                self.update(run.id) { $0.status = .succeeded; $0.finishedAt = Date() }
                self.issue = "任务完成，结果已保存在本机"
                try await self.flush()
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                let status: ExecutionStatus = cancelled ? .cancelled : .failed
                let message = cancelled ? "任务已取消，已完成的步骤结果仍保留。" : error.localizedDescription
                self.update(run.id) { value in
                    value.status = status; value.error = message; value.finishedAt = Date()
                    for index in value.steps.indices where value.steps[index].status == .running {
                        value.steps[index].status = status; value.steps[index].error = message; value.steps[index].finishedAt = Date()
                    }
                }
                self.issue = message
                do { try await self.persist() } catch { self.issue += "\n执行记录保存失败：" + error.localizedDescription }
            }
        }
        changed?()
    }
    private func update(_ id: UUID, _ body: (inout WorkflowExecution) -> Void) {
        guard let index = snapshot.history.firstIndex(where: { $0.id == id }) else { return }
        body(&snapshot.history[index])
        snapshot.revision &+= 1
    }
    func cancel() { executionTask?.cancel() }
    func finishForTermination() async throws {
        cancel()
        await executionTask?.value
        try await flush()
    }
}
