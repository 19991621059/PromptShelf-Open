import AppKit
import ServiceManagement

final class ControlSettingsView: FormPage, NSTextFieldDelegate {
    unowned let host: AppDelegate
    let theme = NSPopUpButton()
    let pets = PetPicker(selected: "classic")
    let pin = NSButton(checkboxWithTitle: "固定展开", target: nil, action: nil)
    let launch = NSButton(checkboxWithTitle: "登录电脑后自动启动", target: nil, action: nil)
    let openPanel = NSButton(checkboxWithTitle: "启动时打开控制面板", target: nil, action: nil)
    let widthField = NSTextField(), heightField = NSTextField()
    let advanced = NSButton(checkboxWithTitle: "调整尺寸和位置", target: nil, action: nil)
    let sizeControls: FormControls
    let reset: NSButton
    let shortcut = ShortcutRecorder()
    let issue: NSTextField
    var changed: (() -> Void)?
    let preferences: UserDefaults
    init(host: AppDelegate, preferences: UserDefaults = OpenEnvironment.preferences) {
        self.host = host
        self.preferences = preferences
        sizeControls = FormControls(
            [widthField, NSTextField(labelWithString: "×"), heightField, NSTextField(labelWithString: "pt")],
            widths: [76, 14, 76, 24])
        reset = NSButton(title: "恢复默认位置与尺寸", target: nil, action: nil)
        issue = NSTextField(wrappingLabelWithString: "")
        super.init(title: "通用设置")
        theme.addItems(withTitles: ["浅色", "深色", "跟随系统"])
        theme.target = self
        theme.action = #selector(changeTheme)
        theme.setAccessibilityLabel("外观")
        row("外观", theme, width: 154)
        launch.target = self
        launch.action = #selector(changeLaunch)
        row("启动", launch)
        openPanel.target = self
        openPanel.action = #selector(changeOpenPanel)
        row("", openPanel)
        shortcut.recorded = { [weak self] spec in self?.changeShortcut(spec) }
        row("打开面板快捷键", shortcut, width: 190)
        section("悬浮窗")
        pets.changed = { [weak self] style in
            guard let self else { return }
            self.preferences.set(style, forKey: "PromptShelfOpenPet")
            self.host.render()
        }
        row("悬浮伙伴", pets, height: 60, width: 312)
        pin.target = self
        pin.action = #selector(changePin)
        row("显示方式", pin, width: 180)
        let expand = button("展开") { [weak host] in host?.expand() }
        let collapse = button("收起") { [weak host] in host?.collapse() }
        row("当前窗口", FormControls([expand, collapse], widths: [70, 70]))
        advanced.target = self
        advanced.action = #selector(toggleAdvanced)
        row("高级设置", advanced)
        for field in [widthField, heightField] {
            field.font = .systemFont(ofSize: 12)
            field.alignment = .right
            field.delegate = self
            field.target = self
            field.action = #selector(changeSize)
        }
        widthField.setAccessibilityLabel("悬浮窗宽度")
        heightField.setAccessibilityLabel("悬浮窗高度")
        row("尺寸", sizeControls)
        reset.font = .systemFont(ofSize: 12)
        reset.bezelStyle = .rounded
        reset.target = self
        reset.action = #selector(resetFloatingWindow)
        row("位置", reset, width: 190)
        issue.font = .systemFont(ofSize: 11)
        issue.tag = 1
        addSubview(issue)
        rows.append(Row(label: nil, control: issue, height: 32, preferredWidth: 0))
        refresh()
        toggleAdvanced()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var contentHeight: CGFloat {
        super.contentHeight - (advanced.state == .on ? 0 : 72) - (issue.stringValue.isEmpty ? 32 : 0)
    }
    override func layout() {
        super.layout()
        issue.isHidden = issue.stringValue.isEmpty
        if advanced.state != .on {
            sizeControls.isHidden = true
            reset.isHidden = true
            for row in rows where row.control === sizeControls || row.control === reset {
                row.label?.isHidden = true
            }
            issue.frame.origin.y -= 72
        } else {
            sizeControls.isHidden = false
            reset.isHidden = false
            for row in rows where row.control === sizeControls || row.control === reset {
                row.label?.isHidden = false
            }
        }
    }
    func refresh() {
        let library = host.store.library
        pets.selected = PetCatalog.normalize(preferences.string(forKey: "PromptShelfOpenPet") ?? "classic")
        theme.selectItem(at: ["light", "dark", "system"].firstIndex(of: library.theme) ?? 0)
        pin.state = library.pinned == true ? .on : .off
        if widthField.currentEditor() == nil { widthField.integerValue = Int(library.panelWidth ?? 352) }
        if heightField.currentEditor() == nil { heightField.integerValue = Int(library.panelHeight ?? 260) }
        openPanel.state =
            preferences.object(forKey: "openControlPanelOnLaunch") as? Bool == false ? .off : .on
        let service = SMAppService.mainApp
        launch.state = service.status == .enabled || service.status == .requiresApproval ? .on : .off
        shortcut.spec = host.hotKey?.spec
        colors()
        needsLayout = true
    }
    private func update(_ change: (inout Library) -> Void) {
        guard host.finishEditing() else { return }
        do {
            try host.store.change(change)
            host.render()
            refresh()
            changed?()
        } catch {
            issue.stringValue = error.localizedDescription
            refresh()
            changed?()
        }
    }


    @objc func changeTheme() {
        let value = ["light", "dark", "system"][theme.indexOfSelectedItem]
        update { $0.theme = value }
    }
    @objc func changePin() {
        let fixed = pin.state == .on
        update { $0.pinned = fixed }
    }
    @objc func changeOpenPanel() {
        preferences.set(openPanel.state == .on, forKey: "openControlPanelOnLaunch")
    }
    @objc func changeLaunch() {
        do {
            if launch.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            issue.stringValue =
                SMAppService.mainApp.status == .requiresApproval ? "请在系统设置的登录项中允许 PromptShelf-Open 启动。" : ""
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { issue.stringValue = "开机启动设置失败：\(error.localizedDescription)" }
        refresh()
        changed?()
    }
    func changeShortcut(_ spec: ShortcutSpec?) {
        do {
            try host.hotKey?.set(spec)
            issue.stringValue = ""
        } catch { issue.stringValue = "这个快捷键不可用，请换一个组合。" }
        refresh()
        changed?()
    }
    @objc func toggleAdvanced() {
        needsLayout = true
        changed?()
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === widthField
            || notification.object as? NSTextField === heightField
        {
            changeSize()
        }
    }
    @objc func changeSize() {
        let width = widthField.doubleValue
        let height = heightField.doubleValue
        guard width.isFinite, height.isFinite, width >= 312, height >= 140 else {
            issue.stringValue = "宽度至少 312 pt，高度至少 140 pt。"
            needsLayout = true
            changed?()
            return
        }
        let w = min(1000, min(width, host.screen.visibleFrame.width - 8))
        let h = min(1600, min(height, host.screen.visibleFrame.height - 12))
        issue.stringValue = ""
        update {
            $0.panelWidth = w
            $0.panelHeight = h
        }
    }
    @objc func resetFloatingWindow() {
        host.liveAnchor = nil
        host.liveWidth = nil
        host.liveHeight = nil
        update {
            $0.panelWidth = nil
            $0.panelHeight = nil
            $0.positionX = nil
            $0.positionY = nil
            $0.dockEdge = "left"
            $0.topRatio = 0.32
        }
    }
}
