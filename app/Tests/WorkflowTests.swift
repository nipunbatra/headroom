// Exercise the same model and row builders as the SwiftUI buttons, with an isolated defaults suite.
import Foundation

@MainActor private final class WorkflowFixture {
    let disk = Fixture()
    let suite = "local.headroom.tests." + UUID().uuidString
    let defaults: UserDefaults
    let model: AppModel
    var report: Scan

    init() {
        defaults = UserDefaults(suiteName: suite)!
        model = AppModel(engine: Engine(env: disk.env), defaults: defaults)
        report = disk.scan()
    }

    deinit { defaults.removePersistentDomain(forName: suite) }

    func download(_ name: String, days: Double, size: Int64 = MB, folder: Bool = false) -> Download {
        if folder { disk.dir("Downloads/" + name) } else { disk.text("Downloads/" + name, "fixture") }
        return Download(name: name, bytes: size, mtime: report.scannedAt - days * 86400, dir: folder)
    }

    func awaitReview() async throws -> CleanSession {
        for _ in 0..<500 {
            if let session = model.session, session.ready { return session }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw EngineError("preview did not finish")
    }
}

@MainActor func workflowTests() async {
    T.test("large file filters compose by allocated size and modification date") {
        let f = WorkflowFixture(), m = f.model, now = f.report.scannedAt
        func file(_ name: String, _ size: Int64, _ days: Int, _ kind: String = "Video") -> BigFile {
            BigFile(path: "~/Movies/" + name, bytes: size, mtime: days < 0 ? 0 : now - Double(days * 86400), kind: kind, frees: MB)
        }
        f.report.bigFiles = [file("Film A", GB, 365), file("Film B", GB - 1, 400), file("Film C", 5 * GB, 364),
                             file("Film D", 5 * GB, -1), file("Archive", 5 * GB, 600, "Data")]
        m.install(f.report)
        m.go(.files)
        m.minimumFileSize = .oneGB
        m.modifiedBefore = .oneYear
        m.kind = "Video"
        T.equal(m.fileSections()[0].rows.map(\.title), ["Film A"])
        T.equal(m.fileSections()[0].rows.first?.bytes, MB)
        m.search = "mismatch"
        T.expect(m.fileSections()[0].rows.isEmpty)
        m.go(.files)
        T.equal(m.minimumFileSize, .any)
        T.equal(m.modifiedBefore, .any)
        T.equal(m.fileSections()[0].rows.count, 5)
    }

    T.test("nested cleanup search stages only the matching child") {
        let f = WorkflowFixture(), m = f.model
        let parent = "~/Library/Developer/Xcode/DerivedData"
        let items = ["Studio", "Other"].map { name in
            RuleItem(id: "file:" + parent + "/" + name, name: name, path: parent + "/" + name, bytes: MB)
        }
        f.report.rules = [Rule(id: "xcode", group: "dev", safety: "safe", title: "Build cache", paths: [parent],
                               bytes: 2 * MB, why: "", items: items)]
        m.install(f.report)
        m.search = "Studio"
        let result = m.cleanupSections().first
        T.equal(result?.rows.map(\.title), ["Studio"])
        T.equal(result?.bulk.first?.ids, [items[0].id])
    }

    await T.asyncTest("uninstall review preserves unchecked support and recomputes its estimate") {
        let f = WorkflowFixture(), m = f.model
        let bundle = f.disk.app("Studio", id: "org.example.studio")
        let cache = "~/Library/Caches/org.example.studio", data = "~/Library/Application Support/Studio"
        for path in [cache, data] { f.disk.dir(f.disk.env.expand(path)) }
        let app = AppInfo(name: "Studio", path: f.disk.env.disp(bundle), bytes: 8 * MB,
                          leftovers: [.init(path: cache, bytes: MB), .init(path: data, bytes: 2 * MB)])
        let id = "app:" + app.path
        f.report.apps = [app]
        m.install(f.report)
        m.review([id, "file:" + cache])
        let s = try await f.awaitReview()
        T.equal(Set(s.blocked.keys), [id, "file:" + cache])
        m.removeFromSession("file:" + cache)
        _ = try await f.awaitReview()
        T.equal(s.previews[id]?.map(\.step), [.trash(bundle)])
        m.selectSupport(data, for: id, include: true)
        m.selectSupport(data, for: id, include: false)
        m.selectSupport(cache, for: id, include: true)
        T.expect(!s.ready)
        _ = try await f.awaitReview()
        T.equal(s.items.first?.bytes, 9 * MB)
        T.equal(s.previews[id]?.map(\.step), [.trash(bundle), .trash(f.disk.env.expand(cache))])
        await m.runClean()
        T.equal(s.done, 1)
        T.equal(f.disk.trashed, [bundle, f.disk.env.expand(cache)])
        T.expect(lexists(f.disk.env.expand(data)))
        T.expect(m.candidates["file:" + data] != nil)
    }

    T.test("old snapshots adopt current safety labels before quick cleanup") {
        let f = WorkflowFixture()
        f.report.rules = ["trash", "maven", "pycache", "logs"].map {
            Rule(id: $0, group: "system", safety: "safe", title: $0, paths: [], bytes: MB, why: "", cmd: "legacy")
        }
        f.model.install(f.report)
        T.equal(f.model.safeItems.map(\.id), ["rule:logs"])
        T.equal(f.model.candidates["rule:trash"]?.safety, "review")
        T.expect(f.model.candidates["rule:pycache"] == nil)
        T.expect(f.model.candidates["rule:trash"]?.cmd == nil)
        T.equal(f.model.totals.safe, MB)
    }

    T.test("installer focus and search scope every Downloads bulk action") {
        let f = WorkflowFixture(), m = f.model
        f.report.downloads = [f.download("Studio.DMG", days: 400), f.download("Editor.pkg", days: 500),
                              f.download("Studio notes.pdf", days: 390), f.download("Studio.pkg", days: 5, folder: true)]
        m.install(f.report)
        m.go(.downloads, focus: .installers)
        T.equal(m.downloadSections()[0].rows.map(\.title), ["Studio.DMG", "Editor.pkg"])
        m.search = "studio"
        let section = m.downloadSections()[0]
        T.equal(section.rows.map(\.title), ["Studio.DMG"])
        T.equal(section.bulk.map(\.ids), [["file:~/Downloads/Studio.DMG"], ["file:~/Downloads/Studio.DMG"]])
        m.search = "missing"
        T.expect(m.downloadSections()[0].bulk.isEmpty)
    }

    T.test("old downloads use the scan date and exclude missing dates") {
        let f = WorkflowFixture(), m = f.model
        var unknown = f.download("unknown", days: 1000)
        unknown.mtime = 0
        f.report.downloads = [unknown, f.download("year", days: 365), f.download("older", days: 366)]
        m.install(f.report)
        m.go(.downloads, focus: .older)
        T.equal(m.downloadSections()[0].rows.map(\.title), ["older"])
        m.go(.downloads)
        T.equal(m.focus, .all)
        T.equal(m.downloadSections()[0].rows.last?.id, "all-downloads")
    }

    T.test("idle project selection needs a known date and matches the visible type and search") {
        let f = WorkflowFixture(), m = f.model
        f.report.found = ["one", "two", "unknown", "active"].enumerated().map { index, name in
            Found(tag: index == 1 ? "rust-target" : "node_modules", path: "~/Projects/" + name + "/build",
                  bytes: 3 * MB, projectMtime: index == 2 ? nil : f.report.scannedAt - Double(index == 3 ? 3 : 100) * 86400)
        }
        m.install(f.report)
        m.go(.projects, focus: .idle)
        T.equal(m.projectSections()[0].rows.count, 2)
        m.tag = "rust-target"
        T.equal(m.projectSections()[0].bulk.first?.ids, ["file:~/Projects/two/build"])
        m.search = "one"
        T.expect(m.projectSections()[0].bulk.isEmpty)
        T.equal(m.candidates["file:~/Projects/unknown/build"]?.safety, "review")
    }

    T.test("cleanup category totals and Add All follow the search") {
        let f = WorkflowFixture(), m = f.model
        f.report.rules = ["logs", "uv"].map {
            Rule(id: $0, group: "caches", safety: "safe", title: $0, paths: ["~/.cache/" + $0], bytes: MB, why: "")
        }
        m.install(f.report)
        m.search = "uv"
        let section = m.cleanupSections()[0]
        T.equal(section.rows.map(\.id), ["rule:uv"])
        T.equal(section.bulk.first?.ids, ["rule:uv"])
        T.expect(section.title.contains(fmt(MB)))
    }

    T.test("duplicate-only view accepts old reports and handles empty groups") {
        let f = WorkflowFixture(), m = f.model
        let paths = ["~/Documents/a", "~/Documents/b"]
        f.report.dupes = [DupeGroup(bytes: MB, files: []),
                          DupeGroup(bytes: MB, files: paths.map { .init(path: $0, mtime: 1) })]
        m.install(f.report)
        m.go(.files, focus: .duplicates)
        let sections = m.fileSections()
        T.equal(sections.map(\.id), ["dupes"])
        T.equal(sections[0].rows.count, 1)
        T.expect(sections[0].rows[0].meta.contains("sample"))
        T.expect(sections[0].rows[0].children[0].cleanID == nil)
        T.expect(sections[0].bulk.isEmpty)
    }

    T.test("a verified cloned copy shows its own estimated reclaimable bytes") {
        let f = WorkflowFixture()
        let copy = DupeGroup.Copy(path: "~/Documents/copy", mtime: 2, frees: 0)
        f.report.dupes = [.init(bytes: 2 * GB, files: [.init(path: "~/Documents/original", mtime: 1, frees: 0), copy], verified: true)]
        f.model.install(f.report)
        T.equal(f.model.candidates["file:" + copy.path]?.bytes, 0)
        T.equal(f.report.dupes?.first?.extraBytes, 0)
    }

    await T.asyncTest("review waits for the current preview and executes only approved fixture items") {
        let f = WorkflowFixture(), m = f.model
        f.report.downloads = [f.download("keep.txt", days: 2), f.download("remove.txt", days: 3)]
        m.install(f.report)
        let ids = f.report.downloads!.map { "file:" + $0.path }
        m.setPlan(ids, true)
        m.review(ids)
        await m.runClean() // The dry run task has not returned to the main actor.
        T.expect(f.disk.trashed.isEmpty)
        m.session?.hard = true
        m.refreshDry()
        m.session?.hard = false
        m.removeFromSession(ids[0])
        let s = try await f.awaitReview()
        T.equal(s.dry.keys.sorted(), [ids[1]])
        T.equal(s.dry[ids[1]], "Moves 1 item to the Trash")
        await m.runClean()
        T.equal(s.done, 1)
        T.equal(s.failed, 0)
        T.expect(f.disk.exists("Downloads/keep.txt"))
        T.equal(f.disk.trashed, [f.disk.path("Downloads/remove.txt")])
        T.expect(m.plan.isEmpty)
        T.expect(m.cleared.contains(ids[1]))
        let reopened = AppModel(engine: m.engine, defaults: f.defaults)
        reopened.install(f.report)
        T.expect(reopened.cleared.contains(ids[1]))
    }

    await T.asyncTest("a missing target cannot start an all-blocked cleanup") {
        let f = WorkflowFixture(), m = f.model
        f.report.downloads = [Download(name: "missing.txt", bytes: MB, mtime: 0, dir: false)]
        m.install(f.report)
        let id = "file:~/Downloads/missing.txt"
        m.review([id])
        let s = try await f.awaitReview()
        T.expect(s.blocked[id] != nil)
        await m.runClean()
        T.expect(s.stage == .review)
        T.expect(!lexists(f.disk.env.logPath))
    }
    T.test("quick cleanup remembers exclusions across launches and regrouped caches") {
        let f = WorkflowFixture(), m = f.model
        let path = "~/Library/Caches/Example"
        f.report.rules = [Rule(id: "cache:" + path, group: "caches", safety: "safe", title: "Example cache", paths: [path], bytes: MB, why: "")]
        m.install(f.report)
        let id = "rule:cache:" + path
        m.includeInQuickCleanup(id, false)
        T.expect(m.safeItems.isEmpty)
        T.expect(m.candidates[id] != nil, "direct review remains available")
        f.report.rules = [Rule(id: "cache-rest:~/Library/Caches", group: "caches", safety: "safe", title: "Small caches",
                               paths: [path, "~/Library/Caches/Other"], bytes: 2 * MB, why: "")]
        let next = AppModel(engine: m.engine, defaults: f.defaults)
        next.install(f.report)
        T.expect(next.safeItems.isEmpty)
        next.includeInQuickCleanup(id, true)
        T.equal(next.safeItems.map(\.title), ["Small caches"])
    }

    await T.asyncTest("review catches selections that would remove the retained copy") {
        let f = WorkflowFixture(), m = f.model
        let paths = ["~/Documents/older", "~/Documents/newer"]
        for path in paths { f.disk.text(f.disk.env.expand(path), "same content") }
        f.report.dupes = [.init(bytes: MB, files: paths.map { .init(path: $0, mtime: 1) }, verified: true)]
        m.install(f.report)
        let keeper = "file:" + paths[0], copy = "duplicate:" + paths[1]
        m.review([keeper, copy])
        let s = try await f.awaitReview()
        T.equal(Set(s.blocked.keys), [keeper, copy])
        T.expect(s.previews.isEmpty)
        m.removeFromSession(keeper)
        _ = try await f.awaitReview()
        T.expect(s.blocked.isEmpty)
        await m.runClean()
        T.expect(lexists(f.disk.env.expand(paths[0])))
        T.equal(f.disk.trashed, [f.disk.env.expand(paths[1])])
        T.expect(m.remainingDuplicateGroups.isEmpty)
        m.go(.files, focus: .duplicates)
        T.expect(m.fileSections()[0].rows.isEmpty)
    }

    T.test("disk map leaf tiles have useful paths and zero-size layouts are empty") {
        let root = Node(n: "Documents", s: 400)
        let file = Node(n: "video", s: 400, k: "f")
        file.path = "~/Documents/video"
        root.c = [file]
        T.expect(Treemap.layout(root, size: .zero).isEmpty)
        let tiles = Treemap.layout(root, size: CGSize(width: 200, height: 120))
        T.equal(tiles.count, 1)
        T.equal(tiles.first?.path, file.path)
        T.expect(tiles.first?.zoom == nil)
        T.expect(tiles.allSatisfy { $0.rect.width > 0 && $0.rect.height > 0 })
    }

    await T.asyncTest("review flags overlapping parent and child targets until one is removed") {
        let f = WorkflowFixture(), m = f.model
        let paths = ["~/Documents/folder", "~/Documents/folder/file"]
        f.disk.text("Documents/folder/file", "example")
        f.report.bigFiles = paths.map { BigFile(path: $0, bytes: MB, mtime: 1, kind: "Data") }
        m.install(f.report)
        let ids = paths.map { "file:" + $0 }
        m.review(ids)
        let s = try await f.awaitReview()
        T.equal(Set(s.blocked.keys), Set(ids))
        m.removeFromSession(ids[1])
        _ = try await f.awaitReview()
        T.equal(Set(s.previews.keys), [ids[0]])
        T.expect(s.blocked.isEmpty)
    }

    await T.asyncTest("post-cleanup Trash offers a fresh review before any permanent removal") {
        let f = WorkflowFixture(), m = f.model
        f.disk.text(".Trash/from-an-earlier-cleanup", "keep until reviewed")
        let previous = CleanSession(items: [])
        previous.stage = .done
        previous.trashed = 1
        m.session = previous
        m.reviewHomeTrash()
        let s = try await f.awaitReview()
        T.expect(s !== previous && s.stage == .review)
        T.equal(s.previews["rule:trash"]?.map(\.step), [.delete(f.disk.path(".Trash/from-an-earlier-cleanup"))])
        T.expect(f.disk.exists(".Trash/from-an-earlier-cleanup"))
        m.closeSession()
        T.expect(f.disk.exists(".Trash/from-an-earlier-cleanup"))
    }

}
