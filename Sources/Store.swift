import Foundation

final class PromptStore {
    static let didChange = Notification.Name("PromptShelfLibraryChanged")
    private(set) var library: Library
    private(set) var file: URL
    private(set) var backup: URL
    let root: URL
    private(set) var loadWarning: String?
    private(set) var writable = true
    private(set) var generation: UInt64 = 0
    private var validatedDiskData: Data?

    init(directory: URL? = nil) {
        root = directory ?? OpenEnvironment.dataDirectory
        file = root.appendingPathComponent("library.json")
        backup = root.appendingPathComponent("library.backup.json")
        library = Library()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) {
                do {
                    library = try Self.decode(Data(contentsOf: file))
                } catch {
                    if let recovered = try? Self.decode(Data(contentsOf: backup)) {
                        library = recovered
                        let preserved = root.appendingPathComponent(
                            "library.damaged-\(Int(Date().timeIntervalSince1970)).json")
                        try FileManager.default.copyItem(at: file, to: preserved)
                        try Self.encode(recovered).write(to: file, options: .atomic)
                        loadWarning = "已从备份恢复提示词。原文件已保留在数据文件夹。"
                    } else {
                        writable = false
                        library = Library(groups: [], prompts: [])
                        loadWarning = "无法读取提示词文件，原文件已保留。请通过菜单导入有效备份。"
                    }
                }
            } else {
                library.examplesRemoved = true
                try Self.encode(library).write(to: file, options: .atomic)
            }
            if writable && library.examplesRemoved != true {
                var next = library
                next.prompts.removeAll { prompt in
                    Library.retiredExamples.contains { $0.title == prompt.title && $0.body == prompt.body }
                }
                next.examplesRemoved = true
                if next.prompts != library.prompts {
                    let preserved = root.appendingPathComponent(
                        "library.before-example-removal-\(UUID().uuidString).json")
                    try Data(contentsOf: file).write(to: preserved, options: .atomic)
                }
                try Self.encode(next).write(to: file, options: .atomic)
                library = next
            }
        } catch {
            writable = false
            loadWarning = error.localizedDescription
        }
        if let data = try? Data(contentsOf: root.appendingPathComponent("device.json")),
            let settings = try? Self.decode(data)
        {
            let group = library.activeGroup
            library.copyDeviceSettings(from: settings)
            library.activeGroup = group
        }
    }

    static func decode(_ data: Data) throws -> Library {
        var library = try JSONDecoder().decode(Library.self, from: data)
        try library.normalize()
        return library
    }

    static func encode(_ library: Library) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(library)
    }

    func change(_ update: (inout Library) -> Void) throws {
        guard writable else { throw StoreError.invalid("数据文件尚未恢复，请先导入备份") }
        var next = library
        update(&next)
        guard next != library else { return }
        try next.normalize()
        guard next != library else { return }
        if FileManager.default.fileExists(atPath: file.path) {
            let previous = try Data(contentsOf: file)
            if previous != validatedDiskData { _ = try Self.decode(previous) }
            try previous.write(to: backup, options: .atomic)
        }
        let encoded = try Self.encode(next)
        try encoded.write(to: file, options: .atomic)
        validatedDiskData = encoded
        let oldSettings = Self.deviceSettings(library)
        library = next
        generation &+= 1
        let settings = Self.deviceSettings(next)
        if settings != oldSettings {
            try? Self.encode(settings).write(to: root.appendingPathComponent("device.json"), options: .atomic)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private static func deviceSettings(_ source: Library) -> Library {
        var settings = Library(groups: [], prompts: [])
        settings.copyDeviceSettings(from: source)
        settings.examplesRemoved = true
        return settings
    }

    func deleteGroupAndContents(_ group: String) throws {
        guard library.groups.contains(group) else { throw StoreError.invalid("分组不存在") }
        let safety = file.deletingLastPathComponent().appendingPathComponent(
            "library.before-group-delete-\(UUID().uuidString).json")
        try Self.encode(library).write(to: safety, options: .atomic)
        try change { library in
            library.groups.removeAll { $0 == group }
            library.prompts.removeAll { $0.group == group }
            if library.activeGroup == group { library.activeGroup = nil }
        }
    }

    func restore(_ data: Data) throws {
        validatedDiskData = nil
        var next = try Self.decode(data)
        next.copyDeviceSettings(from: library)
        next.activeGroup = library.activeGroup
        try next.normalize()
        if let existing = try? Data(contentsOf: file) {
            let safety = file.deletingLastPathComponent().appendingPathComponent(
                "library.before-import-\(UUID().uuidString).json")
            try existing.write(to: safety, options: .atomic)
        }
        try Self.encode(next).write(to: file, options: .atomic)
        library = next
        writable = true
        generation &+= 1
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

}
