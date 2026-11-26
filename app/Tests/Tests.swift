// Headroom's engine tests. Run with ./test.sh. Each test builds what it needs inside a
// throwaway home folder and checks the scanner, the reports and, above all, what may be deleted.
import Darwin
import Foundation

@main
enum TestMain {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        if args.count >= 4, args[1] == "--make-fixture" {       // for the cross-check with scan.py
            CrossCheck.make(home: args[2], support: args[3])
            return
        }
        if args.count >= 4, args[1] == "--scan-fixture" {
            CrossCheck.scan(home: args[2], support: args[3])
            return
        }
        if args.count >= 2 { T.filter = args[1] }
        print("Path policy")
        pathPolicy()
        print("What an id means")
        resolving()
        print("Cleaning")
        cleaning()
        print("Reading folders")
        reading()
        print("Scanning")
        scanning()
        print("Reports")
        reports()
        print("Changes and history")
        changes()
        auditRegressionTests()
        await workflowTests()
        if T.count == 0 { T.fail("No tests matched") }
        print("\n\(T.count) tests, \(T.passed) checks passed, \(T.failed.count) failed")
        for f in T.failed { print("  " + f) }
        exit(T.failed.isEmpty ? 0 : 1)
    }
}

// MARK: - Path policy

func pathPolicy() {
    T.test("userPathOK accepts only deep paths in the home folder and apps in /Applications") {
        let f = Fixture()
        let h = f.home
        f.dir("Documents/work")
        f.dir("Library/Caches/foo")
        f.dir("p/.git/objects")
        f.dir("p/.github")
        let ok = { (p: String) in Cleaner.userPathOK(p, env: f.env) }
        T.expect(ok(h + "/Documents/work"), "two levels deep")
        T.expect(ok(h + "/Documents/missing.bin"), "a missing file two levels deep is still a valid target")
        T.expect(!ok(h + "/Documents"), "a top-level folder such as ~/Documents")
        T.expect(!ok(h), "the home folder itself")
        T.expect(!ok(h + "/Library/Caches"), "~/Library needs three levels")
        T.expect(ok(h + "/Library/Caches/foo"))
        T.expect(ok("/Applications/Example.app"))
        T.expect(!ok("/Applications/Utilities/Terminal.app"))
        T.expect(!ok("/Applications/Example.app/Contents"))
        T.expect(!ok("/Applications/Example.app\n"), "a trailing newline is not part of an app name")
        T.expect(!ok("/Applications/a\nb.app"))
        T.expect(!ok("/Applications"))
        T.expect(!ok("/etc/hosts"))
        T.expect(!ok("/System/Library/Caches/x"))
        T.expect(!ok(h + "x/y/z"), "a sibling folder whose name starts like the home folder")
        T.expect(!ok(h + "/Documents/../../outside/x"), "dot-dot parts")
        T.expect(!ok(h + "/Documents/./work"), "dot parts")
        T.expect(!ok(h + "/Documents/work/"), "trailing slash")
        T.expect(!ok(h + "//Documents/work"), "doubled slash")
        T.expect(!ok("Documents/work"), "relative path")
        T.expect(!ok(""), "empty path")
        T.expect(!ok(h + "/p/.git"), "a .git folder")
        T.expect(!ok(h + "/p/.git/objects"), "inside a .git folder")
        T.expect(ok(h + "/p/.github"), ".github is not .git")
    }

    T.test("userPathOK refuses anything reached through a symlink that leaves the home folder") {
        let f = Fixture()
        try FileManager.default.createDirectory(atPath: f.root + "/outside/data", withIntermediateDirectories: true)
        f.link("escape", to: f.root + "/outside")
        f.dir("real/inner")
        f.link("alias", to: f.home + "/real")
        T.expect(!Cleaner.userPathOK(f.home + "/escape/data", env: f.env), "parent resolves outside home")
        T.expect(!Cleaner.userPathOK(f.home + "/alias/inner", env: f.env), "aliased parents cannot change a path’s cleanup policy")
    }

    T.test("isNormal matches what a normalised absolute path looks like") {
        T.expect(isNormal("/a/b"))
        T.expect(isNormal("/"))
        T.expect(!isNormal("/a/b/"))
        T.expect(!isNormal("/a//b"))
        T.expect(!isNormal("/a/./b"))
        T.expect(!isNormal("/a/../b"))
        T.expect(!isNormal("a/b"))
        T.expect(isNormal("/a/..b/c."), "dots inside a name are fine")
    }
}

// MARK: - Resolving ids

func resolving() {
    T.test("file ids go to the Trash, except rebuildable folders and cache contents") {
        let f = Fixture()
        let c = Cleaner(env: f.env)
        let doc = f.file("Documents/report.pdf")
        let nm = f.dir("proj/node_modules")
        let wheel = f.file(".cache/uv/wheels/a.whl")
        T.equal(try c.resolve("file:~/Documents/report.pdf", hard: false, scan: nil), [.trash(doc)])
        T.equal(try c.resolve("file:~/Documents/report.pdf", hard: true, scan: nil), [.delete(doc)])
        T.equal(try c.resolve("file:~/proj/node_modules", hard: false, scan: nil), [.delete(nm)], "node_modules rebuilds")
        T.equal(try c.resolve("file:~/.cache/uv/wheels/a.whl", hard: false, scan: nil), [.delete(wheel)], "inside a safe rule")
        T.refused("already gone") { try c.resolve("file:~/Documents/nope.pdf", hard: false, scan: nil) }
        T.refused("outside the folders") { try c.resolve("file:~/Documents", hard: false, scan: nil) }
        T.refused("outside the folders") { try c.resolve("file:/etc/hosts", hard: true, scan: nil) }
        T.refused("outside the folders") { try c.resolve("file:~/Documents/../../x/y", hard: false, scan: nil) }
        T.refused("unknown item") { try c.resolve("rm -rf ~", hard: true, scan: nil) }
        T.refused("unknown item") { try c.resolve("", hard: false, scan: nil) }
    }

    T.test("rule ids take their meaning from the rules table, never from the caller") {
        let f = Fixture()
        let c = Cleaner(env: f.env)
        let log = f.file("Library/Logs/app.log")
        let model = f.dir(".cache/huggingface/hub")
        let backup = f.dir("Library/Application Support/MobileSync/Backup/phone")
        T.equal(try c.resolve("rule:uv", hard: false, scan: nil), [.run("uv cache clean")])
        T.refused("individual") { try c.resolve("rule:pycache", hard: false, scan: nil) }
        T.equal(try c.resolve("rule:logs", hard: false, scan: nil), [.delete(log)], "safe rules delete their contents")
        T.equal(try c.resolve("rule:hf", hard: false, scan: nil), [.delete(model)], "download caches are deleted outright")
        T.equal(try c.resolve("rule:ios-backups", hard: false, scan: nil), [.trash(backup)], "review rules go to the Trash")
        T.equal(try c.resolve("rule:ios-backups", hard: true, scan: nil), [.delete(backup)])
        T.refused("handled by hand") { try c.resolve("rule:photos", hard: true, scan: nil) }
        T.refused("handled by hand") { try c.resolve("rule:rustup", hard: true, scan: nil) }
        T.refused("handled by hand") { try c.resolve("rule:downloads", hard: true, scan: nil) }
        T.refused("unknown item") { try c.resolve("rule:made-up", hard: true, scan: nil) }
        T.refused("not a folder") { try c.resolve("rule:gradle", hard: false, scan: nil) }
    }

    T.test("a rule folder that is a symlink is left alone") {
        let f = Fixture()
        f.dir("elsewhere/keep")
        f.dir("Library")
        f.link("Library/Logs", to: f.home + "/elsewhere")
        T.refused("not a folder") { try Cleaner(env: f.env).resolve("rule:logs", hard: false, scan: nil) }
        T.expect(f.exists("elsewhere/keep"))
    }

    T.test("cache ids are checked against the scan and the cache containers") {
        let f = Fixture()
        let c = Cleaner(env: f.env)
        let blob = f.file("Library/Caches/com.example.app/blob.bin")
        f.file("Documents/keep.txt")
        func scan(_ rules: [Rule]) -> Scan {
            Scan(scannedAt: 1, seconds: 0, os: "", root: "~", disk: Disk(total: 0, free: 0, scanned: 0), stats: Stats(files: 0, dirs: 0),
                 tree: Node(n: "~", s: 0), kinds: [], rules: rules)
        }
        let good = Rule(id: "cache:~/Library/Caches/com.example.app", group: "caches", safety: "safe", title: "", paths: ["~/Library/Caches/com.example.app"], bytes: 1, why: "")
        let forged = Rule(id: "cache:~/Documents", group: "caches", safety: "safe", title: "", paths: ["~/Documents"], bytes: 1, why: "")
        let dotted = Rule(id: "cache:x", group: "caches", safety: "safe", title: "", paths: ["~/Library/Caches/../../Documents"], bytes: 1, why: "")
        T.equal(try c.resolve("rule:cache:~/Library/Caches/com.example.app", hard: false, scan: scan([good])), [.delete(blob)])
        T.refused("no scan") { try c.resolve("rule:cache:~/Library/Caches/com.example.app", hard: false, scan: nil) }
        T.refused("not in the current scan") { try c.resolve("rule:cache:~/Library/Caches/other", hard: false, scan: scan([good])) }
        T.refused("not a cache folder") { try c.resolve("rule:cache:~/Documents", hard: false, scan: scan([forged])) }
        T.refused("not a cache folder") { try c.resolve("rule:cache:x", hard: false, scan: scan([dotted])) }
    }

    T.test("uninstalling an app takes only what carries its own id or exact name") {
        let f = Fixture()
        let c = Cleaner(env: f.env)
        let app = f.app("Sample", id: "com.example.sample")
        let cache = f.dir("Library/Caches/com.example.sample")
        let support = f.dir("Library/Application Support/Sample")
        let prefs = f.text("Library/Preferences/com.example.sample.plist", "<plist/>")
        f.dir("Library/Caches/com.example.sample2")
        f.dir("Library/Application Support/SampleOther")
        f.dir("Library/Application Support/Google")
        let id = "app:~/Applications/Sample.app"
        let selected = Set([cache, support, prefs])
        T.equal(try c.resolve(id, hard: false, scan: nil), [.trash(app)])
        T.equal(try c.resolve(id, hard: false, scan: nil, selectedSupport: [cache]), [.trash(app), .trash(cache)])
        T.refused("no longer belongs") { try c.resolve(id, hard: true, scan: nil, selectedSupport: ["~/Documents/notes"]) }
        let steps = try c.resolve(id, hard: false, scan: nil, selectedSupport: selected)
        T.equal(Set(steps.map { "\($0)" }), Set([app, cache, support, prefs].map { "\(Step.trash($0))" }))
        T.equal(steps.first, .trash(app), "the app itself goes first")
        T.equal(try c.resolve(id, hard: true, scan: nil, selectedSupport: selected).count, 4)
        T.expect(try c.resolve(id, hard: true, scan: nil, selectedSupport: selected).allSatisfy { if case .delete = $0 { return true } else { return false } })
    }

    T.test("uninstall refuses things that are not apps in an Applications folder") {
        let f = Fixture()
        let c = Cleaner(env: f.env)
        f.dir("Documents/Archive.app")
        f.dir("Applications/Empty.app")
        _ = f.app("Stray", id: "com.example.stray", in: "Documents")
        f.link("Applications/Linked.app", to: f.home + "/Documents/Stray.app")
        T.refused("not an app Headroom can remove") { try c.resolve("app:~/Documents/Archive.app", hard: false, scan: nil) }
        T.refused("not an app Headroom can remove") { try c.resolve("app:~/Documents/Stray.app", hard: false, scan: nil) }
        T.refused("not an app Headroom can remove") { try c.resolve("app:~/Applications", hard: false, scan: nil) }
        T.refused("not an app Headroom can remove") { try c.resolve("app:/Applications/Utilities/Terminal.app", hard: false, scan: nil) }
        T.refused("not an app Headroom can remove") { try c.resolve("app:/System/Applications/Mail.app", hard: false, scan: nil) }
        T.refused("not an app bundle") { try c.resolve("app:~/Applications/Empty.app", hard: false, scan: nil) }
        T.refused("already gone") { try c.resolve("app:~/Applications/Linked.app", hard: false, scan: nil) }
        T.refused("already gone") { try c.resolve("app:~/Applications/Missing.app", hard: false, scan: nil) }
    }

    T.test("leftovers are never matched for shared ids, shared names, vendor folders or odd plists") {
        let f = Fixture()
        _ = f.app("One", id: "com.example.shared")
        _ = f.app("Two", id: "com.example.shared")
        _ = f.app("Google", id: "com.example.g")
        _ = f.app("Short", id: "example.short")
        _ = f.app("Dots", id: "com.example..dots", bundleName: "../../Documents")
        let link = f.app("Borrowed", id: "com.example.victim")
        f.text("elsewhere/Info.plist", "<plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>com.example.victim</string></dict></plist>")
        try FileManager.default.removeItem(atPath: link + "/Contents/Info.plist")
        symlink(f.home + "/elsewhere/Info.plist", link + "/Contents/Info.plist")
        for d in ["Library/Caches/com.example.shared", "Library/Application Support/Google", "Library/Caches/example.short",
                  "Library/Caches/com.example.victim", "Library/Application Support/One", "Documents/x"] { f.dir(d) }
        let shared = Report.sharedAppNames(f.env)
        T.expect(shared.contains("com.example.shared"))
        T.equal(Report.appLeftovers(f.home + "/Applications/One.app", shared: shared, env: f.env), [f.home + "/Library/Application Support/One"],
                "the shared id is skipped, the app's own name still counts")
        T.equal(Report.appLeftovers(f.home + "/Applications/Two.app", shared: shared, env: f.env), [])
        T.equal(Report.appLeftovers(f.home + "/Applications/Google.app", shared: shared, env: f.env), [], "vendor folder name")
        T.equal(Report.appLeftovers(f.home + "/Applications/Short.app", shared: shared, env: f.env), [], "two-part id")
        T.equal(Report.appLeftovers(f.home + "/Applications/Dots.app", shared: shared, env: f.env), [], "dot-dot in id and name")
        T.expect(Report.appIdentity(link).id == nil, "an Info.plist reached through a link gives no identity")
        let odd = f.app("Newline", id: "com.example.newline\n", bundleName: "Newline\n")
        T.expect(Report.appIdentity(odd).id == nil && Report.appIdentity(odd).name == nil, "ids and names with a line break are not used")
        T.expect(!Report.isHFRepo("models--org--a\n") && Report.isHFRepo("models--org--a"))
        T.equal(Report.appLeftovers(link, shared: shared, env: f.env), [])
    }

    T.test("leftovers are not followed through a symlinked Library folder") {
        let f = Fixture()
        _ = f.app("Sample", id: "com.example.sample")
        f.dir("Documents/Sample")
        f.dir("Library")
        f.link("Library/Application Support", to: f.home + "/Documents")
        T.equal(Report.appLeftovers(f.home + "/Applications/Sample.app", shared: [], env: f.env), [])
    }

    T.test("Hugging Face repos take only the blobs nothing else links to") {
        let f = Fixture()
        let c = Cleaner(env: f.env)
        let hub = f.dir(".cache/huggingface/hub")
        let a = hub + "/models--org--a", b = hub + "/models--org--b"
        for blob in ["aa/only-a", "bb/only-b", "cc/both", "dd/orphan"] { f.file(".cache/huggingface/hub/blobs/" + blob, size: 20_000) }
        f.link(".cache/huggingface/hub/models--org--a/snapshots/r1/w.bin", to: hub + "/blobs/aa/only-a")
        f.link(".cache/huggingface/hub/models--org--a/snapshots/r1/tok.json", to: hub + "/blobs/cc/both")
        f.link(".cache/huggingface/hub/models--org--b/snapshots/r1/w.bin", to: hub + "/blobs/bb/only-b")
        f.link(".cache/huggingface/hub/models--org--b/snapshots/r1/tok.json", to: hub + "/blobs/cc/both")
        T.equal(try c.resolve("hfrepo:~/.cache/huggingface/hub/models--org--a", hard: false, scan: nil), [.delete(a), .delete(hub + "/blobs/aa/only-a")])
        T.equal(try c.resolve("hforphans:~/.cache/huggingface/hub", hard: false, scan: nil), [.delete(hub + "/blobs/dd/orphan")])
        T.refused("already gone") { try c.resolve("hfrepo:~/.cache/huggingface/hub/models--org--zzz", hard: false, scan: nil) }
        T.refused("not a Hugging Face cache") { try c.resolve("hfrepo:~/Documents/models--org--a", hard: false, scan: nil) }
        T.refused("not a Hugging Face cache") { try c.resolve("hforphans:~/Documents", hard: false, scan: nil) }
        T.refused("not a Hugging Face cache") { try c.resolve("hfrepo:~/.cache/huggingface/hub/../hub/models--org--a", hard: false, scan: nil) }
        let id = "hfrepo:~/.cache/huggingface/hub/models--org--a"
        let preview = c.clean(id, hard: false, dry: true, scan: nil)
        f.text(a + "/metadata", "new revision")
        T.expect(!c.clean(id, hard: false, dry: false, scan: nil, reviewed: preview.preview).ok)
        T.expect(lexists(a) && lexists(hub + "/blobs/aa/only-a"))
        // after a is removed, the blob both used belongs to b alone
        _ = c.clean("hfrepo:~/.cache/huggingface/hub/models--org--a", hard: false, dry: false, scan: nil)
        T.expect(!lexists(a) && !lexists(hub + "/blobs/aa/only-a"), "repo and its own blob are gone")
        T.expect(lexists(hub + "/blobs/cc/both") && lexists(hub + "/blobs/bb/only-b") && lexists(b), "everything b needs is still there")
        T.equal(Set(try c.resolve("hfrepo:~/.cache/huggingface/hub/models--org--b", hard: false, scan: nil).map { "\($0)" }),
                Set([b, hub + "/blobs/bb/only-b", hub + "/blobs/cc/both"].map { "\(Step.delete($0))" }))
    }

    T.test("a Hugging Face hub reached through a symlink is refused") {
        let f = Fixture()
        f.dir("real-hub/models--org--a")
        f.dir(".cache/huggingface")
        f.link(".cache/huggingface/hub", to: f.home + "/real-hub")
        T.refused("not a Hugging Face cache") { try Cleaner(env: f.env).resolve("hfrepo:~/.cache/huggingface/hub/models--org--a", hard: false, scan: nil) }
    }
}

// MARK: - Cleaning

func cleaning() {
    T.test("a dry run changes nothing; a real run deletes, trashes and logs") {
        let f = Fixture()
        let c = Cleaner(env: f.env)
        f.file("Documents/a.bin", size: 50_000)
        f.file("proj/node_modules/pkg/index.js", size: 50_000)
        let dry = c.clean("file:~/Documents/a.bin", hard: false, dry: true, scan: nil)
        T.expect(dry.ok && dry.summary == "Moves 1 item to the Trash", dry.summary)
        T.expect(f.exists("Documents/a.bin"), "dry run left the file")
        T.expect(!lexists(f.env.logPath), "dry run wrote no log")
        let moved = c.clean("file:~/Documents/a.bin", hard: false, dry: false, scan: nil)
        T.expect(moved.ok && moved.trashed == 1 && !f.exists("Documents/a.bin"))
        T.equal(f.trashed, [f.home + "/Documents/a.bin"])
        let gone = c.clean("file:~/proj/node_modules", hard: false, dry: false, scan: nil)
        T.expect(gone.ok && gone.trashed == 0 && !f.exists("proj/node_modules") && f.exists("proj"), gone.summary)
        let again = c.clean("file:~/Documents/a.bin", hard: false, dry: false, scan: nil)
        T.expect(!again.ok && again.errors.first?.contains("already gone") == true)
        let log = (try? String(contentsOfFile: f.env.logPath, encoding: .utf8)) ?? ""
        T.equal(log.split(separator: "\n").count, 2, "one log line per action carried out")
        T.expect(log.contains("\"id\":\"file:~\\/Documents\\/a.bin\"") || log.contains("file:~/Documents/a.bin"))
    }

    T.test("a refused id deletes nothing") {
        let f = Fixture()
        f.file("Documents/keep.txt")
        let r = Cleaner(env: f.env).clean("file:~/Documents", hard: true, dry: false, scan: nil)
        T.expect(!r.ok && !r.errors.isEmpty && f.exists("Documents/keep.txt"))
    }

    T.test("remove deletes a symlink, not what it points at") {
        let f = Fixture()
        f.file("real/data.bin")
        f.link("links/alias", to: f.home + "/real")
        f.link("links/sub/alias", to: f.home + "/real")
        try Cleaner.remove(f.home + "/links/alias")
        T.expect(!f.exists("links/alias") && f.exists("real/data.bin"))
        let r = Cleaner(env: f.env).clean("file:~/links/sub", hard: true, dry: false, scan: nil)
        T.expect(r.ok && !f.exists("links/sub") && f.exists("real/data.bin"), "a folder holding a link goes; the link's target stays")
    }

    T.test("commands report their output, failures and missing tools") {
        let c = Cleaner(env: Fixture().env)
        T.equal(try c.runCommand("echo hello"), "hello")
        do { _ = try c.runCommand("echo nope; exit 3"); T.fail("should throw") } catch { T.expect(error.localizedDescription.contains("nope")) }
        do { _ = try c.runCommand("headroom-no-such-tool-xyz"); T.fail("should throw") } catch { T.expect(error.localizedDescription.contains("not installed")) }
    }

    T.test("summaries say what will happen") {
        T.equal(Cleaner.summarise([]), "Nothing left to remove")
        T.equal(Cleaner.summarise([.run("brew cleanup")]), "Runs: brew cleanup")
        T.equal(Cleaner.summarise([.delete("/a"), .delete("/b"), .trash("/c")]), "Deletes 2 items for good and Moves 1 item to the Trash")
    }

    T.test("looking inside a folder lists it live and stays in the home folder") {
        let f = Fixture()
        let c = Cleaner(env: f.env)
        f.file("Downloads/big.iso", size: 300_000)
        f.file("Downloads/folder/a.bin", size: 100_000)
        f.file("Downloads/folder/b.bin", size: 100_000)
        f.link("Downloads/alias", to: "/etc")
        let l = try c.list("~/Downloads")
        T.equal(l.entries.map(\.name), ["big.iso", "folder", "alias"])
        T.equal(l.entries[1].files, 2)
        T.equal(l.entries[1].bytes, f.allocated("Downloads/folder/a.bin") * 2)
        T.expect(l.entries[2].link && l.entries[2].bytes == 0, "a link is listed, not followed")
        T.refused("only looks inside your home") { try c.list("/usr") }
        T.refused("only looks inside your home") { try c.list(f.root) }
        T.refused("not a folder") { try c.list("~/Downloads/big.iso") }
        T.refused("not a folder") { try c.list("~/Downloads/alias") }
        T.refused("not a folder") { try c.list("~/Downloads/../Downloads") }
    }
}

// MARK: - Reader

func reading() {
    T.test("readDir agrees with lstat and leaves links out") {
        let f = Fixture()
        f.file("d/one.bin", size: 70_000)
        f.file("d/two.txt", size: 10)
        f.dir("d/sub")
        f.link("d/alias", to: "/etc")
        f.link("d/filealias", to: f.home + "/d/one.bin")
        let entries = try Reader.readDir(f.home + "/d").sorted { $0.name < $1.name }
        T.equal(entries.map(\.name), ["one.bin", "sub", "two.txt"])
        for e in entries {
            let st = lstatOf(f.home + "/d/" + e.name)!
            T.equal(e.isDir, st.isDir, e.name)
            T.equal(e.id, UInt64(st.st_ino), e.name)
            if !e.isDir {
                T.equal(e.bytes, st.allocated, e.name)
                T.equal(e.length, Int64(st.st_size), e.name)
                T.equal(e.mtime, Int64(st.st_mtimespec.tv_sec), e.name)
                T.equal(e.links, UInt32(st.st_nlink), e.name)
            }
        }
        do { _ = try Reader.readDir(f.home + "/missing"); T.fail("should throw") } catch { T.expect(true) }
    }

    T.test("measure counts clone-shared space only when every copy is inside") {
        let f = Fixture()
        f.file("c/a/model.bin", size: 400_000, fill: 7)
        f.clone("c/b/model.bin", of: "c/a/model.bin")
        f.file("c/a/own.bin", size: 100_000, fill: 9)
        let size = f.allocated("c/a/model.bin"), own = f.allocated("c/a/own.bin")
        let whole = Reader.measure(f.home + "/c")
        T.equal(whole.bytes, size * 2 + own, "on disk counts each copy")
        T.equal(whole.returns, size + own, "deleting both copies returns the shared blocks once")
        T.equal(whole.files, 3)
        let part = Reader.measure(f.home + "/c/a")
        T.equal(part.bytes, size + own)
        T.equal(part.returns, own, "the other copy keeps the shared blocks alive")
        T.expect(Reader.measure(f.home + "/c", deadline: Date().addingTimeInterval(-1)).partial, "a passed deadline is reported")
        T.equal(Reader.privateBytes(f.home + "/c/a/own.bin"), own, "a file that shares nothing returns its whole size")
        T.equal(Reader.privateBytes(f.home + "/c/a/model.bin"), 0, "a pure clone returns nothing on its own")
        T.expect(Reader.privateBytes(f.home + "/c/missing.bin") == nil)
    }

    T.test("extension, glob and helper functions") {
        T.equal(Scanner.ext(of: "a.TXT"), "txt")
        T.equal(Scanner.ext(of: ".bashrc"), "")
        T.equal(Scanner.ext(of: "noext"), "")
        T.equal(Scanner.ext(of: "archive.tar.gz"), "gz")
        T.equal(Scanner.ext(of: "x.averyveryverylongextension"), "")
        T.equal(Scanner.ext(of: "trailing."), "")
        let f = Fixture()
        for p in ["r/hub/m1/x", "r/hub/m2/x", "r/hub/.hidden/x", "r/other/y"] { f.file(p) }
        T.equal(Report.glob(f.home + "/r", "hub/*").sorted(), [f.home + "/r/hub/m1", f.home + "/r/hub/m2"])
        T.equal(Report.glob(f.home + "/r", "*/*").count, 3)
        T.equal(Report.glob(f.home + "/r", "nothing/*"), [])
        T.equal(parentPath("/a/b"), "/a")
        T.equal(parentPath("/a"), "/")
        T.equal(lastComponent("/a/b.c"), "b.c")
        T.equal(f.env.disp(f.home + "/x"), "~/x")
        T.equal(f.env.disp(f.home), "~")
        T.equal(f.env.disp(f.home + "x"), f.home + "x")
        T.equal(f.env.expand("~/x"), f.home + "/x")
        T.equal(f.env.expand("/abs"), "/abs")
    }
}

// MARK: - Scanner

func scanning() {
    T.test("totals count every file once: hard links, links and bundles included") {
        let f = Fixture()
        f.file("Documents/a.bin", size: 300_000)
        f.file("Documents/deep/b.bin", size: 200_000)
        f.hardLink("Documents/deep/a-again.bin", to: "Documents/a.bin")
        try FileManager.default.createDirectory(atPath: f.root + "/outside", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: f.root + "/outside/huge.bin", contents: Data(repeating: 1, count: 900_000))
        f.link("Documents/outside", to: f.root + "/outside")
        f.file("Applications/Tool.app/Contents/MacOS/tool", size: 250_000)
        let a = f.allocated("Documents/a.bin"), b = f.allocated("Documents/deep/b.bin"), tool = f.allocated("Applications/Tool.app/Contents/MacOS/tool")
        let core = Scanner.walk(f.options(), env: f.env, progress: ScanProgress())!
        T.equal(core.total, a + b + tool, "the hard link and the linked folder add nothing")
        T.equal(core.files, 3)
        T.equal(core.unique, core.total, "no clones here")
        T.equal(core.sizes[f.home + "/Documents"], a + b)
        let apps = core.tree.children.first { $0.n == "Applications" }
        let bundle = apps?.children.first { $0.n == "Tool.app" }
        T.equal(bundle?.s, tool)
        T.expect(bundle?.o == 1 && bundle?.c == nil, "an app bundle is one block; its insides are not shown")
        T.expect(!core.big.contains { $0.path.contains("outside") }, "nothing reached through the link")
    }

    T.test("the same tree gives the same answer on one thread and on many") {
        let f = Fixture()
        for i in 0..<40 { f.file("data/d\(i % 7)/sub\(i % 3)/f\(i).bin", size: 20_000 + i * 1_000, fill: UInt8(i)) }
        f.clone("data/copy.bin", of: "data/d0/sub0/f0.bin")
        let one = Scanner.walk(f.options(threads: 1), env: f.env, progress: ScanProgress())!
        let many = Scanner.walk(f.options(threads: 8), env: f.env, progress: ScanProgress())!
        T.equal(one.total, many.total)
        T.equal(one.unique, many.unique)
        T.equal(one.files, many.files)
        T.equal(one.dirs, many.dirs)
        T.equal(one.sizes, many.sizes)
        T.equal(one.privs, many.privs)
        func flat(_ n: Node) -> [String] { ["\(n.n):\(n.s):\(n.r ?? -1)"] + n.children.flatMap(flat) }
        T.equal(flat(one.tree), flat(many.tree))
    }

    T.test("clone-shared space is credited to the deepest folder holding every copy") {
        let f = Fixture()
        f.file("c/a/model.bin", size: 400_000, fill: 3)
        f.clone("c/b/model.bin", of: "c/a/model.bin")
        f.file("c/b/other.bin", size: 150_000, fill: 4)
        f.file("d/plain.bin", size: 150_000, fill: 5)
        let size = f.allocated("c/a/model.bin"), other = f.allocated("c/b/other.bin"), plain = f.allocated("d/plain.bin")
        let core = Scanner.walk(f.options(), env: f.env, progress: ScanProgress())!
        T.equal(core.total, size * 2 + other + plain)
        T.equal(core.unique, size + other + plain, "the disk really holds one copy")
        T.equal(core.frees(f.home + "/c"), size + other, "both copies live under c")
        T.equal(core.frees(f.home + "/c/a"), 0, "a alone returns nothing: b still holds the blocks")
        T.equal(core.frees(f.home + "/c/b"), other)
        T.equal(core.frees(f.home + "/d"), plain)
        T.expect(core.frees(f.home + "/nope") == nil)
        let c = core.tree.children.first { $0.n == "c" }!
        T.equal(c.returns, size + other)
        T.equal(c.children.first { $0.n == "a" }?.r, 0)
    }

    T.test("project folders are tagged only in the user's own, visible folders") {
        let f = Fixture()
        f.file("proj/node_modules/pkg/i.js", size: 30_000)
        f.file("proj/node_modules/pkg/node_modules/inner/i.js", size: 30_000)
        f.file("proj/.venv/lib/x.py", size: 30_000)
        f.text("proj/.venv/pyvenv.cfg", "home = /usr")
        f.file("proj/venv/not-a-venv.txt", size: 30_000)
        f.file("rust/target/debug/bin", size: 30_000)
        f.text("rust/Cargo.toml", "[package]")
        f.file("notrust/target/x", size: 30_000)
        f.file("proj/.git/objects/pack", size: 30_000)
        f.file("proj/__pycache__/m.pyc", size: 30_000)
        f.file("Library/Thing/node_modules/x.js", size: 30_000)
        f.file(".hidden/node_modules/x.js", size: 30_000)
        let core = Scanner.walk(f.options(), env: f.env, progress: ScanProgress())!
        let tags = Dictionary(grouping: core.found, by: \.tag).mapValues { $0.map { f.env.disp($0.path) }.sorted() }
        T.equal(tags["node_modules"], ["~/proj/node_modules"], "nested and Library/hidden ones are not listed")
        T.equal(tags["venv"], ["~/proj/.venv"], "needs pyvenv.cfg")
        T.equal(tags["rust-target"], ["~/rust/target"], "needs Cargo.toml beside it")
        T.equal(tags["git"], ["~/proj/.git"])
        T.equal(tags["pycache"], ["~/proj/__pycache__"])
        T.equal(core.tagTotals["node_modules"]?.count, 1)
        T.equal(core.found.first { $0.tag == "node_modules" }?.files, 2, "the nested one is counted inside its parent")
    }

    T.test("a folder that cannot be opened is reported, not guessed at") {
        let f = Fixture()
        f.file("open/a.bin", size: 50_000)
        f.file("locked/secret.bin", size: 50_000)
        chmod(f.home + "/locked", 0)
        defer { chmod(f.home + "/locked", 0o755) }
        let core = Scanner.walk(f.options(), env: f.env, progress: ScanProgress())!
        T.equal(core.denied, [f.home + "/locked"])
        T.equal(core.total, f.allocated("open/a.bin"))
    }

    T.test("a cancelled scan returns nothing") {
        let f = Fixture()
        f.file("a/b.bin")
        let p = ScanProgress()
        p.cancel()
        T.expect(Scanner.walk(f.options(), env: f.env, progress: p) == nil)
        T.expect(try Report.run(f.options(), env: f.env, progress: p, write: true) == nil)
        T.expect(!lexists(f.env.scanPath), "nothing is written for a cancelled scan")
    }

    T.test("progress counts the files it has measured") {
        let f = Fixture()
        for i in 0..<25 { f.file("many/f\(i).bin", size: 100) }
        let p = ScanProgress()
        _ = Scanner.walk(f.options(), env: f.env, progress: p)
        T.equal(p.snapshot.files, 25)
    }
}

// MARK: - Reports

func reports() {
    T.test("a full scan finds rules, items, caches, downloads, big files and duplicates") {
        let f = Fixture()
        f.file(".cache/uv/archive/wheel.bin", size: 700_000)
        f.file("Library/Caches/com.example.big/data.bin", size: 1_700_000)
        f.file("Library/Caches/com.example.small/data.bin", size: 150_000)
        f.file("Library/Caches/com.example.tiny/data.bin", size: 120_000)
        f.file("Library/Developer/Xcode/DerivedData/AppOne-abc/Build/x.o", size: 400_000)
        f.file("Library/Developer/Xcode/DerivedData/AppTwo-def/Build/x.o", size: 250_000)
        f.file("Library/Developer/Xcode/DerivedData/Tiny-ghi/x.o", size: 5_000)
        f.file("Downloads/installer.dmg", size: 300_000)
        f.file("Downloads/folder/video.mp4", size: 200_000)
        f.file("Downloads/small.txt", size: 100)
        f.file("Documents/movie.mov", size: 1_200_000, fill: 1)
        f.file("Documents/copy/movie-copy.mov", size: 1_200_000, fill: 1)
        f.file("Documents/different.mov", size: 1_200_000, fill: 2)
        f.file("proj/node_modules/pkg/i.js", size: 80_000)
        f.text("proj/readme.md", "hi")
        let scan = f.scan()
        let rules = Dictionary(uniqueKeysWithValues: scan.rules.map { ($0.id, $0) })
        T.equal(rules["uv"]?.cmd, "uv cache clean")
        T.equal(rules["uv"]?.paths, ["~/.cache/uv"])
        T.equal(rules["uv"]?.bytes, f.allocated(".cache/uv/archive/wheel.bin"))
        T.expect(rules["cache:~/Library/Caches/com.example.big"] != nil, "a large cache folder gets its own rule")
        T.equal(rules["cache-rest:~/Library/Caches"]?.paths.sorted(), ["~/Library/Caches/com.example.small", "~/Library/Caches/com.example.tiny"])
        let derived = rules["derived"]
        T.equal(derived?.items?.map(\.name), ["AppOne-abc", "AppTwo-def"], "largest first, small ones folded into the rest")
        T.equal(derived?.itemsRest?.count, 1)
        T.equal(derived?.items?.first?.id, "file:~/Library/Developer/Xcode/DerivedData/AppOne-abc")
        T.equal(derived?.items?.first?.dir, true)
        T.expect(rules["gradle"] == nil, "rules with nothing on disk are left out")
        T.equal(scan.rules.map(\.returns), scan.rules.map(\.returns).sorted(by: >), "rules are sorted by what they return")
        T.equal(scan.downloads?.map(\.name), ["installer.dmg", "folder"])
        T.equal(scan.downloads?.last?.dir, true)
        T.equal(scan.bigFiles?.map { lastComponent($0.path) }.sorted(), ["data.bin", "different.mov", "movie-copy.mov", "movie.mov"])
        T.equal(scan.bigFiles?.first { $0.path.hasSuffix("movie.mov") }?.kind, "Video")
        T.equal(scan.dupes?.count, 1, "same length and same samples, different content excluded")
        T.equal(scan.dupes?.first?.files.map(\.path).sorted(), ["~/Documents/copy/movie-copy.mov", "~/Documents/movie.mov"])
        T.equal(scan.found?.map(\.path), ["~/proj/node_modules"])
        T.expect((scan.found?.first?.projectMtime ?? 0) > 1_600_000_000, "the project's own files give its age")
        T.equal(scan.root, "~")
        T.equal(scan.tree.n, "~")
        T.equal(scan.stats.files, 15)
        T.equal(scan.kinds.first { $0.kind == "Video" }?.files, 4)
        T.expect(!scan.rules.contains { $0.paths.contains { $0.hasPrefix(f.home) } }, "no absolute home path leaks into the scan")
    }

    T.test("the scan round-trips through scan.json unchanged") {
        let f = Fixture()
        f.file("Documents/a.bin", size: 400_000)
        f.file(".cache/uv/x.bin", size: 700_000)
        _ = f.app("Sample", id: "com.example.sample")
        f.file("Library/Caches/com.example.sample/c.bin", size: 50_000)
        let scan = f.scan(write: true)
        let back = Report.loadScan(f.env.scanPath)
        T.expect(back != nil, "scan.json decodes")
        T.equal(back?.rules.map(\.id), scan.rules.map(\.id))
        T.equal(back?.tree.children.map(\.n), scan.tree.children.map(\.n))
        T.equal(back?.disk.scanned, scan.disk.scanned)
        T.equal(back?.apps?.first?.leftovers?.map(\.path), ["~/Library/Caches/com.example.sample"])
        T.equal(back?.apps?.first?.bundleId, "com.example.sample")
        let raw = (try? String(contentsOfFile: f.env.scanPath, encoding: .utf8)) ?? ""
        T.expect(!raw.contains(f.home), "scan.json holds no absolute home path")
    }

    T.test("Hugging Face items carry their own blobs and flag leftovers") {
        let f = Fixture()
        let hub = ".cache/huggingface/hub"
        f.file(hub + "/blobs/aa/big", size: 600_000, fill: 1)
        f.file(hub + "/blobs/bb/shared", size: 200_000, fill: 2)
        f.file(hub + "/blobs/cc/orphan", size: 300_000, fill: 3)
        f.link(hub + "/models--org--alpha/snapshots/r/w.bin", to: f.home + "/" + hub + "/blobs/aa/big")
        f.link(hub + "/models--org--alpha/snapshots/r/t.json", to: f.home + "/" + hub + "/blobs/bb/shared")
        f.link(hub + "/datasets--org--beta/snapshots/r/t.json", to: f.home + "/" + hub + "/blobs/bb/shared")
        let hf = f.scan().rules.first { $0.id == "hf" }
        T.equal(hf?.perm, true)
        let items = Dictionary(uniqueKeysWithValues: (hf?.items ?? []).map { ($0.id, $0) })
        let alpha = items["hfrepo:~/.cache/huggingface/hub/models--org--alpha"]
        T.equal(alpha?.name, "org/alpha")
        T.equal(alpha?.kind, "Model")
        T.equal(alpha?.bytes, f.allocated(hub + "/blobs/aa/big"), "only the blob nothing else uses")
        let orphans = items["hforphans:~/.cache/huggingface/hub"]
        T.equal(orphans?.bytes, f.allocated(hub + "/blobs/cc/orphan"))
        T.equal(orphans?.flag, "leftover")
        T.expect(items["hfrepo:~/.cache/huggingface/hub/datasets--org--beta"] == nil, "a repo with nothing of its own falls under the size floor")
        T.equal(hf?.itemsRest?.count, 1)
    }

    T.test("superseded VS Code extensions are pointed out") {
        let f = Fixture()
        for v in ["pub.tool-1.2.0", "pub.tool-1.10.0", "pub.other-0.1.0", "pub.marked-2.0.0"] { f.file(".vscode/extensions/\(v)/ext.js", size: 150_000) }
        f.text(".vscode/extensions/.obsolete", "{\"pub.marked-2.0.0\": true}")
        let items = Dictionary(uniqueKeysWithValues: (f.scan().rules.first { $0.id == "vscode-ext" }?.items ?? []).map { ($0.name, $0) })
        T.equal(items["pub.tool-1.2.0"]?.flag, "leftover")
        T.equal(items["pub.tool-1.2.0"]?.note, "Superseded: version 1.10.0 is installed.")
        T.expect(items["pub.tool-1.10.0"]?.flag == nil, "1.10 is newer than 1.2")
        T.expect(items["pub.other-0.1.0"]?.flag == nil)
        T.equal(items["pub.marked-2.0.0"]?.note, "VS Code has marked this version for removal.")
    }

    T.test("apps list their leftovers with sizes") {
        let f = Fixture()
        _ = f.app("Sample", id: "com.example.sample")
        f.file("Library/Application Support/Sample/db.sqlite", size: 1_400_000)
        f.text("Library/Preferences/com.example.sample.plist", "<plist/>")
        let app = f.scan().apps?.first { $0.name == "Sample" }
        T.equal(app?.path, "~/Applications/Sample.app")
        T.equal(app?.leftovers?.map(\.path), ["~/Library/Application Support/Sample", "~/Library/Preferences/com.example.sample.plist"])
        T.equal(app?.leftovers?.first?.bytes, f.allocated("Library/Application Support/Sample/db.sqlite"))
    }
}

// MARK: - Changes and history

func changes() {
    func n(_ name: String, _ gb: Double, _ kids: [Node] = [], home: Bool = false, r: Double? = nil) -> Node {
        let node = Node(n: name, s: Int64(gb * 1e9), r: r.map { Int64($0 * 1e9) })
        if !kids.isEmpty { node.c = kids }
        if home { node.h = 1 }
        return node
    }

    T.test("the diff names the deepest folders that explain a change") {
        let old = n("Macintosh HD", 100, [n("Users", 60, [n("~", 60, [n("Documents", 20, [n("Codex", 10, [n("a", 6), n("b", 4)])]),
                                                                   n("Library", 30, [n("Caches", 8)]), n("old", 5)], home: true)]), n("private", 10)])
        let new = n("Macintosh HD", 113, [n("Users", 72, [n("~", 72, [n("Documents", 31, [n("Codex", 21, [n("a", 6), n("b", 4), n("c", 9, [n("deep", 9)])])]),
                                                                   n("Library", 27.5, [n("Caches", 5.5)]), n("fresh", 3)], home: true)]), n("private", 11)])
        let items = Report.diffTrees(old: old, new: new, root: "/")
        let byPath = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0) })
        T.equal(items.map(\.path), ["~/Documents/Codex/c", "~/old", "~/fresh", "~/Library/Caches", "/private"], "largest change first")
        T.equal(byPath["~/Documents/Codex/c"]?.new, true)
        T.equal(byPath["~/old"]?.gone, true)
        T.equal(byPath["~/old"]?.delta, -5_000_000_000)
        T.equal(byPath["~/Library/Caches"]?.delta, -2_500_000_000)
        T.expect(byPath["~/Documents"] == nil && byPath["~"] == nil, "parents are not repeated")
    }

    T.test("a new clone of something already on disk is not growth") {
        let old = n("~", 50, [n("app", 40), n("data", 10)])
        let new = n("~", 90, [n("app", 40), n("data", 10), n("app-copy", 40, r: 0.1)], r: 50.1)
        T.equal(Report.diffTrees(old: old, new: new, root: "~").map(\.path), [], "40 GB on disk, 0.1 GB of real growth")
    }

    T.test("identical trees and small changes report nothing") {
        let a = n("~", 50, [n("x", 30), n("y", 20)])
        T.equal(Report.diffTrees(old: a, new: n("~", 50.1, [n("x", 30.1), n("y", 20)]), root: "~").count, 0)
        T.equal(Report.diffTrees(old: a, new: a, root: "~").count, 0)
    }

    T.test("a second scan records what changed since the first") {
        let f = Fixture()
        f.file("Documents/steady.bin", size: 400_000)
        f.file("Documents/going.bin", size: 300_000)
        _ = f.scan(write: true)
        f.file("Projects/new/large.bin", size: 900_000)
        try FileManager.default.removeItem(atPath: f.home + "/Documents/going.bin")
        let second = f.scan(write: true)
        T.expect(second.changes != nil, "the earlier scan was found")
        T.equal(second.changes?.items.first?.path, "~/Projects")
        T.equal(second.changes?.items.first?.new, true)
        T.expect((second.changes?.items.first?.delta ?? 0) > 800_000)
        T.expect(second.changes?.items.contains { $0.path == "~/Documents" && $0.delta < 0 } == true, "the shrink is reported too")
    }

    T.test("history survives damage and never writes through a link") {
        let f = Fixture()
        Report.addHistory(f.env, Sample(t: 100, free: 5, total: 10, scan: 1))
        Report.addHistory(f.env, Sample(t: 200, free: 4, total: 10))
        T.equal(Report.readHistory(f.env).map(\.t), [100, 200])
        T.equal(Report.addHistory(f.env, Sample(t: 250, free: 3), minGap: 100).count, 2, "too soon after the last reading")
        T.equal(Report.addHistory(f.env, Sample(t: 400, free: 3), minGap: 100).count, 3)
        try "[null, 7, {\"t\": 5, \"free\": 9}, {\"free\": 1}, \"x\"]".write(toFile: f.env.historyPath, atomically: true, encoding: .utf8)
        T.equal(Report.readHistory(f.env).map(\.t), [5], "malformed readings are dropped")
        try "not json".write(toFile: f.env.historyPath, atomically: true, encoding: .utf8)
        T.equal(Report.readHistory(f.env).count, 0)
        f.text("victim.txt", "precious")
        symlink(f.home + "/victim.txt", f.env.historyPath + ".tmp")
        Report.addHistory(f.env, Sample(t: 500, free: 1))
        T.equal(try String(contentsOfFile: f.home + "/victim.txt", encoding: .utf8), "precious", "the link target is untouched")
    }
}

// MARK: - Cross-check with the Python scanner

enum CrossCheck {
    /// A fixture big enough for the scanners' real thresholds (50 MB rules, 50 MB big files).
    static func make(home: String, support: String) {
        let f = Fixture(at: parentPath(home))
        let mb = 1_000_000
        f.file(".cache/uv/archive/wheels.bin", size: 60 * mb, fill: 1)
        f.file("Library/Caches/com.example.big/data.bin", size: 160 * mb, fill: 2)
        f.file("Library/Caches/com.example.small/data.bin", size: 15 * mb, fill: 3)
        f.file("Library/Caches/com.example.tiny/data.bin", size: 9 * mb, fill: 4)
        f.file("Library/Developer/Xcode/DerivedData/AppOne-abc/Build/x.o", size: 40 * mb, fill: 5)
        f.file("Library/Developer/Xcode/DerivedData/AppTwo-def/Build/x.o", size: 15 * mb, fill: 6)
        f.file("Library/Developer/Xcode/DerivedData/Tiny-ghi/x.o", size: 2 * mb, fill: 7)
        let hub = ".cache/huggingface/hub"
        f.file(hub + "/blobs/aa/big", size: 30 * mb, fill: 8)
        f.file(hub + "/blobs/bb/shared", size: 12 * mb, fill: 9)
        f.file(hub + "/blobs/cc/orphan", size: 14 * mb, fill: 10)
        f.link(hub + "/models--org--alpha/snapshots/r/w.bin", to: f.home + "/" + hub + "/blobs/aa/big")
        f.link(hub + "/models--org--alpha/snapshots/r/t.json", to: f.home + "/" + hub + "/blobs/bb/shared")
        f.link(hub + "/datasets--org--beta/snapshots/r/t.json", to: f.home + "/" + hub + "/blobs/bb/shared")
        for v in ["pub.tool-1.2.0", "pub.tool-1.10.0", "pub.other-0.1.0"] { f.file(".vscode/extensions/\(v)/ext.js", size: 20 * mb, fill: 11) }
        f.file("Downloads/installer.dmg", size: 8 * mb, fill: 12)
        f.file("Downloads/folder/video.mp4", size: 6 * mb, fill: 13)
        f.file("Downloads/small.txt", size: 100)
        f.file("Documents/movie.mov", size: 55 * mb, fill: 14)
        f.file("Documents/copy/movie-copy.mov", size: 55 * mb, fill: 14)
        f.file("Documents/different.mov", size: 55 * mb, fill: 15)
        f.file("Documents/model.safetensors", size: 210 * mb, fill: 16)
        f.clone("Documents/clones/model-clone.safetensors", of: "Documents/model.safetensors")
        f.clone("Elsewhere/model-clone-2.safetensors", of: "Documents/model.safetensors")
        f.file("proj/node_modules/pkg/i.js", size: 25 * mb, fill: 17)
        f.file("proj/node_modules/pkg/node_modules/inner/i.js", size: 1 * mb, fill: 18)
        f.file("proj/.venv/lib/x.so", size: 22 * mb, fill: 19)
        f.text("proj/.venv/pyvenv.cfg", "home = /usr")
        f.file("proj/.git/objects/pack/p.pack", size: 21 * mb, fill: 20)
        f.file("proj/src/__pycache__/m.pyc", size: 1 * mb, fill: 21)
        f.text("proj/readme.md", "hi")
        f.file("rust/target/debug/bin", size: 30 * mb, fill: 22)
        f.text("rust/Cargo.toml", "[package]")
        f.file("Library/Thing/node_modules/x.js", size: 21 * mb, fill: 23)
        f.hardLink("Documents/linked/movie-link.mov", to: "Documents/different.mov")
        f.link("Documents/etc", to: "/etc")
        f.file("Movies/Clip.fcpbundle/media.mov", size: 70 * mb, fill: 24)
        _ = f.app("Sample", id: "com.example.sample")
        f.file("Library/Application Support/Sample/db.sqlite", size: 3 * mb, fill: 25)
        f.text("Library/Preferences/com.example.sample.plist", "<plist/>")
        _ = Unmanaged.passRetained(f)       // keep the fixture on disk for the other scanner
        print("fixture ready at \(f.home)")
    }

    static func scan(home: String, support: String) {
        try? FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)
        let env = Env(home: home, support: support, appDirs: ["/Applications", "/Applications/Utilities", home + "/Applications"])
        let started = Date()
        let scan = try! Report.run(ScanOptions(root: home), env: env, progress: ScanProgress())!
        print("swift scan: \(scan.stats.files) files in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
    }
}
