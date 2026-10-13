import AppKit

enum WorkflowUI {
    static let secondary = NSColor(name: "OpenSecondaryText") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(calibratedWhite: 0.72, alpha: 1) : NSColor(calibratedWhite: 0.34, alpha: 1)
    }
    static let success = NSColor(name: "OpenSuccessText") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(calibratedRed: 0.5, green: 0.9, blue: 0.6, alpha: 1) : NSColor(calibratedRed: 0.08, green: 0.38, blue: 0.19, alpha: 1)
    }
    static let error = NSColor(name: "OpenErrorText") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(calibratedRed: 1, green: 0.6, blue: 0.6, alpha: 1) : NSColor(calibratedRed: 0.7, green: 0.1, blue: 0.1, alpha: 1)
    }
    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: text)
        view.font = .systemFont(ofSize: size, weight: weight)
        view.textColor = .labelColor
        return view
    }
    static func button(_ text: String, target: AnyObject, action: Selector, symbol: String? = nil) -> NSButton {
        let button = NSButton(title: text, target: target, action: action)
        button.bezelStyle = .rounded
        button.setAccessibilityLabel(text)
        if let symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); button.imagePosition = .imageLeading }
        return button
    }
    static func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.spacing = spacing
        stack.distribution = .fill
        return stack
    }
    static func embed(_ view: NSView, in parent: NSView, inset: CGFloat = 0) {
        view.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }
    static func scroll(text: NSTextView, editable: Bool) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        text.isEditable = editable
        text.isSelectable = true
        text.isRichText = false
        text.allowsUndo = editable
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        text.font = .systemFont(ofSize: 13)
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        scroll.documentView = text
        return scroll
    }
    static func table(_ table: NSTableView, label: String) -> NSScrollView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.style = .sourceList
        table.setAccessibilityLabel(label)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = table
        return scroll
    }
    static func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
}

@MainActor
final class ModelSettingsWindowController: NSWindowController, NSWindowDelegate {
    let workspace: WorkflowWorkspace
    let provider = NSPopUpButton()
    let address = NSTextField()
    let model = NSTextField()
    let key = NSSecureTextField()
    let tokens = NSTextField()
    let timeout = NSTextField()
    let installed = NSPopUpButton()
    let status = WorkflowUI.label("")
    let deleteKey = NSButton(checkboxWithTitle: "删除此地址已保存的密钥", target: nil, action: nil)
    let noThinking = NSButton(checkboxWithTitle: "兼容 API：请求关闭思考（服务需支持）", target: nil, action: nil)
    var fetch: NSButton!, test: NSButton!, save: NSButton!
    private var task: Task<Void, Never>?
    init(workspace: WorkflowWorkspace) {
        self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "模型设置 · PromptShelf-Open"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        provider.addItems(withTitles: ModelProvider.allCases.map(\.title))
        provider.selectItem(at: ModelProvider.allCases.firstIndex(of: workspace.configuration.provider)!)
        provider.target = self; provider.action = #selector(changeProvider)
        provider.setAccessibilityLabel("模型服务类型")
        address.stringValue = workspace.configuration.baseURL; address.setAccessibilityLabel("API 根地址")
        model.stringValue = workspace.configuration.model; model.setAccessibilityLabel("模型名称")
        key.placeholderString = "留空保留已存密钥；Ollama 通常无需填写"; key.setAccessibilityLabel("API Key")
        tokens.integerValue = workspace.configuration.maxOutputTokens; tokens.setAccessibilityLabel("最大输出 token")
        timeout.doubleValue = workspace.configuration.timeout; timeout.setAccessibilityLabel("请求超时秒数")
        noThinking.state = workspace.configuration.reasoningEffort == "none" ? .on : .off
        fetch = WorkflowUI.button("获取本机模型", target: self, action: #selector(fetchModels), symbol: "arrow.clockwise")
        test = WorkflowUI.button("测试连接", target: self, action: #selector(testConnection), symbol: "network")
        save = WorkflowUI.button("保存设置", target: self, action: #selector(saveSettings))
        save.keyEquivalent = "\r"
        installed.target = self; installed.action = #selector(selectInstalled)
        installed.setAccessibilityLabel("已安装的 Ollama 模型")
        installed.addItem(withTitle: "先获取本机模型")
        installed.isEnabled = false
        let modelTools = WorkflowUI.stack([installed, fetch], vertical: false)
        let grid = NSGridView(views: [
            [WorkflowUI.label("服务类型"), provider], [WorkflowUI.label("API 根地址"), address],
            [WorkflowUI.label("模型名称"), model], [WorkflowUI.label("本机模型"), modelTools],
            [WorkflowUI.label("API Key"), key], [WorkflowUI.label("输出上限"), tokens],
            [WorkflowUI.label("超时（秒）"), timeout]
        ])
        grid.rowSpacing = 14; grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        let help = WorkflowUI.label("本地模型在这台 Mac 处理；远程 API 会接收你选择的材料。", size: 12)
        help.textColor = WorkflowUI.secondary
        let buttons = WorkflowUI.stack([test, save], vertical: false)
        let content = WorkflowUI.stack([help, grid, noThinking, deleteKey, status, NSView(), buttons], spacing: 18)
        WorkflowUI.embed(content, in: window.contentView!, inset: 26)
        for view in [help, grid, status] { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        address.widthAnchor.constraint(greaterThanOrEqualToConstant: 410).isActive = true
        changeProvider()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func present() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func windowWillClose(_ notification: Notification) { task?.cancel() }
    @objc func changeProvider() {
        fetch.isEnabled = provider.indexOfSelectedItem == 0 && task == nil
        if provider.indexOfSelectedItem == 1 && address.stringValue == "http://127.0.0.1:11434" {
            address.stringValue = ""; address.placeholderString = "https://你的服务地址/v1"
        } else if provider.indexOfSelectedItem == 0 && address.stringValue.isEmpty { address.stringValue = "http://127.0.0.1:11434" }
    }
    func configuration() -> ModelConfiguration {
        ModelConfiguration(provider: ModelProvider.allCases[provider.indexOfSelectedItem], baseURL: address.stringValue,
            model: model.stringValue, maxOutputTokens: tokens.integerValue, timeout: timeout.doubleValue,
            reasoningEffort: noThinking.state == .on ? "none" : nil)
    }
    private func perform(_ operation: @escaping () async throws -> String) {
        guard task == nil else { return }
        status.stringValue = "正在连接模型…"; status.textColor = WorkflowUI.secondary
        test.isEnabled = false; save.isEnabled = false; fetch.isEnabled = false
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil; self.test.isEnabled = true; self.save.isEnabled = true; self.changeProvider() }
            do { self.status.stringValue = try await operation(); self.status.textColor = WorkflowUI.success }
            catch { self.status.stringValue = error.localizedDescription; self.status.textColor = WorkflowUI.error }
        }
    }
    @objc func fetchModels() {
        let config = configuration()
        perform { [weak self] in
            guard let self else { return "" }
            let models = try await ModelClient(configuration: config).models()
            self.installed.removeAllItems(); self.installed.addItems(withTitles: models); self.installed.isEnabled = true
            if let index = models.firstIndex(of: self.model.stringValue) { self.installed.selectItem(at: index) }
            else { self.model.stringValue = models[0] }
            return "发现 \(models.count) 个本机模型"
        }
    }
    @objc func selectInstalled() { model.stringValue = installed.titleOfSelectedItem ?? "" }
    @objc func testConnection() {
        let config = configuration(); let enteredKey = key.stringValue
        perform { [weak self] in
            guard let self else { return "" }
            var testConfig = try config.validated(); testConfig.maxOutputTokens = 128
            let client = enteredKey.isEmpty ? try await self.workspace.client(for: testConfig) : ModelClient(configuration: testConfig, key: enteredKey)
            _ = try await client.generate(instruction: "只回复四个汉字：连接成功", input: "模型连接测试")
            return "连接成功"
        }
    }
    @objc func saveSettings() {
        let config = configuration(); let enteredKey = key.stringValue; let remove = deleteKey.state == .on
        perform { [weak self] in
            guard let self else { return "" }
            try await self.workspace.saveConfiguration(config, enteredKey: enteredKey, removeKey: remove)
            self.key.stringValue = ""; self.deleteKey.state = .off
            return "设置已保存，密钥不会写入配置文件。"
        }
    }
}
