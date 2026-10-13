import AppKit

@MainActor
func runRichTextChecks() throws {
    let body = "# 旧提示词\n**保留字面标记** 😀\n```python\n旧代码\n```\n"
    let legacy = Prompt(title: "旧数据", body: body, group: "常用")
    let encoded = try JSONEncoder().encode(legacy)
    let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    precondition(object["richText"] == nil)
    let oldDecoded = try JSONDecoder().decode(Prompt.self, from: encoded)
    precondition(oldDecoded == legacy)
    let editor = GuidedTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    editor.loadBody(body, richText: nil)
    precondition(
        editor.string == body && editor.richTextSnapshot() == nil,
        "Legacy text is not reinterpreted or rewritten")
    for badStyle: Any in [
        "corrupt", ["version": 99], ["version": 1, "bodyFingerprint": "stale", "spans": []],
    ] {
        var corrupted = object
        corrupted["richText"] = badStyle
        let recovered = try JSONDecoder().decode(
            Prompt.self, from: JSONSerialization.data(withJSONObject: corrupted))
        precondition(recovered.body == body && recovered.richText == nil)
    }
    let emoji = (body as NSString).range(of: "😀")
    let split = RichTextDocument(
        bodyFingerprint: RichTextDocument.fingerprint(body),
        spans: [RichTextSpan(location: emoji.location + 1, length: 1, bold: true)])
    precondition(!split.valid(for: body))
    let rich = RichTextDocument(
        bodyFingerprint: RichTextDocument.fingerprint(body),
        spans: [RichTextSpan(location: 0, length: 7, heading: 1)])
    editor.loadBody(body, richText: rich)
    precondition(editor.richTextSnapshot() == rich && editor.string == body)
    var decorated = legacy
    decorated.richText = rich

    // Splitting an actual styled paragraph must switch to body/code continuation
    // immediately, and undo must restore both the text and its previous styles.
    let draft = InlineEditor(prompt: decorated, selectedGroup: nil)
    let window = ShelfPanel(
        contentRect: NSRect(x: 100, y: 100, width: 420, height: 320),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = draft
    defer {
        window.contentView = nil
        window.close()
    }
    let input = draft.bodyField
    input.loadBody(
        "标题后半段",
        richText: RichTextDocument(
            bodyFingerprint: RichTextDocument.fingerprint("标题后半段"),
            spans: [RichTextSpan(location: 0, length: 5, heading: 1)]))
    window.makeFirstResponder(input)
    input.setSelectedRange(NSRange(location: 2, length: 0))
    input.typingAttributes = input.semanticTypingAttributes(at: 1)
    let beforeSplit = input.richTextSnapshot()
    input.insertNewline(nil)
    precondition(
        input.string == "标题\n后半段"
            && input.textStorage!.attribute(.promptHeading, at: 3, effectiveRange: nil) == nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    input.undoManager?.undo()
    precondition(input.string == "标题后半段" && input.richTextSnapshot() == beforeSplit)
    input.undoManager?.redo()
    precondition(input.string == "标题\n后半段")
    input.undoManager?.removeAllActions()
    input.loadBody("code", richText: nil)
    input.selectAll(nil)
    input.applyCommand(EditorCommand.all[3])
    input.setSelectedRange(NSRange(location: 2, length: 0))
    input.typingAttributes = input.semanticTypingAttributes(at: 1)
    input.insertNewline(nil)
    precondition(input.string == "co\nde")
    precondition(
        (input.textStorage!.attribute(.paragraphStyle, at: 3, effectiveRange: nil) as! NSParagraphStyle)
            .paragraphSpacingBefore == 0)
    precondition(input.richTextSnapshot()!.spans.allSatisfy { $0.codeLanguage == "" })
    let longBody = (0..<2400).map { "第\($0)行 中文长文 😀 abcdefghijklmnop" }.joined(separator: "\n")
    editor.loadBody(longBody, richText: nil)
    editor.setSelectedRange((longBody as NSString).range(of: "第2399行"))
    let start = ProcessInfo.processInfo.systemUptime
    editor.applyCommand(EditorCommand.all[1])
    let snapshot = editor.richTextSnapshot()!
    precondition(snapshot.valid(for: longBody) && editor.string == longBody)
    let reopened = GuidedTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
    reopened.loadBody(longBody, richText: snapshot)
    reopened.layoutManager!.ensureLayout(for: reopened.textContainer!)
    let location = (longBody as NSString).range(of: "第2399行").location
    precondition(
        (reopened.textStorage!.attribute(.font, at: location, effectiveRange: nil) as! NSFont).pointSize == 20
    )
    reopened.setSelectedRange(NSRange(location: location + 2, length: 0))
    reopened.setMarkedText(
        "pin", selectedRange: NSRange(location: 3, length: 0), replacementRange: reopened.selectedRange())
    let composing = reopened.string
    reopened.applyCommand(EditorCommand.all[2])
    precondition(reopened.hasMarkedText() && reopened.string == composing)
    reopened.insertText("拼音", replacementRange: reopened.markedRange())
    reopened.unmarkText()
    precondition(reopened.richTextSnapshot()!.valid(for: reopened.string))
    let milliseconds = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
    print(
        "PASS: legacy literal Markdown untouched; malformed/stale styles recover text; UTF-16 emoji guards; native rich 2400-line style/reopen/marked-text API in \(milliseconds) ms"
    )
}
