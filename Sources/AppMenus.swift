import AppKit

extension AppDelegate {
    func buildMainMenu() {
        let main = NSMenu()
        let app = NSMenu()
        let quit = NSMenuItem(
            title: "退出 PromptShelf-Open", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let manage = NSMenuItem(title: "提示词库…", action: #selector(showManager), keyEquivalent: "m")
        manage.target = self
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        app.addItem(manage)
        let workflows = NSMenuItem(title: "AI 工作流…", action: #selector(showWorkflows), keyEquivalent: "1")
        workflows.target = self
        app.insertItem(workflows, at: 0)
        app.addItem(settings)
        app.addItem(quit)
        let appItem = NSMenuItem()
        appItem.submenu = app
        main.addItem(appItem)
        let edit = NSMenu(title: "编辑")
        for (name, action, key) in [
            ("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a"),
        ] {
            edit.addItem(withTitle: name, action: action, keyEquivalent: key)
        }
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.insertItem(redo, at: 1)
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func add(_ title: String, to menu: NSMenu, checked: Bool = false, action: @escaping () -> Void) {
        let handler = MenuAction(action)
        menuActions.append(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke), keyEquivalent: "")
        item.target = handler
        item.state = checked ? .on : .off
        menu.addItem(item)
    }

    func settingsMenu() -> NSMenu {
        let menu = NSMenu()
        add("AI 工作流…", to: menu) { [weak self] in self?.showWorkflows() }
        add("提示词库…", to: menu) { [weak self] in self?.showManager() }
        add("设置…", to: menu) { [weak self] in self?.showSettings() }
        add("固定展开", to: menu, checked: store.library.pinned == true) { [weak self] in self?.togglePin() }
        add(shelfBulk ? "完成批量管理" : "批量管理", to: menu) { [weak self] in self?.toggleShelfBulk() }
        add("新提示词…", to: menu) { [weak self] in self?.openEditor(nil) }
        let groups = NSMenu(title: "分组")
        add("新分组…", to: groups) { [weak self] in self?.newGroup() }
        for group in store.library.groups {
            let item = NSMenuItem(title: group, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            add("重命名…", to: sub) { [weak self] in self?.renameGroup(group) }
            add("只删除分组…", to: sub) { [weak self] in self?.deleteGroup(group) }
            add("删除分组及全部提示词…", to: sub) { [weak self] in self?.deleteGroupAndContents(group) }
            item.submenu = sub
            groups.addItem(item)
        }
        let groupItem = NSMenuItem(title: "管理分组", action: nil, keyEquivalent: "")
        groupItem.submenu = groups
        menu.addItem(groupItem)
        menu.addItem(.separator())
        let themes = NSMenu()
        for (title, value) in [("浅色", "light"), ("深色", "dark"), ("跟随系统", "system")] {
            add(title, to: themes, checked: store.library.theme == value) { [weak self] in
                self?.mutate { $0.theme = value }
            }
        }
        let themeItem = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        themeItem.submenu = themes
        menu.addItem(themeItem)
        if NSScreen.screens.count > 1 {
            let screens = NSMenu()
            for (index, screen) in NSScreen.screens.enumerated() {
                add(
                    "\(index + 1) · \(screen.localizedName)", to: screens,
                    checked: displayID(screen) == displayID(self.screen)
                ) { [weak self] in self?.mutate { $0.screenID = self?.displayID(screen) } }
            }
            let item = NSMenuItem(title: "所在屏幕", action: nil, keyEquivalent: "")
            item.submenu = screens
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add("导出全部提示词…", to: menu) { [weak self] in self?.exportLibrary() }
        add("导入提示词…", to: menu) { [weak self] in self?.importLibrary() }
        add("打开数据文件夹", to: menu) { [weak self] in
            if let self { NSWorkspace.shared.open(self.store.file.deletingLastPathComponent()) }
        }
        menu.addItem(.separator())
        add("收起", to: menu) { [weak self] in self?.collapse() }
        add("退出", to: menu) { NSApp.terminate(nil) }
        return menu
    }

    func rebuildStatusMenu() {
        guard statusItem != nil else { return }
        menuActions.removeAll()
        let menu = NSMenu()
        add("展开提示词", to: menu) { [weak self] in self?.expand() }
        let settings = settingsMenu()
        while let item = settings.items.first {
            settings.removeItem(item)
            menu.addItem(item)
        }
        statusItem.menu = menu
    }
}
