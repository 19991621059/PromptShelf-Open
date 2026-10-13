import AppKit
import WebKit

// Shared catalog keeps settings, persisted selection and the floating handle consistent.
enum PetCatalog {
    static let styles = [
        ("classic", "原始图标"), ("round", "奶油圆团"), ("cloud", "金黄云团"),
        ("heart", "蜜桃心团"), ("sprout", "薄荷芽团"), ("cat", "雾蓝猫团"),
    ]
    static let files = [
        "round": "01-cream-round", "cloud": "02-golden-cloud", "heart": "03-peach-heart",
        "sprout": "04-mint-sprout", "cat": "05-misty-cat",
    ]
    static let colors = [
        "round": "#F1DFC1", "cloud": "#F5CA52", "heart": "#F3A9B9",
        "sprout": "#A7D7C4", "cat": "#9EBED4",
    ]
    static func normalize(_ style: String) -> String {
        if style == "bear" { return "round" }
        if style == "bunny" { return "heart" }
        return styles.contains(where: { $0.0 == style }) ? style : "classic"
    }
    static var directory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("DotAvatars", isDirectory: true)
    }
}

private final class PetReadyBridge: NSObject, WKScriptMessageHandler {
    weak var owner: PlushPetView?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.body as? Bool == true { owner?.showAnimation() }
    }
}

// Native hit testing stays with the handle/button; WebKit only draws the bundled 3D scene.
final class PlushPetView: NSView, WKNavigationDelegate {
    let style: String
    private let fallback = NSImageView()
    private var web: WKWebView?
    private var observers: [NSObjectProtocol] = []
    private var retried = false
    private var ready = false
    private var lastVisibility: Bool?
    private var lastMotion: Bool?
    var animationEnabled = true { didSet { updateVisibility() } }
    init(style: String) {
        self.style = PetCatalog.normalize(style)
        super.init(frame: .zero)
        fallback.imageScaling = .scaleProportionallyUpOrDown
        if let directory = PetCatalog.directory, let file = PetCatalog.files[self.style] {
            fallback.image = NSImage(contentsOf: directory.appendingPathComponent(file + ".png"))
        }
        fallback.frame = bounds
        fallback.autoresizingMask = [.width, .height]
        addSubview(fallback)
        for name in [
            NSWindow.didUpdateNotification, NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
        ] {
            let center =
                name == NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
                ? NSWorkspace.shared.notificationCenter : NotificationCenter.default
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.updateVisibility()
                })
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateVisibility()
    }
    override func viewDidHide() {
        super.viewDidHide()
        updateVisibility()
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateVisibility()
    }
    private func updateVisibility() {
        let visible =
            animationEnabled && !isHiddenOrHasHiddenAncestor && window?.isVisible == true
            && window?.isMiniaturized != true
        if animationEnabled && !isHiddenOrHasHiddenAncestor && window != nil && web == nil { loadRenderer() }
        let motion = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard web != nil, visible != lastVisibility || motion != lastMotion else { return }
        lastVisibility = visible
        lastMotion = motion
        web?.evaluateJavaScript(
            "window.PromptShelfAvatar?.setMotion(\(motion));window.PromptShelfAvatar?.setVisible(\(visible));",
            completionHandler: nil)
    }
    private func loadRenderer() {
        guard let directory = PetCatalog.directory else { return }
        let file = directory.appendingPathComponent("renderer.html")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let bridge = PetReadyBridge()
        bridge.owner = self
        config.userContentController.add(bridge, name: "avatarReady")
        let color = PetCatalog.colors[style] ?? "#F1DFC1"
        let settings =
            "window.__avatarErrors=[];window.addEventListener('error',e=>window.__avatarErrors.push(e.message));window.addEventListener('unhandledrejection',e=>window.__avatarErrors.push(String(e.reason)));window.DOT_VIEW={shape:'\(style)',color:'\(color)',material:'plush',style:'minimal',gender:'male',yaw:0,motion:\(!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)};"
        config.userContentController.addUserScript(
            WKUserScript(source: settings, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: bounds, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.autoresizingMask = [.width, .height]
        view.navigationDelegate = self
        // Keep the canvas compositable: alpha zero can suspend WebKit animation frames.
        // The bundled PNG stays above it until the first real 3D frame is ready.
        view.alphaValue = 1
        addSubview(view, positioned: .below, relativeTo: fallback)
        web = view
        view.loadFileURL(file, allowingReadAccessTo: file)
    }
    fileprivate func showAnimation() {
        ready = true
        web?.alphaValue = 1
        fallback.isHidden = true
        updateVisibility()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastVisibility = nil
        updateVisibility()
    }
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let requested = navigationAction.request.url
        let expected = PetCatalog.directory?.appendingPathComponent("renderer.html")
        let allowed =
            requested?.absoluteString == "about:blank"
            || (requested?.isFileURL == true
                && requested?.standardizedFileURL.path == expected?.standardizedFileURL.path)
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        fallback.isHidden = false
        webView.alphaValue = 0
        guard !retried else { return }
        retried = true
        webView.reload()
    }
}

final class PetChoiceButton: NSButton {
    var selected = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(selected ? "已选择" : "未选择")
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        if selected {
            Palette.hover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
            Palette.ink.withAlphaComponent(0.5).setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            border.lineWidth = 1
            border.stroke()
        }
    }
}

final class PetPicker: FlippedView {
    var selected: String { didSet { updateSelection() } }
    var changed: ((String) -> Void)?
    var animationEnabled = false {
        didSet {
            for button in subviews {
                (button.subviews.first as? PlushPetView)?.animationEnabled = animationEnabled
            }
        }
    }
    init(selected: String) {
        self.selected = PetCatalog.normalize(selected)
        super.init(frame: .zero)
        for (index, style) in PetCatalog.styles.enumerated() {
            let button = PetChoiceButton(title: "", target: self, action: #selector(choose(_:)))
            button.tag = index
            button.isBordered = false
            button.setAccessibilityLabel("选择\(style.1)")
            addSubview(button)
            let preview: NSView
            if style.0 == "classic" {
                let handle = HandleView(frame: .zero)
                handle.interactive = false
                preview = handle
            } else {
                let pet = PlushPetView(style: style.0)
                pet.animationEnabled = false
                preview = pet
            }
            button.addSubview(preview)
        }
        updateSelection()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func choose(_ sender: NSButton) {
        selected = PetCatalog.styles[sender.tag].0
        changed?(selected)
    }
    private func updateSelection() {
        let normalized = PetCatalog.normalize(selected)
        for (i, button) in subviews.enumerated() {
            (button as? PetChoiceButton)?.selected = PetCatalog.styles[i].0 == normalized
        }
    }
    override func layout() {
        super.layout()
        let width = min(52, bounds.width / 6)
        for (i, view) in subviews.enumerated() {
            view.frame = NSRect(x: CGFloat(i) * width, y: 0, width: width - 4, height: 52)
            view.subviews.first?.frame = NSRect(x: (width - 4 - 38) / 2, y: 7, width: 38, height: 38)
        }
    }
}
