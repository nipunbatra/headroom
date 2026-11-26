// Turns the scan into the rows each page lists. One row shape serves every list,
// so selection, context menus and cleaning behave the same everywhere.
import SwiftUI

enum FileSizeFilter: Int64, CaseIterable {
    case any = 0, oneGB = 1000000000, fiveGB = 5000000000
    var label: String { self == .any ? "Any size" : "\(rawValue / GB) GB or larger" }
}

enum FileAgeFilter: Int, CaseIterable {
    case any = 0, threeMonths = 90, oneYear = 365
    var label: String {
        switch self {
        case .any: return "Any date"
        case .threeMonths: return "90+ days ago"
        case .oneYear: return "1+ year ago"
        }
    }
}

enum ReviewFocus: String, Identifiable {
    case all = "All items", installers = "Installers", older = "Over a year old"
    case idle = "Idle builds", duplicates = "Duplicate groups"
    var id: Self { self }

    static func choices(for page: Page) -> [Self] {
        switch page {
        case .downloads: return [.all, .installers, .older]
        case .projects: return [.all, .idle]
        case .files: return [.all, .duplicates]
        default: return []
        }
    }
}

extension Download {
    var installer: Bool {
        !dir && ["dmg", "pkg", "iso", "ipsw"].contains((name as NSString).pathExtension.lowercased())
    }
}

struct BulkAction: Identifiable {
    var id: String
    var label: String
    var ids: [String]
    var help: String
}

struct Row: Identifiable {
    var id: String
    var cleanID: String?          // what to send to the helper to clean this row
    var title: String
    var pills: [Pill] = []
    var why = ""
    var path = ""
    var cmd = ""
    var bytes: Int64 = 0          // sizes the bar; shown as the figure unless `amount` is set
    var amount: String?
    var disk: Int64?              // size on disk, shown when cleaning returns clearly less
    var meta = ""
    var approx = false
    var browse: String?           // a folder that can be opened in place
    var reveal: String?
    var mapPath: String?
    var children: [Row] = []
    var startsOpen = false
    var appPath: String?          // draws that app's icon
    var swatch: Color?
    var note = false              // a line of text, not an item
    var loading = false
    var action: BulkAction?       // a button on a note row
    var link: Page?               // a button on a row that opens another page
    var date: Double?             // when it last changed, for sorting
}

struct FlatRow: Identifiable {
    var id: String
    var row: Row
    var depth: Int
    var max: Int64
    var expandable: Bool
    var expanded: Bool
}

struct RowSection: Identifiable {
    var id: String
    var title: String
    var subtitle = ""
    var rows: [Row]
    var bulk: [BulkAction] = []
    var empty = ""
}

extension AppModel {
    func isCleared(_ row: Row) -> Bool { row.cleanID.map(cleared.contains) ?? false }
    func isCleanable(_ row: Row) -> Bool { row.cleanID.map { candidates[$0] != nil } ?? false }

    /// Top-level rows in the order picked in the toolbar. Size is the default everywhere.
    func ordered(_ rows: [Row]) -> [Row] {
        switch sort {
        case "newest": return rows.sorted { ($0.date ?? 0) > ($1.date ?? 0) }
        case "oldest": return rows.sorted { ($0.date ?? .infinity) < ($1.date ?? .infinity) }
        case "name": return rows.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        default: return rows.sorted { $0.bytes > $1.bytes }
        }
    }

    func matches(_ row: Row) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        return row.title.localizedCaseInsensitiveContains(q) || row.path.localizedCaseInsensitiveContains(q)
            || row.why.localizedCaseInsensitiveContains(q)
    }

    /// Rows in display order with open rows followed by their children.
    func flatten(_ rows: [Row], depth: Int = 0, prefix: String = "") -> [FlatRow] {
        let top = max(1, rows.map(\.bytes).max() ?? 1)
        var out: [FlatRow] = []
        for r in rows {
            let uid = prefix + r.id
            let can = (!r.children.isEmpty || r.browse != nil) && !isCleared(r)
            let open = can && (expanded.contains(uid) != r.startsOpen)
            out.append(FlatRow(id: uid, row: r, depth: depth, max: top, expandable: can, expanded: open))
            guard open else { continue }
            if !r.children.isEmpty {
                out += flatten(r.children, depth: depth + 1, prefix: uid + "›")
            } else if let b = r.browse {
                out += flatten(browseRows(b), depth: depth + 1, prefix: uid + "›")
            }
        }
        return out
    }

    private func textRow(_ id: String, _ text: String) -> Row {
        var r = Row(id: id, title: text)
        r.note = true
        return r
    }

    /// The live contents of one folder, each entry a normal row.
    func browseRows(_ path: String) -> [Row] {
        guard let b = browse[path] else { return [] }
        if b.loading {
            var r = Row(id: "loading", title: "Measuring \(baseName(path))")
            r.loading = true
            r.note = true
            return [r]
        }
        if !b.error.isEmpty { return [textRow("error", b.error)] }
        if b.entries.isEmpty { return [textRow("empty", "This folder is empty.")] }
        var rows = b.entries.map { e -> Row in
            var r = Row(id: "file:" + e.path, cleanID: "file:" + e.path, title: e.name)
            if e.dir { r.pills = [Pill(text: "Folder")] } else if e.link { r.pills = [Pill(text: "Alias")] }
            r.bytes = e.returns
            r.disk = e.bytes
            r.approx = e.partial
            r.meta = (e.dir && e.files != nil ? plural(e.files ?? 0, "file") + " · " : "") + "changed " + ageText(e.mtime, now: Date().timeIntervalSince1970)
            r.browse = e.dir ? e.path : nil
            r.reveal = e.path
            return r
        }
        if let rest = b.rest {
            rows.append(textRow("rest", "\(plural(rest.count, "smaller item")) not listed, \(fmt(rest.bytes)) in all."))
        }
        return rows
    }

    // MARK: - Clean Up

    func ruleRow(_ r: Rule) -> Row {
        var row = Row(id: r.cleanID, cleanID: r.pickable ? r.cleanID : nil, title: r.title)
        row.pills = [Pill.safety(r.safety), Pill(text: AppModel.groupNames[r.group] ?? r.group)]
        row.why = r.why + (!r.pickable && r.safety != "keep" && r.cmd == "@manual" ? " Handled by hand, or inside the app that owns it." : "")
        row.path = r.paths.count == 1 ? r.paths[0] : (r.paths.isEmpty ? "" : "\(r.paths.count) folders")
        row.cmd = r.pickable ? (r.cmd ?? "") : ""
        row.bytes = left(r)
        row.disk = r.bytes
        if r.paths.count == 1 {
            let p = r.paths[0]
            if p.hasPrefix("~") { row.reveal = p }
            if let n = nodes[p], !n.children.isEmpty { row.mapPath = p }
            if (r.items ?? []).isEmpty, p.hasPrefix("~/") { row.browse = p }
        }
        if r.cmd == "@view:downloads" { row.link = .downloads }
        guard let items = r.items, !items.isEmpty else { return row }
        let sug = suggested(r)
        if !sug.isEmpty { row.meta = "\(sug.count) suggested · \(fmt(sug.reduce(0) { $0 + $1.returns }))" }
        var head = textRow("head", "\(plural(items.count, "item")) inside, largest first"
                           + (r.itemsRest.map { "; \(plural($0.count, "smaller one")) (\(fmt($0.bytes))) not listed" } ?? "") + ".")
        if !sug.isEmpty {
            head.action = BulkAction(id: "sug-" + r.id, label: "Add Suggested", ids: sug.map(\.id),
                                     help: "Add the leftovers and long-unread items to the cleanup list")
        }
        row.children = [head] + items.map { itemRow($0, r) }
            + [textRow("foot", "Suggested means a leftover, or no read recorded for 90 days. macOS notes reads only now and then, and a backup counts as one, so treat the read date as a hint.")]
        return row
    }

    private func itemRow(_ it: RuleItem, _ rule: Rule) -> Row {
        var row = Row(id: it.id, cleanID: it.id, title: it.name)
        if let k = it.kind { row.pills.append(Pill(text: k)) }
        if let v = verdict(it) { row.pills.append(v.pill) }
        row.why = it.note ?? ""
        row.path = it.path ?? ""
        row.bytes = it.returns
        row.disk = it.bytes
        if let c = it.changed { row.meta = (rule.group == "ml" ? "downloaded " : "changed ") + age(c) }
        if it.dir == true, let p = it.path, p.hasPrefix("~/") { row.browse = p }
        if !it.id.hasPrefix("hforphans:") { row.reveal = it.path }
        return row
    }

    var ruleGroups: [String] {
        var seen: [String] = []
        for r in scan?.rules ?? [] where !seen.contains(r.group) { seen.append(r.group) }
        return seen
    }

    func cleanupSections() -> [RowSection] {
        guard let scan else { return [] }
        let list = scan.rules.filter { group == "all" || $0.group == group }
        let subs = ["safe": "Rebuilt automatically by the app or tool that owns them. Quit the app before clearing its cache.",
                    "review": "Yours to judge. Most of these download or rebuild again, at the cost of time and bandwidth.",
                    "keep": "Large, but personal or managed by macOS. Shown so you know where the space went."]
        return ["safe", "review", "keep"].compactMap { k in
            let rs = list.filter { $0.safety == k }
            var rows = rs.map { ruleRow($0) }
            if k == "safe", group == "all" || group == "dev", let stale = staleRow() {
                rows.append(stale)
                rows.sort { $0.bytes > $1.bytes }
            }
            rows = rows.flatMap { row -> [Row] in
                if matches(row) { return [row] }
                return row.children.filter { !$0.note && matches($0) }.map { child in
                    var result = child
                    result.pills.append(Pill(text: row.title))
                    return result
                }
            }
            guard !rows.isEmpty else { return nil }
            let total = rows.filter { !isCleared($0) }.reduce(0) { $0 + $1.bytes }
            var ids = rows.compactMap(\.cleanID).filter { candidates[$0] != nil }
            if rows.contains(where: { $0.id == "x:stale" }) {
                ids += totals.staleFound.map { "file:" + $0.path }.filter { candidates[$0] != nil }
            }
            return RowSection(id: k, title: (AppModel.safetyTitle[k] ?? k) + " · " + fmt(total), subtitle: subs[k] ?? "", rows: rows,
                              bulk: k == "keep" || ids.isEmpty ? [] : [BulkAction(id: "rules-" + k, label: "Add All", ids: ids,
                                                                                 help: "Add every item in this group to the cleanup list")])
        }
    }

    /// The largest things worth clearing, for the Overview.
    func wins() -> [Row] {
        guard let scan else { return [] }
        var rows = scan.rules.filter { $0.safety != "keep" && !cleared.contains($0.cleanID) }.map { r -> Row in
            var row = ruleRow(r)
            row.children = []
            row.browse = nil
            row.pills = [Pill.safety(r.safety)]
            return row
        }
        if let stale = staleRow() { rows.append(stale) }
        return Array(rows.filter { $0.cleanID != nil }.sorted { $0.bytes > $1.bytes }.prefix(5))
    }

    /// One line standing for every rebuildable folder in a project nobody has touched for 90 days.
    func staleRow() -> Row? {
        guard !totals.staleFound.isEmpty else { return nil }
        var r = Row(id: "x:stale", title: "Build folders in idle projects")
        r.pills = [Pill.safety("safe"), Pill(text: "Developer Tools")]
        r.why = "\(totals.staleFound.count) folders such as node_modules in projects untouched for 90 days or more. Each one is listed under Projects."
        r.bytes = totals.staleFound.reduce(0) { $0 + $1.returns }
        r.link = .projects
        return r
    }

    // MARK: - What Changed

    func changeRow(_ c: Changes.Item) -> Row {
        let gone = c.gone ?? false
        var r = Row(id: "chg:" + c.path, title: c.path == "/" ? "Macintosh HD" : c.path == "~" ? "Home folder" : baseName(c.path))
        if !gone, AppModel.pickable(c.path) { r.cleanID = "file:" + c.path }
        r.path = c.path
        r.bytes = abs(c.delta)
        r.amount = signed(c.delta)
        r.meta = gone ? "no longer above the map's cutoff" : "now \(fmt(c.bytes))"
        if c.new ?? false { r.pills = [Pill(text: "New")] }
        if gone { r.pills = [Pill(text: "Gone")] } else {
            r.reveal = c.path
            if let n = nodes[c.path] {
                if !n.children.isEmpty { r.mapPath = c.path }
                if !n.isFile, c.path.hasPrefix("~/") { r.browse = c.path }
            }
        }
        return r
    }

    func changeSections() -> [RowSection] {
        guard let ch = scan?.changes else { return [] }
        let grew = ch.items.filter { $0.delta > 0 }.map(changeRow).filter(matches)
        let shrank = ch.items.filter { $0.delta < 0 }.map(changeRow).filter(matches)
        var out: [RowSection] = []
        if !grew.isEmpty {
            out.append(RowSection(id: "grew", title: "Grew · " + fmt(grew.reduce(0) { $0 + $1.bytes }),
                                  subtitle: "The deepest folders that explain the growth. Look inside one, or add it to the cleanup list.", rows: grew))
        }
        if !shrank.isEmpty {
            out.append(RowSection(id: "shrank", title: "Shrank · " + fmt(shrank.reduce(0) { $0 + $1.bytes }),
                                  subtitle: "Space that came back, from cleaning or from apps tidying up after themselves.", rows: shrank))
        }
        return out
    }

    // MARK: - Disk Map

    func mapRows(_ node: Node) -> [Row] {
        var rows = node.children.enumerated().map { i, k -> Row in
            var r = Row(id: "file:" + k.path, cleanID: AppModel.pickable(k.path) ? "file:" + k.path : nil, title: k.n)
            r.swatch = Palette.slot(i).color
            if let t = k.t, let info = AppModel.tags[t] { r.pills = [Pill(text: info.label)] }
            r.path = k.path
            r.bytes = k.s
            let share = node.s > 0 ? Double(k.s) / Double(node.s) * 100 : 0
            r.meta = String(format: "%.1f%%", share) + (k.f.map { " · " + plural($0, "file") } ?? "")
                + (k.returns < k.s * 9 / 10 ? " · deleting returns \(fmt(k.returns))" : "")
            if !k.isFile, k.path.hasPrefix("~/") { r.browse = k.path }
            r.reveal = k.path
            if !k.children.isEmpty { r.mapPath = k.path }
            return r
        }.filter(matches)
        let rest = node.s - node.children.reduce(0) { $0 + $1.s }
        if rest > MB, !node.children.isEmpty, search.isEmpty {
            rows.append(textRow("rest", "Smaller items: \(fmt(rest)). Files and folders under the map's size cutoff."))
        }
        return rows
    }

    // MARK: - Large Files

    var fileKinds: [String] {
        var seen: [String] = []
        for f in scan?.bigFiles ?? [] where !seen.contains(f.kind) { seen.append(f.kind) }
        return seen
    }

    var remainingDuplicateGroups: [DupeGroup] {
        (scan?.dupes ?? []).compactMap { group in
            guard let keeper = group.files.first, !cleared.contains("file:" + keeper.path) else { return nil }
            var remaining = group
            remaining.files = group.files.filter { !cleared.contains("duplicate:" + $0.path) && !cleared.contains("file:" + $0.path) }
            return remaining.files.count > 1 ? remaining : nil
        }
    }

    func fileSections() -> [RowSection] {
        guard let scan else { return [] }
        let files = (scan.bigFiles ?? []).filter { file in
            (kind == "all" || file.kind == kind) && file.bytes >= minimumFileSize.rawValue
                && (modifiedBefore == .any || (file.mtime > 0 && days(file.mtime) >= Double(modifiedBefore.rawValue)))
        }.map { f -> Row in
            var r = Row(id: "file:" + f.path, cleanID: "file:" + f.path, title: baseName(f.path))
            r.pills = [Pill(text: f.kind)]
            r.path = dirName(f.path)
            r.bytes = f.returns
            r.disk = f.bytes
            r.meta = "changed " + age(f.mtime)
            r.date = f.mtime
            r.reveal = f.path
            return r
        }.filter(matches)
        var out: [RowSection] = []
        if focus != .duplicates {
            let count = files.count > 300 ? "Showing the first 300 of \(files.count) matches." : plural(files.count, "matching file") + "."
            out.append(RowSection(id: "files", title: "Large Files", subtitle: count + " Size filters use space on disk. Each row shows the estimated space you can recover.",
                                  rows: Array(ordered(files).prefix(300)), empty: "No large files match."))
        }
        let dupes = remainingDuplicateGroups
        if (kind != "all" || modifiedBefore != .any || minimumFileSize != .any) && focus != .duplicates { return out }
        let rows = dupes.enumerated().map { i, g -> Row in
            var r = Row(id: "dupe:\(i)", title: baseName(g.files[0].path))
            r.pills = [Pill(text: "\(g.files.count) copies")]
            r.bytes = g.extraBytes
            r.meta = g.verified == true ? "full match at scan" : "sample match"
            r.startsOpen = true
            r.children = g.files.enumerated().map { j, f -> Row in
                var c = Row(id: "file:" + f.path, cleanID: j == 0 ? nil : "duplicate:" + f.path, title: baseName(f.path))
                c.pills = j == 0 ? [Pill(text: "Oldest copy", kind: .keep)] : []
                c.path = dirName(f.path)
                c.bytes = f.frees ?? g.bytes
                c.meta = "changed " + age(f.mtime)
                c.reveal = f.path
                return c
            }
            return r
        }.filter { r in matches(r) || r.children.contains(where: matches) }
        if !rows.isEmpty || focus == .duplicates {
            out.append(RowSection(id: "dupes", title: "Duplicate groups",
                                  subtitle: "Headroom compares the contents again before removing a copy. The oldest copy stays in place when cleaning from this group.",
                                  rows: rows, empty: "No duplicate groups in this scan."))
        }
        return out
    }

    // MARK: - Projects

    var projectTags: [String] {
        var seen: [String] = []
        for f in scan?.found ?? [] where !seen.contains(f.tag) { seen.append(f.tag) }
        return seen
    }

    func projectSections() -> [RowSection] {
        let all = scan?.found ?? []
        let rows = all.filter { (tag == "all" || $0.tag == tag) && (focus != .idle || foundSafety($0) == "safe") }.map { f -> Row in
            let info = AppModel.tags[f.tag]
            var r = Row(id: "file:" + f.path, cleanID: f.tag == "git" ? nil : "file:" + f.path, title: project(f))
            r.pills = [Pill(text: info?.label ?? f.tag)]
            if f.tag != "git" {
                r.pills.append(foundSafety(f) == "safe" ? Pill(text: "Idle, Rebuildable", kind: .safe)
                               : Pill(text: (f.projectMtime ?? 0) <= 0 ? "Activity unknown" : stale(f) ? "Idle" : "Recently changed", kind: .review))
            }
            r.why = info?.how ?? ""
            r.path = f.path
            r.bytes = f.returns
            r.disk = f.bytes
            r.meta = "project touched " + age(f.projectMtime)
            r.date = f.projectMtime
            r.reveal = f.path
            r.browse = f.tag == "git" ? nil : f.path
            return r
        }.filter(matches)
        let visible = Array(ordered(rows).prefix(300))
        let idle = visible.compactMap(\.cleanID).filter { candidates[$0]?.safety == "safe" }
        return [RowSection(id: "projects", title: "Dependency and Build Folders",
                           subtitle: "Inside your own projects. Idle means nothing in the project changed for 90 days.",
                           rows: visible,
                           bulk: idle.isEmpty ? [] : [BulkAction(id: "stale", label: "Add Idle Rebuildables", ids: idle, help: "Add rebuildable folders in idle projects to the cleanup list")],
                           empty: focus == .idle ? "No idle rebuildable folders match." : "No project folders match.")]
    }

    // MARK: - Downloads

    func downloadSections() -> [RowSection] {
        guard let dl = scan?.downloads else { return [] }
        let matching = dl.filter { f in
            if focus == .installers { return f.installer }
            if focus == .older { return f.mtime > 0 && days(f.mtime) > 365 }
            return true
        }
        var rows = matching.map { f -> Row in
            var r = Row(id: "file:" + f.path, cleanID: "file:" + f.path, title: f.name)
            if f.dir { r.pills.append(Pill(text: "Folder")) }
            if f.installer { r.pills.append(Pill(text: "Installer")) }
            r.bytes = f.returns
            r.disk = f.bytes
            r.meta = "changed " + age(f.mtime)
            r.date = f.mtime
            r.browse = f.dir ? f.path : nil
            r.reveal = f.path
            return r
        }.filter(matches)
        rows = ordered(rows)
        let visible = Set(rows.compactMap(\.cleanID))
        let eligible = matching.filter { visible.contains("file:" + $0.path) && candidates["file:" + $0.path] != nil }
        let inst = eligible.filter(\.installer).map { "file:" + $0.path }
        let old = eligible.filter { $0.mtime > 0 && days($0.mtime) > 365 }.map { "file:" + $0.path }
        if search.isEmpty, focus == .all {
            var every = Row(id: "all-downloads", title: "Everything in Downloads")
            every.why = "The full listing, measured now, including items under 5 MB."
            every.path = "~/Downloads"
            every.browse = "~/Downloads"
            every.reveal = "~/Downloads"
            every.amount = fmt(nodes["~/Downloads"]?.s ?? 0)       // shown as a figure only, so it does not flatten the other rows' bars
            rows.append(every)
        }
        var bulk: [BulkAction] = []
        if !inst.isEmpty { bulk.append(BulkAction(id: "dl-inst", label: "Add Installers", ids: inst, help: "Add disk images and installer packages to the cleanup list")) }
        if !old.isEmpty { bulk.append(BulkAction(id: "dl-old", label: "Add Older Than a Year", ids: old, help: "Add downloads untouched for a year to the cleanup list")) }
        return [RowSection(id: "downloads", title: "Downloads", subtitle: "Downloads of 5 MB or more. Age is based on the last modification.",
                           rows: rows, bulk: bulk, empty: "No downloads match this view.")]
    }

    // MARK: - Applications

    func appSections() -> [RowSection] {
        let apps = (scan?.apps ?? []).filter { $0.bytes > 0 }
        let rows = apps.map { a -> Row in
            let left = a.leftovers ?? []
            var r = Row(id: "app:" + a.path, cleanID: AppModel.pickable(a.path) ? "app:" + a.path : nil, title: a.name)
            r.appPath = a.path
            r.path = a.path
            r.bytes = a.returns
            r.disk = a.bytes
            r.meta = left.isEmpty ? "" : "\(fmt(a.leftoverBytes)) of optional support files"
            if let used = a.lastUsed {
                r.meta += (r.meta.isEmpty ? "" : " · ") + "opened " + age(used)
                r.date = used
                if days(used) > 180 { r.pills = [Pill(text: "Unused 6+ Months", kind: .review)] }
            }
            r.reveal = a.path
            r.children = left.map { l -> Row in
                var c = Row(id: "file:" + l.path, cleanID: "file:" + l.path, title: baseName(l.path))
                c.pills = [Pill(text: baseName(dirName(l.path)))]
                c.path = dirName(l.path)
                c.bytes = l.returns
                c.disk = l.bytes
                c.reveal = l.path
                if l.path.hasPrefix("~/"), !l.path.hasSuffix(".plist"), !l.path.hasSuffix(".binarycookies") { c.browse = l.path }
                return c
            }
            return r
        }.flatMap { row -> [Row] in
            if matches(row) { return [row] }
            return row.children.filter { matches($0) }.map { child in
                var result = child
                result.pills.append(Pill(text: row.title))
                return result
            }
        }
        return [RowSection(id: "apps", title: "Applications",
                           subtitle: "Select an app to uninstall its bundle. Its support files stay on your Mac unless you include them individually during review.",
                           rows: ordered(rows), empty: "No apps match.")]
    }
}
