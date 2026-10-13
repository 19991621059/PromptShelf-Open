import AppKit
import Carbon

struct ShortcutSpec: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String
    static func from(_ event: NSEvent) -> ShortcutSpec? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty,
            let characters = event.charactersIgnoringModifiers, !characters.isEmpty
        else { return nil }
        let key = event.keyCode == 49 ? "空格" : characters.uppercased()
        guard key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        var modifiers: UInt32 = 0
        var label = ""
        if flags.contains(.control) {
            modifiers |= UInt32(controlKey)
            label += "⌃"
        }
        if flags.contains(.option) {
            modifiers |= UInt32(optionKey)
            label += "⌥"
        }
        if flags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
            label += "⇧"
        }
        if flags.contains(.command) {
            modifiers |= UInt32(cmdKey)
            label += "⌘"
        }
        return ShortcutSpec(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label + key)
    }
}

final class ShortcutRecorder: NSButton {
    var spec: ShortcutSpec? { didSet { if !recording { title = spec?.label ?? "点击录制快捷键" } } }
    var recorded: ((ShortcutSpec?) -> Void)?
    var recording = false
    private var monitor: Any?
    override var acceptsFirstResponder: Bool { true }
    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        font = .systemFont(ofSize: 12)
        title = "点击录制快捷键"
        target = self
        action = #selector(beginRecording)
        setAccessibilityLabel("打开控制面板的全局快捷键")
        toolTip = "点击后按下快捷键；按删除键清除，Escape 取消。"
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func beginRecording() {
        recording = true
        title = "按下快捷键…"
        window?.makeFirstResponder(self)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording, event.window === self.window else { return event }
            self.keyDown(with: event)
            return nil
        }
    }
    override func keyDown(with event: NSEvent) {
        guard recording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            stop()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            stop()
            recorded?(nil)
            return
        }
        guard let next = ShortcutSpec.from(event) else {
            NSSound.beep()
            return
        }
        stop()
        recorded?(next)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func resignFirstResponder() -> Bool {
        stop()
        return super.resignFirstResponder()
    }
    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        recording = false
        title = spec?.label ?? "点击录制快捷键"
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stop() }
        super.viewWillMove(toWindow: newWindow)
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

final class HotKeyController {
    var spec: ShortcutSpec?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let preferences: UserDefaults
    let pressed: () -> Void
    init(preferences: UserDefaults = OpenEnvironment.preferences, pressed: @escaping () -> Void) {
        self.preferences = preferences
        self.pressed = pressed
        var type = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                let controller = Unmanaged<HotKeyController>.fromOpaque(context).takeUnretainedValue()
                controller.pressed()
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if let data = preferences.data(forKey: "controlPanelShortcut"),
            let saved = try? JSONDecoder().decode(ShortcutSpec.self, from: data)
        {
            try? set(saved)
        }
    }
    func set(_ next: ShortcutSpec?) throws {
        if next == spec { return }
        var registered: EventHotKeyRef?
        if let next {
            let result = RegisterEventHotKey(
                next.keyCode, next.modifiers, EventHotKeyID(signature: 0x5053_4846, id: 1),
                GetApplicationEventTarget(), 0, &registered)
            guard result == noErr else { throw StoreError.invalid("快捷键已被占用") }
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = registered
        spec = next
        if let next {
            preferences.set(try JSONEncoder().encode(next), forKey: "controlPanelShortcut")
        } else {
            preferences.removeObject(forKey: "controlPanelShortcut")
        }
    }
    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
