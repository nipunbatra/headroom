// Headroom: a native Mac window, menus and menu bar item around the bundled scanner.
//   Headroom                              the app
//   Headroom --scan [--root <folder>]     measure from a terminal and write scan.json, no window
//   HEADROOM_OUT=<file> Headroom          keep scan.json and the logs in that file's folder (tests)
//   HEADROOM_SNAPSHOT=<dir> Headroom      save a PNG of every page in light and dark, then quit
//   HEADROOM_SELFTEST=<ids> Headroom      clean the given fixture ids through the real code path, then quit
import AppKit
import SwiftUI

@main
@MainActor
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--scan") { exit(CLI.scan(CommandLine.arguments)) }
        HeadroomApp.main()
    }
}

@MainActor
struct HeadroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    @AppStorage("menuBar") private var menuBar = true

    var body: some Scene {
        Window("Headroom", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 560)
        }
        .defaultSize(width: 1220, height: 800)
        .windowToolbarStyle(.unified)
        .commands { HeadroomCommands(model: model) }

        MenuBarExtra(isInserted: $menuBar) {
            MenuBarView().environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor struct HeadroomCommands: Commands {
    let model: AppModel

    var body: some Commands {
        SidebarCommands()
        ToolbarCommands()
        InspectorCommands()
        CommandGroup(replacing: .newItem) { FileItems(model: model) }
        CommandGroup(after: .sidebar) { ViewItems(model: model) }
        CommandMenu("Clean") { CleanItems(model: model) }
    }
}

@MainActor private struct FileItems: View {
    let model: AppModel

    var body: some View {
        let paths = model.highlighted.compactMap(\.reveal)
        Button("Scan Disk") { model.rescan() }
            .keyboardShortcut("r")
            .disabled(model.scanning)
        Button("Stop Scan") { model.cancelScan() }
            .keyboardShortcut(".")
            .disabled(!model.scanning)
        Divider()
        Button("Show in Finder") { model.reveal(paths) }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(paths.isEmpty)
        Button("Quick Look") { if let p = paths.first { model.preview(p) } }
            .keyboardShortcut("y")
            .disabled(paths.isEmpty)
        Button(paths.count > 1 ? "Copy Paths" : "Copy Path") { model.copyPaths(paths) }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(paths.isEmpty)
    }
}

@MainActor private struct ViewItems: View {
    let model: AppModel

    var body: some View {
        Divider()
        ForEach(Array(Page.allCases.enumerated()), id: \.element) { i, page in
            Button(page.title) { model.go(page) }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
        }
        Divider()
        Button("Enclosing Folder") { if let p = model.mapNode?.parent { model.zoom(p.path) } }
            .keyboardShortcut(.upArrow)
            .disabled(model.page != .map || model.mapNode?.parent == nil)
        Divider()
    }
}

@MainActor private struct CleanItems: View {
    let model: AppModel

    var body: some View {
        let ids = model.highlighted.compactMap(\.cleanID).filter { model.candidates[$0] != nil }
        Button("Clean Safe Items…") { model.reviewSafe() }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(model.scan == nil || model.safeItems.isEmpty)
        Divider()
        Button(!ids.isEmpty && ids.allSatisfy(model.inPlan) ? "Remove from Cleanup List" : "Add to Cleanup List") { model.togglePlan(ids) }
            .keyboardShortcut("d")
            .disabled(ids.isEmpty)
        Button("Clean Selected Items…") { model.review(ids) }
            .keyboardShortcut(.delete)
            .disabled(ids.isEmpty)
        Divider()
        Button("Review and Clean…") { model.review(model.plan) }
            .keyboardShortcut(.return)
            .disabled(model.plan.isEmpty)
        Button("Clear Cleanup List") { model.clearPlan() }
            .disabled(model.plan.isEmpty)
        Divider()
        Button("Show Action Log") { model.reveal([model.engine.actionLogPath]) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["menuBar": true, "menuBarText": true, "keepRunning": true,
                                                  "warnBelowGB": 10, "autoScan": "never"])
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let env = ProcessInfo.processInfo.environment
        Task { @MainActor in
            await AppModel.shared.start()
            if let ids = env["HEADROOM_SELFTEST"], !ids.isEmpty {
                exit(await DevTools.selfTest(ids.split(separator: ",").map(String.init), hard: env["HEADROOM_SELFTEST_HARD"] == "1"))
            }
            if let dir = env["HEADROOM_SNAPSHOT"], !dir.isEmpty {
                await DevTools.snapshot(to: dir, only: env["HEADROOM_SNAPSHOT_PAGES"].map { Set($0.split(separator: ",").map(String.init)) })
            }
        }
    }

    /// With the menu bar item on, closing the window leaves Headroom running there.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let d = UserDefaults.standard
        return !(d.bool(forKey: "menuBar") && d.bool(forKey: "keepRunning"))
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Scan Disk", action: #selector(scan), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Clean Safe Items…", action: #selector(cleanSafe), keyEquivalent: "").target = self
        return menu
    }

    @objc private func scan() { AppModel.shared.rescan() }

    @objc private func cleanSafe() {
        NSApp.activate(ignoringOtherApps: true)
        AppModel.shared.reviewSafe()
    }
}

/// Checks an agent or a developer can run from the command line.
@MainActor
enum DevTools {
    static func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

    /// Cleans throwaway fixtures through the same model code the Clean button uses.
    static func selfTest(_ ids: [String], hard: Bool) async -> Int32 {
        guard ids.allSatisfy({ $0.contains("_fixture") || $0.contains("HeadroomFixture") }) else {
            log("SELFTEST refused: only fixture ids are allowed")
            return 2
        }
        let model = AppModel.shared
        for id in ids where model.candidates[id] == nil {
            model.candidates[id] = Candidate(id: id, title: id, bytes: 0, paths: [], safety: "review")
        }
        model.review(ids)
        guard let session = model.session else {
            log("SELFTEST no session")
            return 1
        }
        session.hard = hard
        model.refreshDry()
        try? await Task.sleep(for: .seconds(2))
        for it in session.items { log("DRY \(it.id): \(session.dry[it.id] ?? "") \(session.blocked[it.id].map { "BLOCKED " + $0 } ?? "")") }
        await model.runClean()
        for it in session.items { log("RESULT \(it.id): \(String(describing: session.marks[it.id]))") }
        log("SELFTEST done=\(session.done) failed=\(session.failed) trashed=\(session.trashed) cleared=\(ids.filter(model.cleared.contains).count)")
        return session.failed == 0 && session.done == ids.count ? 0 : 1
    }

    static func snapshot(to dir: String, only: Set<String>?) async {
        let model = AppModel.shared
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for _ in 0..<600 where model.scan == nil || model.scanning { try? await Task.sleep(for: .seconds(0.5)) }
        try? await Task.sleep(for: .seconds(1.5))
        func wanted(_ name: String) -> Bool { only?.contains(name) ?? true }
        for mode in ["light", "dark"] {
            NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
            for page in Page.allCases where wanted(page.rawValue) {
                model.go(page)
                try? await Task.sleep(for: .seconds(0.9))
                capture("\(dir)/\(page.rawValue)-\(mode).png")
            }
            if wanted("open") {
                model.go(.apps)
                if let first = model.flatten(model.appSections().first?.rows ?? [], prefix: "apps/").first(where: \.expandable) {
                    model.toggleExpanded(first.id, browse: first.row.browse)
                    try? await Task.sleep(for: .seconds(0.9))
                    capture("\(dir)/apps-open-\(mode).png")
                    model.toggleExpanded(first.id, browse: nil)
                }
                model.go(.cleanup)
                if let first = model.flatten(model.cleanupSections().last?.rows ?? [], prefix: "review/").first(where: \.expandable) {
                    model.toggleExpanded(first.id, browse: first.row.browse)
                    try? await Task.sleep(for: .seconds(2.5))
                    capture("\(dir)/cleanup-open-\(mode).png")
                    model.toggleExpanded(first.id, browse: nil)
                }
            }
            if wanted("sheet") {
                model.go(.cleanup)
                let before = model.plan
                model.setPlan(Array(model.safeItems.prefix(5).map(\.id)), true)
                try? await Task.sleep(for: .seconds(0.9))
                capture("\(dir)/list-\(mode).png")
                model.review(model.plan)
                try? await Task.sleep(for: .seconds(2))
                capture("\(dir)/sheet-\(mode).png", sheet: true)
                model.closeSession()
                model.clearPlan()
                model.setPlan(before, true)
                model.showInspector = false
                try? await Task.sleep(for: .seconds(0.6))
            }
        }
        if only?.contains("scanning") == true {      // a rescan behind the current page, then stopped
            NSApp.appearance = NSAppearance(named: .aqua)
            model.go(.overview)
            model.rescan()
            try? await Task.sleep(for: .seconds(4))
            capture("\(dir)/scanning.png")
            model.cancelScan()
            for _ in 0..<120 where model.scanning { try? await Task.sleep(for: .seconds(0.25)) }
            log("SNAPSHOT scan stopped, still showing \(model.scan?.stats.files ?? 0) files from the earlier scan")
        }
        if wanted("extras") {
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                extra(MenuBarView().environment(model), "\(dir)/menubar-\(mode).png")
                extra(SettingsView().environment(model).frame(height: 420), "\(dir)/settings-\(mode).png")
            }
        }
        log("SNAPSHOT done \(dir)")
        NSApp.terminate(nil)
    }

    /// Views that normally live outside the main window (the menu bar panel, Settings), drawn on their own.
    private static func extra<V: View>(_ view: V, _ path: String) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.appearance = NSApp.appearance
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            log("SNAPSHOT \(path)")
        }
    }

    /// Captures the real window so materials look as they do on screen. Without Screen
    /// Recording permission it falls back to drawing the view tree, which leaves the sidebar blank.
    private static func capture(_ path: String, sheet: Bool = false) {
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        guard let main = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) else {
            log("SNAPSHOT no window")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        main.makeKeyAndOrderFront(nil)
        let window = sheet ? (main.attachedSheet ?? main) : main
        try? FileManager.default.removeItem(atPath: path)
        for _ in 1...2 {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            shot.standardError = FileHandle.nullDevice
            try? shot.run()
            shot.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) {
                log("SNAPSHOT \(path)")
                return
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        // An app may always capture its own windows, so this still shows the real composited window.
        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
           let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), image.width > 10 {
            try? data.write(to: URL(fileURLWithPath: path))
            log("SNAPSHOT \(path) (own window)")
            return
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            log("SNAPSHOT \(path) (fallback: no Screen Recording permission)")
        }
    }
}
