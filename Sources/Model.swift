import Foundation

struct Prompt: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var body: String
    var group: String
    var richText: RichTextDocument? = nil
    enum CodingKeys: String, CodingKey { case id, title, body, group, richText }
    init(id: UUID = UUID(), title: String, body: String, group: String, richText: RichTextDocument? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.group = group
        self.richText = richText
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        body = try values.decode(String.self, forKey: .body)
        group = try values.decode(String.self, forKey: .group)
        // Optional future/corrupt styles must never prevent recovering the text.
        richText = try? values.decode(RichTextDocument.self, forKey: .richText)
        if richText?.valid(for: body) != true { richText = nil }
    }
}

struct Library: Codable, Equatable {
    var version = 1
    var groups: [String] = ["常用"]
    var prompts: [Prompt] = []
    static let retiredExamples: [Prompt] = [
        Prompt(title: "讲解", body: "请用简单、清楚的中文讲解以下内容。先说核心意思，再用具体例子逐步解释；专业术语第一次出现时说明含义。", group: "常用"),
        Prompt(title: "润色", body: "请润色以下文字，保留原意，表达自然、简洁，删除重复和空话。直接给出修改后的文本。", group: "常用"),
        Prompt(title: "检查", body: "请检查以下内容，找出事实错误、逻辑漏洞和不清楚的表达。按影响大小列出问题，并给出具体修改建议；不确定的地方请明确标出。", group: "常用"),
    ]
    var examplesRemoved: Bool?
    var pinned: Bool?
    var theme = "light"
    var screenID: UInt32?
    var topRatio: Double = 0.32
    var groupRailWidth: Double?
    var panelWidth: Double?
    var panelHeight: Double?
    var positionX: Double?
    var positionY: Double?
    var dockEdge: String?
    var activeGroup: String?

    mutating func normalize() throws {
        guard version == 1 else { throw StoreError.invalid("不支持这个文件版本") }
        guard prompts.count <= 10000, groups.count <= 500 else { throw StoreError.invalid("文件内容过多") }
        guard Set(prompts.map(\.id)).count == prompts.count else { throw StoreError.invalid("提示词编号重复") }
        var seen = Set<String>()
        groups = groups.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
            !$0.isEmpty && $0 != "未分组" && $0 != "全部" && seen.insert($0).inserted
        }
        for index in prompts.indices {
            if let rich = prompts[index].richText, !rich.valid(for: prompts[index].body) {
                prompts[index].richText = nil
            }
            prompts[index].title = prompts[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompts[index].title.isEmpty,
                !prompts[index].body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw StoreError.invalid("标题和提示词不能为空") }
            if prompts[index].group == "未分组" { prompts[index].group = "" }
            if !prompts[index].group.isEmpty && !groups.contains(prompts[index].group) {
                groups.append(prompts[index].group)
            }
        }
        if !["light", "dark", "system"].contains(theme) { theme = "light" }
        if !topRatio.isFinite { topRatio = 0.32 }
        topRatio = min(1, max(0, topRatio))
        if let width = groupRailWidth { groupRailWidth = width.isFinite ? min(260, max(86, width)) : nil }
        if let width = panelWidth { panelWidth = width.isFinite ? min(1000, max(312, width)) : nil }
        if let height = panelHeight { panelHeight = height.isFinite ? min(1600, max(140, height)) : nil }
        if let x = positionX { positionX = x.isFinite ? min(1, max(0, x)) : nil }
        if let y = positionY { positionY = y.isFinite ? min(1, max(0, y)) : nil }
        if let group = activeGroup, !group.isEmpty, !groups.contains(group) { activeGroup = nil }
        if let edge = dockEdge,
            !["", "left", "right", "top", "bottom", "left|top", "left|bottom", "right|top", "right|bottom"]
                .contains(edge)
        {
            dockEdge = ""
        }
    }
}

enum StoreError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

extension Library {
    mutating func copyDeviceSettings(from other: Library) {
        theme = other.theme
        screenID = other.screenID
        topRatio = other.topRatio
        groupRailWidth = other.groupRailWidth
        panelWidth = other.panelWidth
        panelHeight = other.panelHeight
        positionX = other.positionX
        positionY = other.positionY
        dockEdge = other.dockEdge
        pinned = other.pinned
        activeGroup = nil
    }
}
