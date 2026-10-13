import Foundation

enum ModelProvider: String, Codable, CaseIterable {
    case ollama, compatible
    var title: String { self == .ollama ? "Ollama 本地模型" : "OpenAI 兼容 API" }
}

struct ModelConfiguration: Codable, Equatable {
    var provider: ModelProvider = .ollama
    var baseURL = "http://127.0.0.1:11434"
    var model = ""
    var maxOutputTokens = 1536
    var timeout: Double = 180
    var reasoningEffort: String? = nil
    var credentialID: String { RichTextDocument.fingerprint(provider.rawValue + ":" + baseURL) }
    func validated() throws -> ModelConfiguration {
        var value = self
        value.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        value.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value.baseURL), let host = url.host,
            url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
            url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()))
        else { throw WorkflowError.invalid("服务地址需要 HTTPS；本机地址可以使用 HTTP。请填写 API 根地址。") }
        guard !value.model.isEmpty, value.model.count <= 160 else { throw WorkflowError.invalid("请填写模型名称，或先从 Ollama 获取模型。") }
        guard (64...8192).contains(maxOutputTokens), (10...600).contains(timeout) else { throw WorkflowError.invalid("输出上限需为 64–8192，超时需为 10–600 秒。") }
        return value
    }
}

enum StepInput: String, Codable, CaseIterable {
    case files, previous, filesAndPrevious
    var title: String {
        switch self { case .files: return "所选文件与补充说明"; case .previous: return "上一步输出"; case .filesAndPrevious: return "文件、说明与上一步输出" }
    }
}

struct WorkflowStep: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var instruction: String
    var input: StepInput = .previous
}

struct WorkflowDefinition: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var steps: [WorkflowStep]
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120 else { throw WorkflowError.invalid("请为工作流填写名称（最多 120 字）。") }
        guard !steps.isEmpty, steps.count <= 20, Set(steps.map(\.id)).count == steps.count else { throw WorkflowError.invalid("工作流需要 1–20 个步骤，步骤编号不能重复。") }
        for (index, step) in steps.enumerated() {
            guard !step.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !step.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                step.title.count <= 100, step.instruction.count <= 8000
            else { throw WorkflowError.invalid("第 \(index + 1) 步需要名称和提示词；提示词最多 8000 字。") }
            if index == 0 && step.input == .previous { throw WorkflowError.invalid("第一步没有上一步，请选择文件与补充说明作为输入。") }
        }
    }
    static var examples: [WorkflowDefinition] {
        [
            WorkflowDefinition(name: "文件 → 信息 → 文稿", steps: [
                WorkflowStep(title: "提取关键信息", instruction: "从材料中提取事实、数据、决定和待办。保留人物、时间与数字，不补充材料中没有的信息。用中文条目输出。", input: .files),
                WorkflowStep(title: "整理摘要", instruction: "把提取的信息整理为简洁摘要，包含核心内容和下一步行动。保持所有关键事实准确，用中文输出。", input: .previous),
                WorkflowStep(title: "生成文稿", instruction: "根据原始材料和摘要，写一份可直接使用的中文工作简报，包含标题、概述、决定与待办。控制在 400 字内，不编造事实。", input: .filesAndPrevious)
            ]),
            WorkflowDefinition(name: "资料摘要", steps: [
                WorkflowStep(title: "总结材料", instruction: "请用中文总结所选材料。先给出核心结论，再列出重要事实、数字与待办。不确定的信息明确标注。", input: .files)
            ]),
            WorkflowDefinition(name: "文稿润色", steps: [
                WorkflowStep(title: "改进表达", instruction: "润色以下文稿，保留原意、数字和专有名称。删掉重复内容和空话，直接给出修改后的完整中文文稿。", input: .files)
            ])
        ]
    }
}

enum ExecutionStatus: String, Codable {
    case pending, reading, running, succeeded, failed, cancelled, interrupted
    var title: String {
        switch self {
        case .pending: return "等待执行"; case .reading: return "读取文件"; case .running: return "执行中"
        case .succeeded: return "已完成"; case .failed: return "失败"; case .cancelled: return "已取消"; case .interrupted: return "已中断"
        }
    }
}

struct StepExecution: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var status: ExecutionStatus = .pending
    var output = ""
    var error: String? = nil
    var startedAt: Date? = nil
    var finishedAt: Date? = nil
    var elapsed: Double? { guard let startedAt, let finishedAt else { return nil }; return finishedAt.timeIntervalSince(startedAt) }
}

struct WorkflowExecution: Codable, Equatable, Identifiable {
    var id = UUID()
    var definition: WorkflowDefinition
    var model: String
    var provider: ModelProvider
    var sourceNames: [String]
    var status: ExecutionStatus = .pending
    var startedAt = Date()
    var finishedAt: Date? = nil
    var steps: [StepExecution]
    var error: String? = nil
    var result: String { steps.last(where: { $0.status == .succeeded })?.output ?? "" }
}

struct WorkflowSnapshot: Codable, Equatable {
    var version = 1
    var revision: UInt64 = 0
    var configuration = ModelConfiguration()
    var workflows = WorkflowDefinition.examples
    var history: [WorkflowExecution] = []
    func validate() throws {
        guard version == 1, workflows.count <= 100, history.count <= 40,
            Set(workflows.map(\.id)).count == workflows.count else { throw WorkflowError.invalid("工作流数据格式或大小不受支持。") }
        // Drafts may be incomplete; executable definitions are validated when running.
        for flow in workflows {
            guard flow.name.count <= 120, flow.steps.count <= 20,
                flow.steps.allSatisfy({ $0.title.count <= 100 && $0.instruction.count <= 8000 })
            else { throw WorkflowError.invalid("工作流内容过长。") }
        }
    }
}

enum WorkflowError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

actor WorkflowDiskStore {
    let file: URL
    private var savedRevision: UInt64? = nil
    init(directory: URL) { file = directory.appendingPathComponent("workflows.json") }
    static func load(directory: URL) throws -> WorkflowSnapshot {
        let url = directory.appendingPathComponent("workflows.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return WorkflowSnapshot() }
        let data = try Data(contentsOf: url)
        guard data.count <= 32 * 1024 * 1024 else { throw WorkflowError.invalid("执行记录超过 32 MB，请先备份和整理数据文件。") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(WorkflowSnapshot.self, from: data)
        try snapshot.validate()
        return snapshot
    }
    func save(_ snapshot: WorkflowSnapshot) throws {
        if let savedRevision, snapshot.revision <= savedRevision { return }
        try snapshot.validate()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(snapshot)
        guard bytes.count <= 32 * 1024 * 1024 else { throw WorkflowError.invalid("执行记录过大，无法保存。请清理旧记录。") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path) {
            try Data(contentsOf: file).write(to: file.deletingLastPathComponent().appendingPathComponent("workflows.backup.json"), options: .atomic)
        }
        try bytes.write(to: file, options: .atomic)
        savedRevision = snapshot.revision
    }
}
