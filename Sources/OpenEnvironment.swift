import AppKit

enum OpenEnvironment {
    static let bundleID = "io.github.promptshelf.open"
    static let sandbox = ProcessInfo.processInfo.environment["PROMPTSHELF_OPEN_DATA_DIR"]
    static let preferences: UserDefaults = {
        if let sandbox {
            return UserDefaults(suiteName: "io.github.promptshelf.open.qa." + RichTextDocument.fingerprint(sandbox))!
        }
        return .standard
    }()
    static var dataDirectory: URL {
        if let sandbox { return URL(fileURLWithPath: sandbox, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PromptShelf-Open", isDirectory: true)
    }
    static var pasteboard: NSPasteboard {
        if let sandbox {
            return NSPasteboard(name: NSPasteboard.Name("PromptShelfOpenQA." + RichTextDocument.fingerprint(sandbox)))
        }
        return .general
    }
}
