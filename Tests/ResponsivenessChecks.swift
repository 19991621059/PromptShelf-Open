import AppKit

@MainActor
func runResponsivenessChecks() throws {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
    let text = GuidedTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
    text.isVerticallyResizable = true
    text.isHorizontallyResizable = false
    text.textContainer?.widthTracksTextView = true
    scroll.documentView = text
    let body = (0..<2400).map { "第\($0)行 中文输入 English 😀" }.joined(separator: "\n")
    text.loadBody(body, richText: nil)
    text.fitScrollViewport()
    text.settleDocumentExtent()
    let initialPasses = text.extentPassCount
    let start = ProcessInfo.processInfo.systemUptime
    for index in 0..<80 {
        text.setSelectedRange(NSRange(location: 2, length: 0))
        text.insertText("字", replacementRange: text.selectedRange())
        scroll.setFrameSize(NSSize(width: CGFloat(420 + index % 2), height: 280))
        text.fitScrollViewport()
    }
    let burstMS = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
    precondition(text.extentPassCount == initialPasses, "Tracking must not force whole-document layout")
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    precondition(text.extentPassCount == initialPasses + 1)
    precondition(text.frame.height >= text.layoutManager!.usedRect(for: text.textContainer!).maxY)
    precondition(text.selectedRange().location == 3)
    let decorated = RichTextDocument(
        bodyFingerprint: RichTextDocument.fingerprint(body),
        spans: [RichTextSpan(location: 0, length: 3, bold: true)])
    text.loadBody(body, richText: decorated)
    let snapshot = text.richTextSnapshot()
    let snapshots = text.snapshotPassCount
    for _ in 0..<100 { precondition(text.richTextSnapshot() == snapshot) }
    precondition(text.snapshotPassCount == snapshots, "Unchanged snapshots must not rescan the document")
    text.setSelectedRange(NSRange(location: 0, length: 0))
    text.insertText("新", replacementRange: text.selectedRange())
    let changed = text.richTextSnapshot()
    precondition(text.snapshotPassCount == snapshots + 1 && changed?.valid(for: text.string) == true)
    text.undoManager?.undo()
    precondition(text.richTextSnapshot()?.valid(for: text.string) == true)
    for separator in ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"] {
        let candidate = "普通文字" + separator + "/h2"
        precondition(
            EditorCommand.trigger(
                in: candidate as NSString,
                selection: NSRange(location: (candidate as NSString).length, length: 0))?.1 == "h2")
    }
    let hugeLine = NSString(string: String(repeating: "a", count: 100_000))
    precondition(
        EditorCommand.trigger(in: hugeLine, selection: NSRange(location: hugeLine.length, length: 0)) == nil)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "PromptShelf-performance-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PromptStore(directory: root)
    try store.change { $0.prompts = [Prompt(title: "性能", body: body, group: "")] }
    let generation = store.generation
    let saved = try Data(contentsOf: store.file)
    let backup = try Data(contentsOf: store.backup)
    for _ in 0..<100 { try store.change { _ in } }
    precondition(store.generation == generation)
    let savedAfter = try Data(contentsOf: store.file)
    let backupAfter = try Data(contentsOf: store.backup)
    precondition(savedAfter == saved)
    precondition(backupAfter == backup)
    try store.change { $0.prompts[0].title = "  性能  " }
    precondition(store.generation == generation, "Normalized no-op must not persist or notify")
    try store.change { $0.prompts[0].title = "变化" }
    precondition(store.generation == generation + 1)
    precondition(PromptStore(directory: root).library.prompts[0].title == "变化")
    let beforeCorruption = store.library
    try Data("invalid disk data".utf8).write(to: store.file)
    do {
        try store.change { $0.prompts[0].title = "不可覆盖损坏文件" }
        preconditionFailure("Cached disk validation must still detect external corruption")
    } catch {}
    precondition(store.library == beforeCorruption)
    let large = PromptStore(directory: root.appendingPathComponent("large"))
    let sample = String(repeating: "中文 English 😀 保留空格\n", count: 40)
    try large.change {
        $0.prompts = (0..<2000).map { Prompt(title: "条目\($0)", body: sample, group: "") }
    }
    var saveTimes: [Int] = []
    for index in 0..<5 {
        let start = ProcessInfo.processInfo.systemUptime
        try large.change { $0.prompts[0].title = "保存\(index)" }
        saveTimes.append(Int((ProcessInfo.processInfo.systemUptime - start) * 1000))
    }
    precondition(PromptStore(directory: large.root).library == large.library)
    print("PASS: 2000-entry synchronous saves \(saveTimes) ms; exact reopen preserved (CPU/disk time)")
    text.extentTimer?.invalidate()
    print(
        "PASS: 80 long-document input/resize submissions in \(burstMS) ms with zero forced full layouts; settled extent, snapshot cache/invalidation/undo, bounded slash lookup and no-op persistence"
    )
}
