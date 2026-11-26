// Everything the windows show: the scan, what is ticked for cleaning, live free space.
import AppKit
import Observation
import SwiftUI
import UserNotifications

enum Page: String, CaseIterable, Identifiable {
    case overview, cleanup, changes, map, files, projects, downloads, apps, locations, activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .cleanup: return "Clean Up"
        case .changes: return "What Changed"
        case .map: return "Disk Map"
        case .files: return "Large Files"
        case .projects: return "Projects"
        case .downloads: return "Downloads"
        case .locations: return "Folders & Drives"
        case .activity: return "Cleanup History"
        case .apps: return "Applications"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.needle"
        case .cleanup: return "sparkles"
        case .changes: return "chart.line.uptrend.xyaxis"
        case .map: return "square.split.2x2"
        case .files: return "doc"
        case .projects: return "hammer"
        case .downloads: return "arrow.down.circle"
        case .locations: return "externaldrive"
        case .activity: return "clock.arrow.circlepath"
        case .apps: return "square.grid.2x2"
        }
    }

    static let main: [Page] = [.overview, .cleanup, .changes, .activity]
    static let explore: [Page] = [.locations, .map, .files, .projects, .downloads, .apps]
}

/// Something the helper can clean, addressed by id. The helper decides what the id means.
struct Candidate: Identifiable {
    let id: String
    var title: String
    var bytes: Int64
    var paths: [String]
    var cmd: String?
    var safety: String
    var perm = false
    var child = false
    var supportOptions: [AppInfo.Leftover] = []
    var selectedSupport: Set<String> { id.hasPrefix("app:") ? Set(paths.dropFirst()) : [] }
}

struct Totals {
    var safe: Int64 = 0
    var review: Int64 = 0
    var files: Int64 = 0
    var system: Int64 = 0
    var used: Int64 = 0
    var scanned: Int64 = 0
    var staleFound: [Found] = []
}

struct Browse {
    var loading = true
    var entries: [Listing.Entry] = []
    var rest: Rest?
    var error = ""
}

enum Phase: Equatable {
    case starting, ready
    case failed(String)
}

struct TagInfo {
    var label: String
    var rebuild: Bool
    var how: String
}

@MainActor @Observable final class CleanSession: Identifiable {
    enum Stage { case review, running, done }
    enum Mark: Equatable {
        case working
        case ok(String)
        case failed(String)
    }
    let id = UUID()
    var items: [Candidate]
    var dry: [String: String] = [:]
    var previews: [String: [ReviewedStep]] = [:]
    var previewRevision = 0
    var checkedHard: Bool?
    var ready: Bool { checkedHard == hard && dry.count + blocked.count == items.count }
    var blocked: [String: String] = [:]     // id -> why the helper refuses it
    var marks: [String: Mark] = [:]
    var hard = false
    var stage = Stage.review
    var current = 0
    var planned = 0
    var startFree: Int64 = 0
    var endFree: Int64 = 0
    var done = 0
    var failed = 0
    var trashed = 0
    var stopRequested = false

    init(items: [Candidate]) { self.items = items }
}

@MainActor @Observable final class AppModel {
    static let shared = AppModel()

    let engine: Engine
    let explorer: LocationExplorer
    var protectedPaths: [String] = []
    private var policyUnreadable = false
    var protectionError: String?
    func changeProtection(_ path: String, add: Bool) {
        guard session?.stage != .running else { return }
        do {
            protectedPaths = try ProtectedPaths(env: engine.env).change(path, add: add)
            protectionError = nil
            policyUnreadable = false
            refreshDry()
        } catch { protectionError = error.localizedDescription; policyUnreadable = (try? ProtectedPaths(env: engine.env).read()) == nil }
    }

    private let defaults: UserDefaults
    private var skippedPathsByRule: [String: [String]] = [:]
    var skippedRules: Set<String> { Set(skippedPathsByRule.keys) }

    init(engine: Engine = Engine(), defaults: UserDefaults = .standard) {
        self.engine = engine
        explorer = LocationExplorer(engine: engine, defaults: defaults)
        self.defaults = defaults
        do { protectedPaths = try ProtectedPaths(env: engine.env).read() } catch { protectionError = error.localizedDescription; policyUnreadable = true }
        skippedPathsByRule = defaults.dictionary(forKey: "quickCleanupSkippedRules") as? [String: [String]] ?? [:]
    }
    var phase = Phase.starting
    var scan: Scan?
    var now: Double = Date().timeIntervalSince1970
    var candidates: [String: Candidate] = [:]
    var nodes: [String: Node] = [:]
    var homeNode: Node?
    var totals = Totals()

    var page = Page.overview
    var search = ""
    var mapNode: Node?
    var group = "all"
    var kind = "all"
    var minimumFileSize = FileSizeFilter.any
    var modifiedBefore = FileAgeFilter.any
    var tag = "all"

    var plan: [String] = []
    var cleared: Set<String> = []
    var expanded: Set<String> = []
    var browse: [String: Browse] = [:]
    var highlighted: [Row] = []

    var free: Int64 = 0
    var total: Int64 = 0
    var purgeable: Int64 = 0
    var progress = "Starting"
    var scanFraction: Double = 0
    var scanning = false
    var scanError: String?
    var focus = ReviewFocus.all
    var sort = "size"
    var scanPath = ""
    var scanRate = 0
    var scanStarted = Date()
    var expectedFiles = 0
    private var scanProgress: ScanProgress?
    var history: [Sample] = []

    var session: CleanSession?
    var showInspector = false
    var quickLook: URL?
    var fullDiskAccess = false
    private var timer: Timer?

    static let safetyTitle = ["safe": "Safe to Clear", "review": "Review First", "keep": "Leave Alone"]
    static let groupNames = ["caches": "Caches", "dev": "Developer Tools", "ml": "Models and Datasets",
                             "containers": "Containers and VMs", "system": "System", "personal": "Personal Data"]
    static let tags: [String: TagInfo] = [
        "node_modules": TagInfo(label: "node_modules", rebuild: true, how: "npm install brings it back"),
        "rust-target": TagInfo(label: "Rust build output", rebuild: true, how: "cargo build brings it back"),
        "web-build": TagInfo(label: "Web build output", rebuild: true, how: "the next build brings it back"),
        "toolcache": TagInfo(label: "Tool cache", rebuild: true, how: "rebuilt on the next run"),
        "pods": TagInfo(label: "CocoaPods", rebuild: true, how: "pod install brings it back"),
        "venv": TagInfo(label: "Python environment", rebuild: false, how: "recreate from requirements or pyproject"),
        "notebook-checkpoints": TagInfo(label: "Notebook checkpoints", rebuild: false, how: "May contain an earlier notebook revision"),
        "ml-logs": TagInfo(label: "Experiment logs", rebuild: false, how: "runs, metrics and checkpoints; gone once deleted"),
        "git": TagInfo(label: "Git history", rebuild: false, how: "shrink with git gc --aggressive; never delete"),
    ]

    // MARK: - Start up

    private var started = false

    func start() async {
        guard !started else { return }
        started = true
        readVolume()
        checkAccess()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.tick() }
        }
        await load()
    }

    func load() async {
        guard engine.hasScan else {
            rescan()
            return
        }
        if let scan = await engine.loadScan() {
            install(scan)
            phase = .ready
            history = await engine.history(free: free, total: total)
        } else {
            phase = .failed("Unable to read the last scan. Scan again to replace it.")
        }
    }

    func install(_ snapshot: Scan) {
        var scan = snapshot
        // Stored reports predate rule changes. Apply current policy before offering any actions.
        let definitions = Dictionary(uniqueKeysWithValues: Report.allRules(engine.env).map { ($0.id, $0) })
        if let found = scan.found {
            scan.found = found.map { item in
                var item = item
                if item.tag == "toolcache", lastComponent(item.path) == ".ipynb_checkpoints" { item.tag = "notebook-checkpoints" }
                return item
            }
        }
        for i in scan.rules.indices {
            if let def = definitions[scan.rules[i].id] {
                scan.rules[i].safety = def.safety
                scan.rules[i].cmd = def.cmd
                scan.rules[i].why = def.why
                scan.rules[i].title = def.title
            } else if scan.rules[i].id == "pycache" {
                scan.rules[i].safety = "review"
                scan.rules[i].cmd = "@manual"
            }
        }
        let ticked = plan           // a fresh scan keeps the cleanup list, minus anything that is gone
        self.scan = scan
        now = scan.scannedAt
        nodes = [:]
        homeNode = nil
        candidates = [:]
        browse = [:]
        expanded = []
        highlighted = []
        func walk(_ n: Node, _ parent: Node?, _ path: String) {
            n.parent = parent
            n.path = path
            nodes[path] = n
            if n.h != nil { homeNode = n }
            for c in n.children { walk(c, n, c.h != nil ? "~" : (path == "/" ? "" : path) + "/" + c.n) }
        }
        walk(scan.tree, nil, scan.root.isEmpty ? "/" : scan.root)
        mapNode = homeNode ?? scan.tree

        func add(_ c: Candidate) { if candidates[c.id] == nil { candidates[c.id] = c } }
        for r in scan.rules {
            if r.pickable {
                add(Candidate(id: r.cleanID, title: r.title, bytes: r.returns, paths: r.paths, cmd: r.cmd,
                              safety: r.safety, perm: r.perm ?? false))
            }
            for it in r.items ?? [] where it.id.hasPrefix("hf") || AppModel.pickable(it.path ?? "") {
                add(Candidate(id: it.id, title: r.title + ": " + it.name, bytes: it.returns,
                              paths: it.id.hasPrefix("hforphans:") ? [] : [it.path].compactMap { $0 },
                              safety: r.safety, perm: r.perm ?? false, child: true))
            }
        }
        for f in scan.found ?? [] where f.tag != "git" && Self.pickableFile(f.path) {
            add(Candidate(id: "file:" + f.path, title: tagLabel(f.tag) + " in " + project(f), bytes: f.returns,
                          paths: [f.path], safety: foundSafety(f)))
        }
        for f in scan.bigFiles ?? [] where Self.pickableFile(f.path) {
            add(Candidate(id: "file:" + f.path, title: baseName(f.path), bytes: f.returns, paths: [f.path], safety: "review"))
        }
        for g in scan.dupes ?? [] {
            for f in g.files.dropFirst() where Self.pickableFile(f.path) {
                add(Candidate(id: "duplicate:" + f.path, title: baseName(f.path), bytes: f.frees ?? g.bytes, paths: [f.path], safety: "review"))
            }
            for f in g.files where Self.pickableFile(f.path) {
                add(Candidate(id: "file:" + f.path, title: baseName(f.path), bytes: f.frees ?? g.bytes, paths: [f.path], safety: "review"))
            }
        }
        for f in scan.downloads ?? [] {
            add(Candidate(id: "file:" + f.path, title: f.name, bytes: f.returns, paths: [f.path], safety: "review"))
        }
        for a in scan.apps ?? [] where AppModel.pickable(a.path) && a.bytes > 0 {
            add(Candidate(id: "app:" + a.path, title: a.name + " (app)", bytes: a.returns,
                          paths: [a.path], safety: "review", supportOptions: a.leftovers ?? []))
            for l in a.leftovers ?? [] where AppModel.pickable(l.path) {
                add(Candidate(id: "file:" + l.path, title: baseName(l.path), bytes: l.returns, paths: [l.path], safety: "review"))
            }
        }
        for (p, n) in nodes where Self.pickableFile(p) {
            add(Candidate(id: "file:" + p, title: n.n, bytes: n.returns, paths: [p], safety: "review"))
        }
        restoreState()
        if plan.isEmpty { plan = ticked.filter { candidates[$0] != nil } }
        compute()
    }

    static func pickableFile(_ p: String) -> Bool { pickable(p) && !Cleaner.insideInstalledApp(p) }

    /// Lexical eligibility for the UI. The cleaner also checks the live filesystem.
    static func pickable(_ p: String) -> Bool {
        let path = p.hasPrefix("~/") ? String(p.dropFirst()) : p
        guard isNormal(path), !(path.lowercased() + "/").contains("/.git/") else { return false }
        if !p.hasPrefix("~/") { return p.range(of: #"^/Applications/[^/\n]+\.app\z"#, options: .regularExpression) != nil }
        let seg = p.split(separator: "/", omittingEmptySubsequences: false)
        if seg.count > 1, seg[1].lowercased() == "library" { return seg.count >= 4 }
        return seg.count >= 3
    }

    // MARK: - Derived figures

    func days(_ ts: Double?) -> Double {
        guard let ts, ts > 0 else { return .infinity }
        return (now - ts) / 86400
    }

    func age(_ ts: Double?) -> String { ageText(ts, now: now) }
    func tagLabel(_ tag: String) -> String { AppModel.tags[tag]?.label ?? tag }
    func project(_ f: Found) -> String { baseName(dirName(f.path)) }
    func stale(_ f: Found) -> Bool { (f.projectMtime ?? 0) > 0 && days(f.projectMtime) > 90 }
    func foundSafety(_ f: Found) -> String { (AppModel.tags[f.tag]?.rebuild ?? false) && stale(f) ? "safe" : "review" }

    /// What is still left in a rule after the items cleaned from it since the scan.
    func left(_ r: Rule) -> Int64 {
        max(0, r.returns - (r.items ?? []).filter { cleared.contains($0.id) }.reduce(0) { $0 + $1.returns })
    }

    func compute() {
        guard let scan else { return }
        let rules = scan.rules.filter { !cleared.contains($0.cleanID) }
        func inside(_ p: String, _ safety: String?) -> Bool {
            scan.rules.contains { r in (safety == nil || r.safety == safety) && r.paths.contains { p.hasPrefix($0 + "/") } }
        }
        let found = (scan.found ?? []).filter { !cleared.contains("file:" + $0.path) }
        // Idle build folders count as safe wherever they sit, unless a safe rule already covers them.
        let stale = found.filter { foundSafety($0) == "safe" && $0.tag != "git" }
        var t = Totals()
        t.staleFound = stale.filter { !inside($0.path, "safe") }
        let staleInReview = stale.filter { inside($0.path, "review") }.reduce(0) { $0 + $1.returns }
        let reviewFound = found.filter { ["venv", "ml-logs", "notebook-checkpoints"].contains($0.tag) && foundSafety($0) != "safe" && !inside($0.path, nil) }
        t.safe = rules.filter { $0.safety == "safe" }.reduce(0) { $0 + left($1) } + t.staleFound.reduce(0) { $0 + $1.returns }
        t.review = max(0, rules.filter { $0.safety == "review" }.reduce(0) { $0 + left($1) } + reviewFound.reduce(0) { $0 + $1.returns } - staleInReview)
        let total = self.total > 0 ? self.total : scan.disk.total
        let free = self.total > 0 ? self.free : scan.disk.free
        t.used = total - free
        t.scanned = min(scan.disk.unique ?? scan.disk.scanned, t.used)
        t.system = max(0, t.used - t.scanned)
        t.files = max(0, t.scanned - t.safe - t.review)
        totals = t
    }

    var quickRules: [Candidate] {
        candidates.values.filter { $0.safety == "safe" && $0.id.hasPrefix("rule:") }
            .sorted { ($0.title, $0.id) < ($1.title, $1.id) }
    }

    func includeInQuickCleanup(_ id: String, _ include: Bool) {
        if include { skippedPathsByRule[id] = nil }
        else if let rule = quickRules.first(where: { $0.id == id }) { skippedPathsByRule[id] = rule.paths }
        defaults.set(skippedPathsByRule, forKey: "quickCleanupSkippedRules")
    }

    var safeItems: [Candidate] {
        let rules = quickRules
        let paths = rules.flatMap(\.paths)
        let skippedPaths = skippedPathsByRule.values.flatMap { $0 } + rules.filter { skippedRules.contains($0.id) }.flatMap(\.paths)
        let included = rules.filter { candidate in
            !skippedRules.contains(candidate.id) && !candidate.paths.contains { path in
                skippedPaths.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
            }
        }
        let projects = totals.staleFound.compactMap { candidates["file:" + $0.path] }.filter { candidate in
            !candidate.paths.contains { path in
                (paths + skippedPaths).contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
            }
        }
        return (included + projects).filter { item in
            if policyUnreadable { return false }
            if protectedPaths.isEmpty { return true }
            if item.cmd != nil { return false }
            return !item.paths.contains { shown in protectedPaths.contains { ProtectedPaths.overlaps(engine.env.expand(shown), $0) } }
        }.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }
    }

    /// The sum of several items, counting a folder inside another one once.
    func totalOf(_ items: [Candidate]) -> Int64 {
        var seen: [String] = []
        var total: Int64 = 0
        for it in items.sorted(by: { ($0.paths.first ?? "").count < ($1.paths.first ?? "").count }) {
            if !it.paths.isEmpty, it.paths.allSatisfy({ p in seen.contains { p == $0 || p.hasPrefix($0 + "/") } }) { continue }
            total += it.bytes
            seen += it.paths
        }
        return total
    }

    var planItems: [Candidate] { plan.compactMap { candidates[$0] } }
    var planTotal: Int64 { totalOf(planItems) }

    /// What to say about one item inside a rule, and whether to suggest removing it.
    func verdict(_ it: RuleItem) -> (pill: Pill, suggested: Bool)? {
        if it.flag == "leftover" { return (Pill(text: "Leftover", kind: .review), true) }
        guard let seen = it.seen, seen > 0 else { return nil }
        let d = days(seen)
        if d > 90 {
            let span = d < 730 ? "\(Int((d / 30.4).rounded())) months" : String(format: "%.1f years", d / 365)
            return (Pill(text: "No read in " + span, kind: .review), true)
        }
        if d < 30 { return (Pill(text: "Read " + age(seen)), false) }
        return nil
    }

    func suggested(_ r: Rule) -> [RuleItem] {
        (r.items ?? []).filter { (verdict($0)?.suggested ?? false) && !cleared.contains($0.id) && candidates[$0.id] != nil }
    }

    // MARK: - The cleanup list

    func inPlan(_ id: String) -> Bool { plan.contains(id) }

    func setPlan(_ ids: [String], _ on: Bool) {
        let wasEmpty = plan.isEmpty
        for id in ids where candidates[id] != nil {
            if on, !plan.contains(id) { plan.append(id) }
            if !on { plan.removeAll { $0 == id } }
        }
        if wasEmpty, !plan.isEmpty { showInspector = true }      // the first tick shows where ticked items collect
        saveState()
    }

    func togglePlan(_ ids: [String]) {
        let live = ids.filter { candidates[$0] != nil }
        guard !live.isEmpty else { return }
        setPlan(live, !live.allSatisfy(inPlan))
    }

    func clearPlan() {
        plan = []
        saveState()
    }

    private var stateKey: String { "state" }

    func saveState() {
        guard let scan else { return }
        defaults.set(["at": scan.scannedAt, "plan": plan, "cleared": Array(cleared)] as [String: Any], forKey: stateKey)
    }

    private func restoreState() {
        plan = []
        cleared = []
        guard let scan, let s = defaults.dictionary(forKey: stateKey),
              (s["at"] as? Double) == scan.scannedAt else { return }
        for id in s["cleared"] as? [String] ?? [] {
            cleared.insert(id)
            candidates[id] = nil
        }
        plan = (s["plan"] as? [String] ?? []).filter { candidates[$0] != nil }
    }

    // MARK: - Cleaning

    func review(_ ids: [String]) {
        guard session == nil else { return }
        var seen = Set<String>()
        let items = ids.filter { seen.insert($0).inserted }.compactMap { candidates[$0] }.sorted { $0.bytes > $1.bytes }
        guard !items.isEmpty else { return }
        session = CleanSession(items: items)
        refreshDry()
    }

    func reviewSafe() { review(safeItems.map(\.id)) }

    func selectSupport(_ path: String, for id: String, include: Bool) {
        guard let s = session, s.stage == .review, let base = candidates[id],
              let index = s.items.firstIndex(where: { $0.id == id }),
              base.supportOptions.contains(where: { $0.path == path }) else { return }
        var selected = s.items[index].selectedSupport
        if include { selected.insert(path) } else { selected.remove(path) }
        let options = base.supportOptions.filter { selected.contains($0.path) }
        s.items[index].paths = base.paths + options.map(\.path)
        s.items[index].bytes = base.bytes + options.reduce(0) { $0 + $1.returns }
        refreshDry()
    }

    func refreshDry() {
        guard let s = session, s.stage == .review else { return }
        let items = s.items
        let hard = s.hard
        s.previewRevision += 1
        let revision = s.previewRevision
        s.checkedHard = nil
        s.dry = [:]
        s.blocked = [:]
        s.previews = [:]
        Task {
            let results = await engine.dryRun(items, hard: hard, scan: scan)
            guard session === s, s.stage == .review, s.hard == hard, s.previewRevision == revision else { return }
            var dry: [String: String] = [:]
            var blocked: [String: String] = [:]
            for r in results {
                if r.ok, let preview = r.preview, preview.isEmpty {
                    blocked[r.id] = "Nothing remains to remove. Scan again to update its size."
                } else if r.ok, let preview = r.preview {
                    dry[r.id] = r.summary
                    s.previews[r.id] = preview
                } else { blocked[r.id] = r.errors.joined(separator: "; ") }
            }
            s.dry = dry
            s.blocked = blocked
            s.checkedHard = hard
        }
    }

    func removeFromSession(_ id: String) {
        guard let s = session, s.stage == .review else { return }
        s.items.removeAll { $0.id == id }
        setPlan([id], false)
        if s.items.isEmpty { session = nil } else { refreshDry() }
    }

    func runClean() async {
        guard let s = session, s.stage == .review, s.ready, !scanning, !s.previews.isEmpty else { return }
        s.stage = .running
        s.startFree = free
        let rank = ["safe": 0, "review": 1, "keep": 2]
        var order: [Candidate] = []
        for it in s.items {
            if let why = s.blocked[it.id] {
                s.marks[it.id] = .failed(why)
                s.failed += 1
            } else {
                order.append(it)
            }
        }
        order.sort { (rank[$0.safety] ?? 1, -$0.bytes) < (rank[$1.safety] ?? 1, -$1.bytes) }
        s.planned = order.count
        for (i, it) in order.enumerated() {
            if s.stopRequested { break }
            s.current = i
            s.marks[it.id] = .working
            guard let reviewed = s.previews[it.id] else { continue }
            let r = await engine.clean(it, hard: s.hard, scan: scan, reviewed: reviewed, sessionID: s.id.uuidString)
            if let f = r.free { free = f }
            s.trashed += r.trashed
            if r.ok {
                s.done += 1
                s.marks[it.id] = .ok(r.trashed > 0 ? "Moved to the Trash" : r.freed > MB ? "Cleaned, \(fmt(r.freed)) back" : "Cleaned")
                markCleared(it)
            } else {
                s.failed += 1
                s.marks[it.id] = .failed(r.errors.isEmpty ? "Not finished." : r.errors.joined(separator: "; "))
            }
        }
        s.current = order.count
        try? await Task.sleep(for: .seconds(1.2))      // the file system reports freed space a moment later
        readVolume()
        s.endFree = free
        s.stage = .done
        compute()
        saveState()
    }

    private func markCleared(_ it: Candidate) {
        var gone = [it.id]
        if it.cmd == nil, !it.paths.isEmpty {       // a removed folder takes everything listed under it along
            for c in candidates.values where c.id != it.id && !c.paths.isEmpty {
                if c.paths.allSatisfy({ p in it.paths.contains { p == $0 || p.hasPrefix($0 + "/") } }) { gone.append(c.id) }
            }
        }
        for id in gone {
            cleared.insert(id)
            candidates[id] = nil
        }
        plan.removeAll { gone.contains($0) }
    }

    func reviewHomeTrash() {
        guard let previous = session, previous.stage == .done, previous.trashed > 0 else { return }
        let trash = Candidate(id: "rule:trash", title: "Home Trash", bytes: 0, paths: ["~/.Trash"], safety: "review")
        session = CleanSession(items: [trash])
        refreshDry()
    }

    func closeSession() {
        if session?.stage == .running { return }
        session = nil
    }

    // MARK: - Scanning

    /// Measures the disk again. The current scan stays on screen until the new one is ready.
    func rescan() {
        guard !scanning, session == nil else { return }
        expectedFiles = scan?.stats.files ?? 0
        progress = "Starting"
        scanFraction = 0
        scanPath = ""
        scanRate = 0
        scanStarted = Date()
        scanning = true
        let p = ScanProgress()
        scanProgress = p
        Task {
            let watcher = Task { @MainActor in          // the engine counts; this shows the count
                var last = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    let now = p.snapshot
                    scanRate = (now.files - last) * 4
                    last = now.files
                    if !p.cancelled { progress = now.phase == "Measuring files" ? "Measured \(now.files.formatted()) files" : now.phase }
                    if !now.path.isEmpty { scanPath = now.path }
                    if now.phase != "Measuring files" {
                        scanFraction = 0.97
                    } else if expectedFiles > 0 {
                        scanFraction = min(0.95, Double(now.files) / Double(expectedFiles) * 0.95)
                    }
                }
            }
            do {
                if let result = try await engine.scan(progress: p) {
                    readVolume()
                    install(result)
                    if let s = session, s.stage == .review {
                        s.items = s.items.compactMap { candidates[$0.id] }
                        if s.items.isEmpty { closeSession() } else { refreshDry() }
                    }
                    phase = .ready
                    history = await engine.history(free: free, total: total)
                } else if scan == nil {
                    phase = .failed("The scan was stopped before it finished.")
                }
            } catch {
                if scan == nil { phase = .failed(error.localizedDescription) } else { scanError = error.localizedDescription }
            }
            watcher.cancel()
            scanProgress = nil
            scanning = false
        }
    }

    func cancelScan() {
        scanProgress?.cancel()
        progress = "Stopping"
    }

    // MARK: - Looking inside folders

    func toggleExpanded(_ uid: String, browse path: String?) {
        if expanded.contains(uid) {
            expanded.remove(uid)
            return
        }
        expanded.insert(uid)
        guard let path, browse[path] == nil else { return }
        browse[path] = Browse()
        let tree = scan?.tree
        Task {
            do {
                let listing = try await engine.list(path)
                guard scan?.tree === tree else { return }
                browse[path] = Browse(loading: false, entries: listing.entries, rest: listing.rest)
                for e in listing.entries where Self.pickableFile(e.path) && !cleared.contains("file:" + e.path) && candidates["file:" + e.path] == nil {
                    candidates["file:" + e.path] = Candidate(id: "file:" + e.path, title: e.name, bytes: e.returns, paths: [e.path], safety: "review")
                }
            } catch {
                guard scan?.tree === tree else { return }
                browse[path] = Browse(loading: false, error: error.localizedDescription)
            }
        }
    }

    // MARK: - Finder, Quick Look, the map

    func reveal(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: expandTilde($0)) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty { NSSound.beep() } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func preview(_ path: String) {
        let url = URL(fileURLWithPath: expandTilde(path))
        if FileManager.default.fileExists(atPath: url.path) { quickLook = url } else { NSSound.beep() }
    }

    func copyPaths(_ paths: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.map(expandTilde).joined(separator: "\n"), forType: .string)
    }

    func zoom(_ path: String) {
        guard let n = nodes[path] else { return }
        mapNode = n
        if page != .map { go(.map) }
    }

    func go(_ page: Page, focus: ReviewFocus = .all) {
        self.focus = focus
        kind = "all"
        minimumFileSize = .any
        modifiedBefore = .any
        tag = "all"
        group = "all"
        sort = "size"
        search = ""
        highlighted = []
        self.page = page
    }

    // MARK: - Free space, alerts, automatic scans

    func readVolume() {
        let url = URL(fileURLWithPath: FileManager.default.fileExists(atPath: "/System/Volumes/Data") ? "/System/Volumes/Data" : "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey,
                                                        .volumeAvailableCapacityForImportantUsageKey]) else { return }
        free = Int64(v.volumeAvailableCapacity ?? 0)
        total = Int64(v.volumeTotalCapacity ?? 0)
        purgeable = max(0, (v.volumeAvailableCapacityForImportantUsage ?? 0) - free)
    }

    func checkAccess() {
        // Listing this folder works only with Full Disk Access; macOS shows no prompt for it.
        fullDiskAccess = (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Library/Safari")) != nil
    }

    private func tick() {
        let before = free
        readVolume()
        if abs(free - before) > 50 * MB { compute() }
        let d = UserDefaults.standard
        let warn = Int64(d.object(forKey: "warnBelowGB") as? Int ?? 10) * GB
        if warn > 0, free > 0, free < warn, Date().timeIntervalSince1970 - d.double(forKey: "lastWarned") > 12 * 3600 {
            d.set(Date().timeIntervalSince1970, forKey: "lastWarned")
            notifyLowSpace()
        }
        let every: Double? = ["daily": 86400.0, "weekly": 604800.0][d.string(forKey: "autoScan") ?? "never"]
        if let every, phase == .ready, !scanning, session == nil, let scan, Date().timeIntervalSince1970 - scan.scannedAt > every {
            rescan()
        }
    }

    private func notifyLowSpace() {
        let free = self.free
        let safe = totals.safe
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Only \(fmt(free)) Free"
            content.body = safe > 500 * MB ? "About \(fmt(safe)) is safe to clear. Open Headroom to review it."
                                           : "Open Headroom to see what is filling the disk."
            center.add(UNNotificationRequest(identifier: "low-space", content: content, trigger: nil))
        }
    }

    var freeFraction: Double { total > 0 ? Double(free) / Double(total) : 1 }

    var health: Pill {
        freeFraction < 0.03 ? Pill(text: "Critically Full", kind: .crit)
            : freeFraction < 0.10 ? Pill(text: "Running Tight", kind: .review)
            : Pill(text: "Healthy", kind: .safe)
    }

    var scannedText: String {
        guard let scan else { return "" }
        let date = Date(timeIntervalSince1970: scan.scannedAt)
        return "Scanned " + date.formatted(.relative(presentation: .named))
    }
}
