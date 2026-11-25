// Headroom: a native window around the local Headroom server.
// It starts scan.py (bundled in Resources) in app mode, waits for the address it
// prints, and shows that page. Quitting the app stops the server.
import Cocoa
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var server: Process?
    var buffer = Data()

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 860)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Headroom"
        window.minSize = NSSize(width: 420, height: 480)
        window.center()
        window.setFrameAutosaveName("HeadroomMain")
        web = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        window.contentView = web
        show("Starting Headroom…")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startServer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ note: Notification) { server?.terminate() }

    func show(_ message: String) {
        let safe = message.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        web.loadHTMLString("""
        <meta charset="utf-8"><style>
        :root{color-scheme:light dark}
        body{font:15px -apple-system,sans-serif;display:grid;place-items:center;height:100vh;margin:0;
             background:#e8ebf0;color:#4a5160;text-align:center;padding:0 40px}
        @media (prefers-color-scheme:dark){body{background:#0d0f12;color:#b6bcc8}}
        </style><p>\(safe)</p>
        """, baseURL: nil)
    }

    func startServer() {
        let fm = FileManager.default
        guard let resources = Bundle.main.resourcePath else { return }
        let pythons = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        guard let python = pythons.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            show("Headroom needs Python 3. Install the Xcode Command Line Tools (xcode-select --install) and open Headroom again.")
            return
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Headroom", isDirectory: true)
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [resources + "/scan.py", "app", "--no-open", "--stay", "--port", "0",
                       "--out", support.appendingPathComponent("scan.json").path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self = self, !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                self.buffer.append(chunk)
                guard let text = String(data: self.buffer, encoding: .utf8),
                      let mark = text.range(of: "HEADROOM_URL "),
                      let end = text[mark.upperBound...].firstIndex(of: "\n"),
                      let url = URL(string: String(text[mark.upperBound..<end]).trimmingCharacters(in: .whitespaces))
                else { return }
                handle.readabilityHandler = nil
                self.web.load(URLRequest(url: url))
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.show("Headroom's helper stopped. Quit and open Headroom again.") }
        }
        do { try p.run(); server = p } catch {
            show("Headroom could not start its helper: \(error.localizedDescription)")
        }
    }

    // Keep the window on Headroom's own page; anything else opens in the browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "about" || url.host == "127.0.0.1" { decisionHandler(.allow); return }
        if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }

    func buildMenu() {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(), menu = NSMenu(title: title)
            items.forEach { menu.addItem($0) }
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "") -> NSMenuItem {
            NSMenuItem(title: title, action: action, keyEquivalent: key)
        }
        add("Headroom", [item("About Headroom", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
                         .separator(),
                         item("Hide Headroom", #selector(NSApplication.hide(_:)), "h"),
                         item("Quit Headroom", #selector(NSApplication.terminate(_:)), "q")])
        add("Edit", [item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
                     item("Paste", #selector(NSText.paste(_:)), "v"),
                     item("Select All", #selector(NSText.selectAll(_:)), "a")])
        add("View", [item("Reload", #selector(reload(_:)), "r")])
        add("Window", [item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
                       item("Zoom", #selector(NSWindow.performZoom(_:)))])
        NSApp.mainMenu = main
    }

    @objc func reload(_ sender: Any?) { web.reload() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
