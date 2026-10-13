import AppKit
import CryptoKit

struct RichTextSpan: Codable, Equatable {
    var location: Int
    var length: Int
    var heading: Int? = nil
    var bold: Bool? = nil
    var codeLanguage: String? = nil
    var codeID: String? = nil
}

struct RichTextDocument: Codable, Equatable {
    var version = 1
    var bodyFingerprint: String
    var spans: [RichTextSpan]
    static func fingerprint(_ body: String) -> String {
        SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func valid(for body: String) -> Bool {
        guard version == 1, bodyFingerprint == Self.fingerprint(body), spans.count <= 50_000 else {
            return false
        }
        let ns = body as NSString
        var end = 0
        for span in spans {
            guard span.location >= end, span.length > 0, span.location <= ns.length,
                span.length <= ns.length - span.location,
                span.heading == nil || [1, 2].contains(span.heading!),
                span.codeLanguage == nil || RichTextLanguage.values.contains(span.codeLanguage!),
                span.codeLanguage == nil || span.codeID.flatMap(UUID.init(uuidString:)) != nil
            else { return false }
            for boundary in [span.location, span.location + span.length]
            where boundary > 0 && boundary < ns.length {
                if (0xD800...0xDBFF).contains(ns.character(at: boundary - 1)),
                    (0xDC00...0xDFFF).contains(ns.character(at: boundary))
                {
                    return false
                }
            }
            end = span.location + span.length
        }
        return true
    }
}

enum RichTextLanguage {
    static let values = ["", "python", "javascript", "swift", "json", "bash"]
    static func name(_ value: String) -> String {
        switch value {
        case "python": return "Python"
        case "javascript": return "JavaScript"
        case "swift": return "Swift"
        case "json": return "JSON"
        case "bash": return "Shell"
        default: return "纯文本"
        }
    }
}

extension NSAttributedString.Key {
    static let promptHeading = NSAttributedString.Key("PromptShelf.heading")
    static let promptBold = NSAttributedString.Key("PromptShelf.bold")
    static let promptCode = NSAttributedString.Key("PromptShelf.codeLanguage")
    static let promptCodeID = NSAttributedString.Key("PromptShelf.codeID")
}

final class RichCodeLayoutManager: NSLayoutManager {
    func blockRect(_ range: NSRange, in container: NSTextContainer) -> NSRect {
        guard range.length > 0 else { return .zero }
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return .zero }
        let first = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        return NSRect(
            x: 3, y: max(0, first.minY - 3), width: max(0, container.size.width - 6),
            height: last.maxY - first.minY + 10)
    }
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first, glyphsToShow.length > 0 else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var seen = Set<String>()
        storage.enumerateAttribute(.promptCodeID, in: visible) { value, range, _ in
            guard let id = value as? String, seen.insert(id).inserted else { return }
            var full = NSRange()
            _ = storage.attribute(
                .promptCodeID, at: range.location, longestEffectiveRange: &full,
                in: NSRange(location: 0, length: storage.length))
            var rect = blockRect(full, in: container)
            rect.origin.x += origin.x
            rect.origin.y += origin.y
            (Palette.dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.95, alpha: 1)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            Palette.secondary.withAlphaComponent(0.14).setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).stroke()
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

final class CodeLanguageButton: NSPopUpButton {
    weak var editor: GuidedTextView?
    var blockID = ""
    init(editor: GuidedTextView, blockID: String) {
        self.editor = editor
        self.blockID = blockID
        super.init(frame: .zero, pullsDown: false)
        isBordered = false
        font = .systemFont(ofSize: 11, weight: .medium)
        addItems(withTitles: RichTextLanguage.values.map(RichTextLanguage.name))
        target = self
        action = #selector(changeLanguage)
        setAccessibilityLabel("代码块语言")
        toolTip = "选择代码语言；⌥Return 回到正文"
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func changeLanguage() {
        guard RichTextLanguage.values.indices.contains(indexOfSelectedItem) else { return }
        editor?.setCodeLanguage(RichTextLanguage.values[indexOfSelectedItem], blockID: blockID)
    }
}

extension GuidedTextView {
    var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        return [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: Palette.ink, .paragraphStyle: paragraph,
        ]
    }
    func loadBody(_ body: String, richText: RichTextDocument?) {
        richTextCacheValid = false
        dismissCommands()
        guard let storage = textStorage else { return }
        storage.setAttributedString(NSAttributedString(string: body, attributes: baseAttributes))
        isStructuredDocument = richText != nil
        if let document = richText, document.valid(for: body) {
            for span in document.spans {
                let range = NSRange(location: span.location, length: span.length)
                if let heading = span.heading {
                    storage.addAttribute(.promptHeading, value: heading, range: range)
                }
                if span.bold == true { storage.addAttribute(.promptBold, value: true, range: range) }
                if let language = span.codeLanguage, let id = span.codeID {
                    storage.addAttributes([.promptCode: language, .promptCodeID: id], range: range)
                }
            }
            refreshRichStyles(in: NSRange(location: 0, length: storage.length))
        }
        contentExtentNeedsUpdate = true
        typingAttributes = baseAttributes
        setSelectedRange(NSRange(location: 0, length: 0))
        needsDisplay = true
        needsLayout = true
    }
    func richTextSnapshot() -> RichTextDocument? {
        if richTextCacheValid { return cachedRichText }
        snapshotPassCount += 1
        richTextCacheValid = true
        cachedRichText = nil
        guard isStructuredDocument, let storage = textStorage else { return nil }
        var spans: [RichTextSpan] = []
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
            let heading = attrs[.promptHeading] as? Int
            let bold = (attrs[.promptBold] as? Bool) == true
            let language = attrs[.promptCode] as? String
            guard heading != nil || bold || language != nil else { return }
            var span = RichTextSpan(
                location: range.location, length: range.length,
                heading: heading, bold: bold ? true : nil,
                codeLanguage: language, codeID: attrs[.promptCodeID] as? String)
            if var previous = spans.last, previous.location + previous.length == span.location,
                previous.heading == span.heading, previous.bold == span.bold,
                previous.codeLanguage == span.codeLanguage, previous.codeID == span.codeID
            {
                previous.length += span.length
                spans[spans.count - 1] = previous
            } else {
                span.length = range.length
                spans.append(span)
            }
        }
        let document = RichTextDocument(bodyFingerprint: RichTextDocument.fingerprint(string), spans: spans)
        cachedRichText = document
        return document
    }
    func refreshRichStyles(in range: NSRange) {
        guard let storage = textStorage, range.length > 0 else { return }
        var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
        storage.enumerateAttributes(in: range) { attrs, run, _ in runs.append((run, attrs)) }
        storage.beginEditing()
        for (run, attrs) in runs {
            let heading = attrs[.promptHeading] as? Int
            let bold = (attrs[.promptBold] as? Bool) == true
            let code = attrs[.promptCode] as? String
            let size: CGFloat = code != nil ? 13 : heading == 1 ? 26 : heading == 2 ? 20 : 14
            let font: NSFont =
                code != nil
                ? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
                : .systemFont(ofSize: size, weight: heading != nil || bold ? .bold : .regular)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacing = heading != nil ? 10 : 4
            if code != nil {
                paragraph.headIndent = 12
                paragraph.firstLineHeadIndent = 12
                paragraph.tailIndent = -12
                paragraph.paragraphSpacing = 3
                if attrs[.promptCodeID] is String {
                    var block = NSRange()
                    _ = storage.attribute(
                        .promptCodeID, at: run.location, longestEffectiveRange: &block,
                        in: NSRange(location: 0, length: storage.length))
                    let firstParagraph = (storage.string as NSString).paragraphRange(
                        for: NSRange(location: block.location, length: 0))
                    // Runs can span multiple paragraphs; assign header spacing only
                    // to the first paragraph, not every line of a code block.
                    storage.addAttributes(
                        [.font: font, .foregroundColor: Palette.ink, .paragraphStyle: paragraph], range: run)
                    let first = NSIntersectionRange(run, firstParagraph)
                    if first.length > 0 {
                        let header = paragraph.mutableCopy() as! NSMutableParagraphStyle
                        header.paragraphSpacingBefore = 28
                        storage.addAttribute(.paragraphStyle, value: header, range: first)
                    }
                    continue
                }
            }
            storage.addAttributes(
                [.font: font, .foregroundColor: Palette.ink, .paragraphStyle: paragraph], range: run)
        }
        storage.endEditing()
        needsDisplay = true
        needsLayout = true
    }
    func restoreRichState(
        _ text: NSAttributedString, selection: NSRange,
        typing: [NSAttributedString.Key: Any], structured: Bool
    ) {
        guard let storage = textStorage else { return }
        let previous = NSAttributedString(attributedString: storage)
        let previousSelection = selectedRange()
        let previousTyping = typingAttributes
        let wasStructured = isStructuredDocument
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreRichState(
                previous, selection: previousSelection, typing: previousTyping, structured: wasStructured)
        }
        storage.setAttributedString(text)
        isStructuredDocument = structured
        setSelectedRange(selection)
        typingAttributes = typing
        didChangeText()
        needsLayout = true
    }
    func beginRichChange(_ title: String) {
        guard let storage = textStorage else { return }
        breakUndoCoalescing()
        let previous = NSAttributedString(attributedString: storage)
        let selection = selectedRange()
        let typing = typingAttributes
        let structured = isStructuredDocument
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreRichState(previous, selection: selection, typing: typing, structured: structured)
        }
        undoManager?.setActionName(title)
        isStructuredDocument = true
    }
    func semanticTypingAttributes(at location: Int) -> [NSAttributedString.Key: Any] {
        guard let storage = textStorage, storage.length > 0 else { return typingAttributes }
        return storage.attributes(at: min(max(0, location), storage.length - 1), effectiveRange: nil)
    }
    func setCodeLanguage(_ language: String, blockID: String) {
        guard !hasMarkedText(), RichTextLanguage.values.contains(language), let storage = textStorage else {
            return
        }
        var found: NSRange?
        storage.enumerateAttribute(.promptCodeID, in: NSRange(location: 0, length: storage.length)) {
            id, range, stop in
            if id as? String == blockID {
                found = range
                stop.pointee = true
            }
        }
        guard let range = found else { return }
        beginRichChange("代码语言")
        storage.addAttribute(.promptCode, value: language, range: range)
        refreshRichStyles(in: range)
        if (typingAttributes[.promptCodeID] as? String) == blockID {
            typingAttributes[.promptCode] = language
        }
        window?.makeFirstResponder(self)
        didChangeText()
        breakUndoCoalescing()
    }
    func layoutCodeControls() {
        guard let storage = textStorage, let manager = layoutManager as? RichCodeLayoutManager,
            let container = textContainer, storage.length > 0
        else {
            for button in codeLanguageButtons.values { button.removeFromSuperview() }
            codeLanguageButtons.removeAll()
            return
        }
        let glyphs = manager.glyphRange(forBoundingRect: visibleRect, in: container)
        let visible = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var active = Set<String>()
        storage.enumerateAttribute(.promptCodeID, in: visible) { id, run, _ in
            guard let id = id as? String, active.insert(id).inserted else { return }
            var full = NSRange()
            _ = storage.attribute(
                .promptCodeID, at: run.location, longestEffectiveRange: &full,
                in: NSRange(location: 0, length: storage.length))
            let firstGlyph = manager.glyphIndexForCharacter(at: full.location)
            let firstLine = manager.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
            let rect = NSRect(
                x: 3, y: max(0, firstLine.minY - 3), width: max(0, container.size.width - 6),
                height: firstLine.height
            ).offsetBy(
                dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            guard rect.minY >= visibleRect.minY - 24, rect.minY < visibleRect.maxY else {
                active.remove(id)
                return
            }
            let button = codeLanguageButtons[id] ?? CodeLanguageButton(editor: self, blockID: id)
            if button.superview == nil { addSubview(button) }
            codeLanguageButtons[id] = button
            let language =
                storage.attribute(.promptCode, at: run.location, effectiveRange: nil) as? String ?? ""
            let selectedIndex = RichTextLanguage.values.firstIndex(of: language) ?? 0
            if button.indexOfSelectedItem != selectedIndex { button.selectItem(at: selectedIndex) }
            button.contentTintColor = Palette.secondary
            let frame = NSRect(
                x: rect.minX + 8, y: rect.minY + 3, width: min(145, rect.width - 16), height: 22)
            if button.frame != frame { button.frame = frame }
        }
        for id in Array(codeLanguageButtons.keys) where !active.contains(id) {
            codeLanguageButtons.removeValue(forKey: id)?.removeFromSuperview()
        }
    }
}
