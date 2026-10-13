import Foundation

@MainActor
func runModelChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "PromptShelf-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PromptStore(directory: root)
    let body = "第一行\n\n  保留空格和换行\n🙂 second line"
    let prompt = Prompt(title: "核验", body: body, group: "测试")
    try store.change { $0.prompts.append(prompt) }
    let reopened = PromptStore(directory: root)
    precondition(reopened.library.prompts.last?.body == body)
    precondition(reopened.library.groups.contains("测试"))
    try reopened.change { library in
        library.groups.removeAll { $0 == "测试" }
        for i in library.prompts.indices where library.prompts[i].group == "测试" {
            library.prompts[i].group = ""
        }
    }
    precondition(!reopened.library.groups.contains("测试"))
    let exported = try PromptStore.encode(reopened.library)
    try store.restore(exported)
    precondition(store.library.prompts.last?.body == body)
    try Data("broken".utf8).write(to: store.file)
    let recovered = PromptStore(directory: root)
    precondition(recovered.loadWarning != nil && recovered.writable)
    precondition(!recovered.library.prompts.isEmpty)
    let before = recovered.library
    do {
        try recovered.restore(Data("invalid".utf8))
        preconditionFailure("invalid import accepted")
    } catch {}
    precondition(recovered.library == before)
    try recovered.change {
        $0.theme = "dark"
        $0.topRatio = 2
        $0.panelWidth = 438
        $0.panelHeight = 372
        $0.positionX = 0.4
        $0.positionY = 0.6
        $0.dockEdge = ""
        $0.activeGroup = "常用"
    }
    let final = PromptStore(directory: root)
    precondition(final.library.theme == "dark" && final.library.topRatio == 1)
    precondition(final.library.panelWidth == 438 && final.library.panelHeight == 372)
    precondition(
        final.library.positionX == 0.4 && final.library.positionY == 0.6 && final.library.activeGroup == "常用")
    var legacy = try JSONSerialization.jsonObject(with: exported) as! [String: Any]
    legacy.removeValue(forKey: "panelWidth")
    legacy.removeValue(forKey: "panelHeight")
    let migrated = try PromptStore.decode(JSONSerialization.data(withJSONObject: legacy))
    precondition(migrated.panelWidth == nil && migrated.prompts.last?.body == body)
    let deleteStore = PromptStore(directory: root.appendingPathComponent("delete-check"))
    let deleted = Prompt(title: "待删除", body: "只删此分组", group: "目标")
    let retained = Prompt(title: "保留", body: "其他分组保留", group: "其他")
    try deleteStore.change { $0.groups = ["目标", "其他"]; $0.prompts = [deleted, retained] }
    try deleteStore.deleteGroupAndContents("目标")
    precondition(deleteStore.library.groups == ["其他"] && deleteStore.library.prompts == [retained])
    let preserved = try FileManager.default.contentsOfDirectory(at: deleteStore.root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("library.before-group-delete-") }!
    let beforeDelete = try PromptStore.decode(Data(contentsOf: preserved))
    precondition(beforeDelete.prompts == [deleted, retained])
    print(
        "PASS: exact text persistence, groups, import/export, corruption recovery, invalid import protection, appearance and position"
    )
}
