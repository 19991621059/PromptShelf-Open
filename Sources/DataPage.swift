import AppKit

final class DataPage: FormPage {
    unowned let host: AppDelegate
    let localStatus = NSTextField(labelWithString: "")
    let issue = NSTextField(wrappingLabelWithString: "")
    var localRestore: NSButton!
    init(host: AppDelegate) {
        self.host = host
        super.init(title: "数据与备份")
        let load = button("导入…") { [weak host] in host?.importLibrary() }
        let export = button("导出…") { [weak host] in host?.exportLibrary() }
        let folder = button("打开数据文件夹") { [weak host] in
            if let host { NSWorkspace.shared.open(host.store.root) }
        }
        row("本机提示词", FormControls([localStatus, load, export, folder], widths: [96, 72, 72, 138]))
        localRestore = button("恢复上次本机备份…") { [weak self] in self?.restoreLocal() }
        row("本机备份", localRestore, width: 184)
        row("数据位置", NSTextField(wrappingLabelWithString: "提示词、工作流和执行记录保存在本机。模型密钥单独保存在 macOS 钥匙串。"), height: 56)
        row("", issue, height: 40)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    func refresh() {
        localStatus.stringValue = "\(host.store.library.prompts.count) 条"
        localRestore.isEnabled = FileManager.default.fileExists(atPath: host.store.backup.path)
        colors()
        needsLayout = true
    }
    func restoreLocal() {
        do {
            guard host.manager?.flush() ?? true, host.finishEditing() else { return }
            let data = try Data(contentsOf: host.store.backup)
            let library = try PromptStore.decode(data)
            let alert = NSAlert()
            alert.messageText = "恢复上次本机备份？"
            alert.informativeText = "备份包含 \(library.prompts.count) 条提示词。当前内容会先另存。"
            alert.addButton(withTitle: "恢复")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try host.store.restore(data)
            issue.stringValue = "本机备份已恢复"
        } catch { issue.stringValue = error.localizedDescription }
        refresh()
    }
}
