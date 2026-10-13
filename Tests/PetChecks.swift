import AppKit
import WebKit

private enum PetCheckError: Error { case failed(String) }

@MainActor
func runPetChecks() throws {
    precondition(PetCatalog.styles.count == 6)
    precondition(PetCatalog.normalize("bear") == "round" && PetCatalog.normalize("bunny") == "heart")
    precondition(PetCatalog.normalize("invalid") == "classic")
    let picker = PetPicker(selected: "classic")
    picker.frame = NSRect(x: 0, y: 0, width: 312, height: 60)
    picker.layoutSubtreeIfNeeded()
    var changed = ""
    picker.changed = { changed = $0 }
    for (index, style) in PetCatalog.styles.enumerated() {
        let button = picker.subviews[index] as! PetChoiceButton
        precondition(
            button.title.isEmpty && button.subviews.first?.frame.size == NSSize(width: 38, height: 38))
        button.performClick(nil)
        precondition(changed == style.0 && picker.selected == style.0 && button.selected)
    }
    guard let directory = PetCatalog.directory else { throw PetCheckError.failed("Missing avatar directory") }
    for style in PetCatalog.styles.dropFirst() {
        guard let file = PetCatalog.files[style.0],
            NSImage(contentsOf: directory.appendingPathComponent(file + ".png")) != nil
        else {
            throw PetCheckError.failed("Missing companion fallback: \(style.0)")
        }
        let pet = PlushPetView(style: style.0)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 38, height: 38), styleMask: [], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pet
        defer {
            window.contentView = nil
            window.close()
        }
        guard let nativeCanvas = pet.subviews.compactMap({ $0 as? WKWebView }).first else {
            throw PetCheckError.failed("Native companion canvas was not mounted: \(style.0)")
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let settings =
            "window.__avatarErrors=[];window.addEventListener('error',e=>window.__avatarErrors.push(e.message));window.DOT_VIEW={shape:'\(style.0)',color:'\(PetCatalog.colors[style.0]!)',material:'plush',style:'minimal',gender:'male',motion:true};"
        config.userContentController.addUserScript(
            WKUserScript(source: settings, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 38, height: 38), configuration: config)
        let url = directory.appendingPathComponent("renderer.html")
        view.loadFileURL(url, allowingReadAccessTo: url)
        let deadline = Date().addingTimeInterval(15)
        var result = ""
        while Date() < deadline {
            var done = false
            view.evaluateJavaScript(
                "(()=>{const m=window.__dot?.main;if(!m)return JSON.stringify({errors:window.__avatarErrors});m.place(1.18,true);m.render();return m.renderer.info.render.calls>0?'rendered':JSON.stringify({calls:m.renderer.info.render.calls});})()"
            ) { value, _ in
                result = value as? String ?? "not loaded"
                done = true
            }
            let callbackDeadline = Date().addingTimeInterval(2)
            while !done && Date() < callbackDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            if result == "rendered" { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        view.stopLoading()
        var nativeDone = false
        var nativeRendered = false
        var nativeError = ""
        nativeCanvas.evaluateJavaScript(
            "(()=>{const m=window.__dot?.main;if(!m)return JSON.stringify({url:location.href,state:document.readyState,config:window.DOT_VIEW,errors:window.__avatarErrors});m.place(1.18,true);m.render();window.webkit.messageHandlers.avatarReady.postMessage(true);return m.renderer.info.render.calls>0;})()"
        ) { value, error in
            nativeError = "value=\(String(describing: value)) error=\(String(describing: error))"
            nativeRendered = value as? Bool == true
            nativeDone = true
        }
        let nativeDeadline = Date().addingTimeInterval(3)
        while !nativeDone && Date() < nativeDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        precondition(pet.subviews.compactMap { $0 as? NSImageView }.allSatisfy { $0.isHidden })
        guard nativeRendered else {
            throw PetCheckError.failed("Native companion renderer failed: \(style.0) \(nativeError)")
        }
        guard result == "rendered" else {
            throw PetCheckError.failed("3D render failed for \(style.0): \(result)")
        }
    }
    print(
        "PASS: six icon-only choices, legacy selection migration, 38pt previews, bundled fallback images and actual offline WebGL rendering and native first-frame handoff for all five companions"
    )
}
