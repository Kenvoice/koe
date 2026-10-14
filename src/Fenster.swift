import AppKit
import WebKit

// Hauptfenster: die Oberfläche ist HTML (Resources/ui), die Brücke läuft über window.webkit.messageHandlers.koe.

final class KoeWebView: WKWebView {
    var dateienAbgelegt: ([URL]) -> Void = { _ in }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dateien(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dateien(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let d = dateien(sender)
        guard !d.isEmpty else { return super.performDragOperation(sender) }
        dateienAbgelegt(d)
        return true
    }

    private func dateien(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

final class Fenster: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    let fenster: NSWindow
    let web: KoeWebView
    var befehl: (String, [String: Any]) -> Void = { _, _ in }
    private var geladen = false
    private var ausstehend: [String] = []

    override init() {
        let inhalt = WKUserContentController()
        let konfig = WKWebViewConfiguration()
        konfig.userContentController = inhalt
        konfig.websiteDataStore = .nonPersistent()
        web = KoeWebView(frame: .zero, configuration: konfig)
        fenster = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        super.init()
        inhalt.add(self, name: "koe")
        web.navigationDelegate = self
        web.registerForDraggedTypes([.fileURL])
        fenster.title = "Koe"
        fenster.titlebarAppearsTransparent = true
        fenster.minSize = NSSize(width: 760, height: 560)
        fenster.contentView = web
        fenster.isReleasedWhenClosed = false
        fenster.delegate = self
        fenster.setFrameAutosaveName("KoeHauptfenster")
        if !fenster.setFrameUsingName("KoeHauptfenster") { fenster.center() }
        fenster.backgroundColor = NSColor(srgbRed: 0xF7 / 255.0, green: 0xF9 / 255.0, blue: 0xFC / 255.0, alpha: 1)
        fenster.appearance = NSAppearance(named: .aqua)  // Koe ist hell, auch im dunklen Modus
        let ui = Bundle.main.resourceURL!.appendingPathComponent("ui", isDirectory: true)
        web.loadFileURL(ui.appendingPathComponent("index.html"), allowingReadAccessTo: ui)
    }

    func zeigen() {
        NSApp.activate(ignoringOtherApps: true)
        fenster.makeKeyAndOrderFront(nil)
    }

    /// Ruft eine Funktion von window.koe auf. Vor dem Laden wird gepuffert.
    func senden(_ funktion: String, _ wert: Any) {
        guard let d = try? JSONSerialization.data(withJSONObject: wert),
              let json = String(data: d, encoding: .utf8) else { return }
        let js = "window.koe && window.koe.\(funktion) && window.koe.\(funktion)(\(json));"
        if geladen { web.evaluateJavaScript(js) } else { ausstehend.append(js) }
    }

    func userContentController(_ c: WKUserContentController, didReceive nachricht: WKScriptMessage) {
        guard let daten = nachricht.body as? [String: Any], let cmd = daten["cmd"] as? String else { return }
        befehl(cmd, daten)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        geladen = true
        for js in ausstehend { web.evaluateJavaScript(js) }
        ausstehend = []
    }

    // Links aus der Oberfläche nie im Fenster öffnen.
    func webView(_ webView: WKWebView, decidePolicyFor aktion: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if aktion.navigationType == .linkActivated, let url = aktion.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        fenster.orderOut(nil)
        return false
    }
}
