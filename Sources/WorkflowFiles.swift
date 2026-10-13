import Foundation
import PDFKit
import CryptoKit

enum WorkflowFiles {
    static let textExtensions: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "json", "yaml", "yml", "log", "html", "htm", "xml", "swift", "js", "ts", "py", "css"]
    static func read(_ urls: [URL], note: String) throws -> String {
        guard urls.count <= 20 else { throw WorkflowError.invalid("一次最多选择 20 个文件。") }
        var parts: [String] = []
        if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("补充说明：\n" + note) }
        var characters = note.count
        for url in urls {
            try Task.checkCancellation()
            let attrs = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard attrs.isRegularFile == true, let size = attrs.fileSize, size <= 20 * 1024 * 1024 else {
                throw WorkflowError.invalid("「\(url.lastPathComponent)」不是普通文件，或超过 20 MB。")
            }
            let body: String
            if url.pathExtension.lowercased() == "pdf" {
                guard let document = PDFDocument(url: url), !document.isLocked else { throw WorkflowError.invalid("无法读取 PDF「\(url.lastPathComponent)」，文件可能加密。") }
                guard document.pageCount <= 300 else { throw WorkflowError.invalid("PDF 最多支持 300 页，请先拆分文件。") }
                var pages: [String] = []
                var count = 0
                for index in 0..<document.pageCount {
                    try Task.checkCancellation()
                    let text = document.page(at: index)?.string ?? ""
                    count += text.count
                    guard count + characters <= 120_000 else { throw WorkflowError.invalid("材料超过 12 万字，请拆分后执行。") }
                    pages.append("[第 \(index + 1) 页]\n" + text)
                }
                guard pages.contains(where: { $0.count > 12 }) else { throw WorkflowError.invalid("PDF 没有可提取文字。扫描件请先进行 OCR。") }
                body = pages.joined(separator: "\n\n")
            } else {
                guard textExtensions.contains(url.pathExtension.lowercased()) else { throw WorkflowError.invalid("暂不支持「\(url.lastPathComponent)」。请选择文本、Markdown、CSV、JSON 或文字 PDF。") }
                let data = try Data(contentsOf: url)
                guard let value = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw WorkflowError.invalid("「\(url.lastPathComponent)」不是 UTF-8 / UTF-16 文本。") }
                body = value
            }
            characters += body.count
            guard characters <= 120_000 else { throw WorkflowError.invalid("材料合计超过 12 万字，请减少文件或拆分任务。") }
            parts.append("文件：\(url.lastPathComponent)\n" + body)
        }
        let result = parts.joined(separator: "\n\n---\n\n")
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkflowError.invalid("请先选择文件，或填写补充说明。") }
        return result
    }
    static func input(for step: WorkflowStep, source: String, previous: String) -> String {
        switch step.input {
        case .files: return source
        case .previous: return previous
        case .filesAndPrevious: return "原始材料：\n" + source + "\n\n上一步输出：\n" + previous
        }
    }
}

struct FileWriteProposal {
    let target: URL
    let original: Data?
    let replacement: Data
    let preview: String
    init(target: URL, content: String) throws {
        guard ["md", "txt", "markdown"].contains(target.pathExtension.lowercased()) else { throw WorkflowError.invalid("结果只能保存为 .md 或 .txt 文件。") }
        let standardized = target.standardizedFileURL
        let exists = FileManager.default.fileExists(atPath: standardized.path)
        if exists {
            let values = try standardized.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? Int.max) <= 4 * 1024 * 1024 else {
                throw WorkflowError.invalid("目标文件不是可预览的普通文本文件，请另选保存位置。")
            }
        }
        self.target = standardized.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(standardized.lastPathComponent)
        original = exists ? try Data(contentsOf: self.target) : nil
        replacement = Data(content.utf8)
        if let original {
            guard let text = String(data: original, encoding: .utf8) else { throw WorkflowError.invalid("目标文件不是 UTF-8 文本，请另选保存位置。") }
            preview = "原内容：\n" + text + "\n\n──────── 替换为 ────────\n\n" + content
        } else { preview = "新建文件内容：\n\n" + content }
    }
    func commit(approved: Bool) throws {
        guard approved else { throw WorkflowError.invalid("尚未确认写入。") }
        guard target.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(target.lastPathComponent) == target else {
            throw WorkflowError.invalid("目标目录已改变，请重新预览。")
        }
        let exists = FileManager.default.fileExists(atPath: target.path)
        if exists {
            let values = try target.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw WorkflowError.invalid("目标文件类型已改变，请重新预览。") }
        }
        let current = exists ? try Data(contentsOf: target) : nil
        guard current == original else { throw WorkflowError.invalid("目标文件在预览后已改变。没有写入，请重新预览确认。") }
        try replacement.write(to: target, options: .atomic)
    }
}
