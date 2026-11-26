// Filesystem regressions found in the storage and cleanup audit.
import Foundation

func auditRegressionTests() {
    T.test("scan output preserves reserved history and log files") {
        let f = Fixture()
        for name in ["history.json", "History.JSON", "headroom-actions.log"] {
            let path = f.root + "/" + name
            try Data("previous data".utf8).write(to: URL(fileURLWithPath: path))
            let env = Env(home: f.home, support: f.root, scanFile: path)
            do {
                _ = try Report.run(f.options(), env: env, progress: ScanProgress())
                T.fail("reserved filename accepted")
            } catch { T.expect(error.localizedDescription.contains("output filename")) }
            T.equal(try String(contentsOfFile: path), "previous data")
        }
    }

    T.test("a scan of one Applications folder omits outside apps and support files") {
        let f = Fixture()
        _ = f.app("Inside", id: "org.example.inside")
        _ = f.app("Outside", id: "org.example.outside", in: "OtherApps")
        f.dir("Library/Application Support/Inside")
        let root = f.path("Applications")
        let env = Env(home: f.home, support: f.root, appDirs: [root, f.path("OtherApps")])
        let scan = try Report.run(f.options(root: root), env: env, progress: ScanProgress(), write: false)
        T.equal(scan?.apps?.map(\.name), ["Inside"])
        T.expect(scan?.apps?.first?.leftovers == nil)
    }
    T.test("an ordinary target or Pods directory defaults to Trash") {
        let f = Fixture(), c = Cleaner(env: f.env)
        for name in ["target", "Pods"] {
            let path = f.dir("Documents/" + name)
            T.equal(try c.resolve("file:" + path, hard: false, scan: nil), [.trash(path)])
        }
        let document = f.file("Downloads/node_modules")
        T.equal(try c.resolve("file:" + document, hard: false, scan: nil), [.trash(document)])
        f.text("Documents/Cargo.toml", "[package]")
        T.equal(try c.resolve("file:~/Documents/target", hard: false, scan: nil), [.delete(f.path("Documents/target"))])
    }

    T.test("home Trash is explicit and limited to the fixture Trash directory") {
        let f = Fixture()
        let file = f.text(".Trash/old draft", "recoverable")
        let c = Cleaner(env: f.env)
        T.equal(Rules.table.first { $0.id == "trash" }?.safety, "review")
        let dry = c.clean("rule:trash", hard: false, dry: true, scan: nil)
        T.equal(dry.preview?.map(\.step), [.delete(file)])
        T.expect(f.exists(".Trash/old draft"))
        T.expect(c.clean("rule:trash", hard: false, dry: false, scan: nil, reviewed: dry.preview).ok)
        T.expect(!f.exists(".Trash/old draft"))
    }

    T.test("reviewed directory cleanup refuses newly added targets") {
        let f = Fixture()
        f.text("Library/Logs/old", "first")
        let c = Cleaner(env: f.env)
        let preview = c.clean("rule:logs", hard: false, dry: true, scan: nil)
        f.text("Library/Logs/new", "second")
        let result = c.clean("rule:logs", hard: false, dry: false, scan: nil, reviewed: preview.preview)
        T.expect(!result.ok)
        T.expect(f.exists("Library/Logs/old") && f.exists("Library/Logs/new"))
    }

    T.test("an item replaced after review is left in place") {
        let f = Fixture(), c = Cleaner(env: f.env)
        let path = f.text("Downloads/draft", "first")
        let id = "file:" + path
        let preview = c.clean(id, hard: false, dry: true, scan: nil)
        try FileManager.default.moveItem(atPath: path, toPath: path + "-old")
        f.text("Downloads/draft", "replacement")
        T.expect(!c.clean(id, hard: false, dry: false, scan: nil, reviewed: preview.preview).ok)
        T.expect(f.trashed.isEmpty)
        T.equal(try String(contentsOfFile: path), "replacement")
    }

    T.test("installed bundles use the uninstaller from every page") {
        let f = Fixture(), c = Cleaner(env: f.env)
        let app = f.app("Notebook", id: "org.example.notebook")
        for path in [app, app + "/Contents/Info.plist"] {
            T.refused("Applications") { try c.resolve("file:" + path, hard: true, scan: nil) }
        }
        T.equal(try c.resolve("app:" + app, hard: false, scan: nil), [.trash(app)])
    }

    T.test("an unsuccessful bundle removal leaves its support data in place") {
        let f = Fixture(), c = Cleaner(env: f.env)
        let app = f.app("Notebook", id: "org.example.notebook")
        f.text("Library/Application Support/Notebook/notes", "drafts")
        var calls: [String] = []
        f.env.trasher = { path in calls.append(path); throw EngineError("busy") }
        let result = c.clean("app:" + app, hard: false, dry: false, scan: nil, selectedSupport: ["~/Library/Application Support/Notebook"])
        T.expect(!result.ok)
        T.equal(calls, [app])
        T.expect(f.exists("Library/Application Support/Notebook/notes"))
    }

    T.test("incomplete model indexes leave shared blobs untouched") {
        let f = Fixture(), c = Cleaner(env: f.env)
        let hub = ".cache/huggingface/hub"
        f.file(hub + "/blobs/data")
        let unreadable = f.dir(hub + "/models--org--demo/snapshots")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable)
        defer { _ = chmod(unreadable, 0o700) }
        let r = c.clean("hforphans:~/" + hub, hard: false, dry: false, scan: nil)
        T.expect(!r.ok)
        T.expect(f.exists(hub + "/blobs/data"))
    }

    T.test("duplicate content is checked between the sampled offsets") {
        let f = Fixture()
        let big = 8_000_000
        f.file("Documents/one.bin", size: big, fill: 7)
        f.file("Documents/two.bin", size: big, fill: 7)
        let other = f.file("Documents/different.bin", size: big, fill: 7)
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: other))
        try h.seek(toOffset: 2_500_000)
        try h.write(contentsOf: Data([99]))
        try h.close()
        let groups = f.scan().dupes ?? []
        T.equal(groups.count, 1)
        T.equal(groups.first?.verified, true)
        T.equal(Set(groups.first?.files.map(\.path) ?? []), ["~/Documents/one.bin", "~/Documents/two.bin"])
    }

    T.test("a cancelled scan keeps the prior report and history intact") {
        let f = Fixture()
        _ = f.scan(write: true)
        let before = try Data(contentsOf: URL(fileURLWithPath: f.env.scanPath))
        let progress = ScanProgress()
        progress.cancel()
        let cancelled = try Report.run(f.options(), env: f.env, progress: progress)
        T.expect(cancelled == nil)
        T.equal(try Data(contentsOf: URL(fileURLWithPath: f.env.scanPath)), before)
        T.expect(!lexists(f.env.historyPath))
    }
    T.test("nested changes invalidate a permanent folder cleanup") {
        let f = Fixture(), c = Cleaner(env: f.env)
        f.text("proj/node_modules/nested/data", "before")
        let id = "file:~/proj/node_modules"
        let before = c.clean(id, hard: false, dry: true, scan: nil)
        T.expect(before.ok)
        f.text("proj/node_modules/nested/new", "arrived while reviewing")
        let result = c.clean(id, hard: false, dry: false, scan: nil, reviewed: before.preview)
        T.expect(!result.ok)
        T.expect(f.exists("proj/node_modules/nested/new"))
    }

    T.test("duplicate cleanup rechecks the retained copy even for old reports") {
        let f = Fixture(), c = Cleaner(env: f.env)
        let first = f.text("Documents/first", "equal contents")
        let second = f.text("Documents/second", "equal contents")
        var report = f.scan()
        report.dupes = [.init(bytes: 4096, files: [first, second].map { .init(path: f.env.disp($0), mtime: 1) })]
        let id = "duplicate:~/Documents/second"
        let preview = c.clean(id, hard: false, dry: true, scan: report)
        T.expect(preview.ok)
        f.text("Documents/first", "other contents")
        T.expect(!c.clean(id, hard: false, dry: false, scan: report, reviewed: preview.preview).ok)
        T.expect(f.exists("Documents/second") && f.trashed.isEmpty)
        try FileManager.default.removeItem(atPath: first)
        T.expect(!c.clean(id, hard: true, dry: true, scan: report).ok)
    }

    T.test("duplicate reads over budget are marked as sample matches") {
        let f = Fixture()
        f.file("Documents/a", size: 2_500_000)
        f.file("Documents/b", size: 2_500_000)
        let progress = ScanProgress()
        let core = Scanner.walk(f.options(), env: f.env, progress: progress)!
        let groups = Report.findDupes(core.big, stripRoot: "", env: f.env, progress: progress, fullReadBudget: 1)
        T.equal(groups.count, 1)
        T.equal(groups[0].verified, false)
    }

    T.test("live folder estimates only credit hard links when all names are inside") {
        let f = Fixture()
        f.file("one/a/data", size: 99_000)
        f.hardLink("one/b/second", to: "one/a/data")
        let outer = Reader.measure(f.path("one"))
        T.equal(outer.files, 1)
        T.equal(outer.bytes, f.allocated("one/a/data"))
        T.equal(outer.returns, outer.bytes)
        T.equal(Reader.measure(f.path("one/a")).returns, 0)
        T.expect(Reader.measure(f.path("missing")).partial)
    }

    T.test("time-series samples with the same timestamp are unique") {
        let f = Fixture()
        Report.addHistory(f.env, Sample(t: 123, free: 45))
        Report.addHistory(f.env, Sample(t: 123, free: 42, scan: 1))
        Report.addHistory(f.env, Sample(t: 123, free: 50))
        let history = Report.readHistory(f.env)
        T.equal(history.count, 1)
        T.equal(history.first?.free, 42)
        T.equal(history.first?.scan, 1)
    }

    T.test("invalid CLI arguments fail before scanning") {
        let f = Fixture()
        let valid = try CLI.options(["Headroom", "--scan", "--root", f.home, "--threads", "1"])
        T.equal(valid.root, f.home)
        T.equal(valid.threads, 1)
        for tail in [["--root"], ["--root", f.path("absent")], ["--root", f.file("regular")],
                     ["--threads", "0"], ["--threads", "65"], ["--threads", "lots"], ["--unknown"]] {
            do { _ = try CLI.options(["Headroom", "--scan"] + tail); T.fail("accepted invalid arguments") }
            catch is EngineError { T.expect(true) }
        }
    }

    T.test("developer self-tests require an explicitly isolated temporary home") {
        let f = Fixture()
        T.refused { try Env.fixture(nil) }
        T.refused { try Env.fixture(f.home) }
        let root = NSTemporaryDirectory() + "HeadroomFixture-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let env = try Env.fixture(root)
        T.equal(env.home, realPath(root))
        T.equal(env.appDirs, [])
        let src = env.home + "/sample"
        try Data([1]).write(to: URL(fileURLWithPath: src))
        try env.trasher(src)
        T.expect(!lexists(src))
        T.equal(listNames(env.support + "/Trash")?.count, 1)
    }

    T.test("a genuinely missing model blob does not hide other model entries") {
        let f = Fixture(), c = Cleaner(env: f.env)
        let hub = ".cache/huggingface/hub"
        let orphan = f.file(hub + "/blobs/unused")
        f.link(hub + "/models--org--demo/snapshots/missing", to: f.path(hub + "/blobs/missing"))
        T.equal(try c.resolve("hforphans:~/" + hub, hard: false, scan: nil), [.delete(orphan)])
    }

    T.test("later targets are rechecked after the first step in a batch") {
        let f = Fixture(), c = Cleaner(env: f.env)
        let base = "Library/Application Support/MobileSync/Backup/"
        let first = f.text(base + "A", "one")
        let second = f.text(base + "B", "two")
        let preview = c.clean("rule:ios-backups", hard: false, dry: true, scan: nil)
        var calls: [String] = []
        f.env.trasher = { path in
            calls.append(path)
            try FileManager.default.moveItem(atPath: path, toPath: f.trash + "/" + lastComponent(path))
            if path == first { f.text(base + "B", "modified during cleanup") }
        }
        let result = c.clean("rule:ios-backups", hard: false, dry: false, scan: nil, reviewed: preview.preview)
        T.expect(!result.ok)
        T.equal(result.trashed, 1)
        T.equal(calls, [first])
        T.equal(try String(contentsOfFile: second), "modified during cleanup")
    }

}
