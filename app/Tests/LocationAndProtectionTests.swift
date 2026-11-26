// Exercise arbitrary-volume measurement and policy enforcement in a disposable filesystem.
import Foundation

@MainActor func locationAndProtectionTests() async {
    T.test("location measures small immediate files, folders and nested large files") {
        let f = Fixture()
        let root = f.dir("Film")
        let movie = f.file("Film/Footage/interview.mov", size: 9_000_000)
        let music = f.file("Film/Audio/room.wav", size: 3_000_000)
        let note = f.text("Film/Notes.txt", "notes\n")
        guard let r = try LocationReport.measure(root, progress: ScanProgress()) else { return T.fail("cancelled") }
        T.equal(r.path, root)
        T.equal(r.entries.map(\.name), ["Footage", "Audio", "Notes.txt"])
        T.equal(r.largest.map(\.path), [movie, music])
        T.equal(r.files, 3)
        T.equal(r.bytes, [movie, music, note].reduce(0) { $0 + Int64(lstatOf($1)!.st_blocks) * 512 })
        T.expect(r.available > 0 && r.denied.isEmpty)
        T.expect(!lexists(f.env.scanPath) && !lexists(f.env.historyPath))
    }
    T.test("location keeps empty folders, ignores symlinks and package interiors in largest files") {
        let f = Fixture(), root = f.dir("Review")
        f.dir("Review/Empty")
        f.file("Review/Studio.app/Contents/movie", size: 2_000_000)
        f.link("Review/Alias", to: f.dir("Other"))
        guard let r = try LocationReport.measure(root, progress: ScanProgress()) else { return T.fail("unexpected cancellation") }
        T.equal(Set(r.entries.map(\.name)), ["Studio.app", "Empty"])
        T.expect(r.largest.isEmpty)
        T.expect(r.bytes >= 2_000_000)
        let cancelled = ScanProgress()
        cancelled.cancel()
        T.expect(try LocationReport.measure(root, progress: cancelled) == nil)
        do { _ = try LocationReport.measure(f.path("missing"), progress: ScanProgress()); T.fail("missing folder accepted") }
        catch is EngineError { T.expect(true) }
    }
    await T.asyncTest("location navigation cancels superseded work and isolates measurements from the disk report") {
        let f = Fixture(), suite = "local.headroom.location." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let m = AppModel(engine: Engine(env: f.env), defaults: defaults)
        let first = f.dir("First"), second = f.dir("Second"), child = f.dir("Second/Child")
        f.file("Second/Child/sample", size: 8192)
        let x = m.explorer
        @MainActor func settle() async throws {
            for _ in 0..<500 where x.busy { try await Task.sleep(for: .milliseconds(10)) }
            T.expect(!x.busy && x.error == nil)
        }
        x.open(first)
        x.open(second)
        try await settle()
        T.equal(x.trail, [second])
        let before = x.report?.bytes
        x.open(child, drill: true)
        try await settle()
        T.equal(x.trail, [second, child])
        f.file("Second/more", size: 8192)
        x.back()
        try await settle()
        T.equal(x.report?.path, second)
        if x.report?.identity != nil { T.equal(x.previousBytes, before) }
        T.expect((x.report?.bytes ?? 0) > (before ?? 0))
        x.open(first)
        x.cancel()
        try await Task.sleep(for: .milliseconds(30))
        T.equal(x.report?.path, second)
        T.expect(m.scan == nil && m.plan.isEmpty)
    }
    T.test("protected locations survive relaunch and refuse a previously reviewed ancestor") {
        let f = Fixture(), c = Cleaner(env: f.env), p = ProtectedPaths(env: f.env)
        let file = f.file("Downloads/Kept/book"), dir = f.path("Downloads/Kept")
        let sibling = f.file("Downloads/Kept-copy")
        let id = "file:" + dir
        let review = c.clean(id, hard: false, dry: true, scan: nil)
        T.expect(review.ok)
        f.link("shortcut", to: file)
        T.equal(try p.change(f.path("shortcut"), add: true), [file])
        T.equal(try ProtectedPaths(env: f.env).read(), [file])
        let refused = c.clean(id, hard: false, dry: false, scan: nil, reviewed: review.preview)
        T.expect(!refused.ok && refused.errors.joined().contains("protected location"))
        T.expect(lexists(file) && f.trashed.isEmpty)
        T.refused("protected location") { try p.validate([.delete(file.uppercased())], paths: p.read()) }
        try p.validate([.trash(sibling)], paths: p.read())
        T.refused("chooses its own") { try p.validate([.run("brew cleanup")], paths: p.read()) }
        T.equal(try p.change(file, add: false), [])
        T.expect(c.clean(id, hard: false, dry: true, scan: nil).ok)
        T.refused("protected location") { try p.validate([.trash(f.env.support)], paths: []) }
    }
    T.test("active cleanup prevents another instance from changing protection mid-operation") {
        let f = Fixture(), target = f.file("Downloads/Film")
        let p = ProtectedPaths(env: f.env)
        var observedBusy = false
        f.env.trasher = { path in
            do { _ = try ProtectedPaths(env: f.env).change(path, add: true) }
            catch { observedBusy = error.localizedDescription.contains("busy") }
        }
        let r = Cleaner(env: f.env).clean("file:" + target, hard: false, dry: false, scan: nil)
        T.expect(r.ok && observedBusy)
        T.equal(try p.read(), [])
        T.equal(try p.change(target, add: true), [target])
    }
    T.test("hard-link names stay visible and bytes have a deterministic owner") {
        let f = Fixture(), root = f.dir("Links")
        let file = f.file("Links/A.app/Media/clip.mov", size: 2_000_000)
        f.hardLink("Links/B/clip.mov", to: file)
        f.hardLink("Links/First.mov", to: file)
        f.hardLink("Links/Second.mov", to: file)
        guard let r = try LocationReport.measure(root, progress: ScanProgress()) else { return T.fail("cancelled") }
        T.equal(r.files, 1)
        T.equal(Set(r.entries.map(\.name)), ["A.app", "B", "First.mov", "Second.mov"])
        T.equal(r.entries.first?.name, "First.mov")
        T.equal(r.entries.first?.bytes, r.bytes)
        T.equal(r.largest.map(\.name), ["First.mov"])
        T.expect(r.entries.contains { $0.name == "Second.mov" && $0.note != nil })
        let again = try LocationReport.measure(root, progress: ScanProgress())
        T.equal(again?.entries.map(\.bytes), r.entries.map(\.bytes))
        try FileManager.default.removeItem(atPath: root + "/First.mov")
        try FileManager.default.removeItem(atPath: root + "/Second.mov")
        let nested = try LocationReport.measure(root, progress: ScanProgress())
        T.equal(nested?.largest.map(\.path), [root + "/B/clip.mov"])
    }
    T.test("broken protection files refuse execution before any filesystem changes") {
        let f = Fixture(), file = f.file("Downloads/stay")
        f.text(f.env.protectionPath, "broken")
        let outcome = Cleaner(env: f.env).clean("file:" + file, hard: true, dry: false, scan: nil)
        T.expect(!outcome.ok && outcome.errors.joined().contains("protected locations"))
        T.expect(lexists(file))
        try FileManager.default.removeItem(atPath: f.env.protectionPath)
        f.link(f.env.protectionPath, to: file)
        T.refused("protected locations") { try ProtectedPaths(env: f.env).read() }
    }
    T.test("cleanup history reads mixed logs newest first and records refused and completed actions") {
        let f = Fixture(), c = Cleaner(env: f.env)
        T.equal(try CleanupRecord.recent(f.env.logPath).count, 0)
        let line = #"{"at":"then","id":"old","did":"Trash","ok":true}"#
        f.text(f.env.logPath, String(repeating: line + "\n", count: 205) + "bad line\n")
        let target = f.file("Downloads/book")
        let id = "file:" + target
        T.expect(c.clean(id, hard: false, dry: false, scan: nil, sessionID: "abc", title: "Book").ok)
        T.expect(!c.clean(id, hard: false, dry: false, scan: nil, sessionID: "abc", title: "Book").ok)
        let records = try CleanupRecord.recent(f.env.logPath)
        T.equal(records.count, 200)
        T.equal(records.prefix(2).map(\.session), ["abc", "abc"])
        T.equal(records.prefix(2).map(\.ok), [false, true])
        T.equal(records[1].title, "Book")
        T.equal(records[1].trashed, 1)
        T.equal(records.prefix(2).map(\.completed), [0, 1])
        T.equal(records[2].idString, "old")
        T.equal(Set(records.map(\.id)).count, 200)
        T.expect(records[0].offset > records[1].offset)
    }
    T.test("history uses stable offsets when the one-megabyte tail slides") {
        let f = Fixture()
        let entry = #"{"at":"then","id":"old","did":"Trash","ok":true}"# + "\n"
        let prefix = String(repeating: "x", count: 1_070_000) + "\n"
        f.text(f.env.logPath, prefix + entry)
        let original = try CleanupRecord.recent(f.env.logPath)
        T.equal(original.map(\.offset), [prefix.utf8.count])
        f.text(f.env.logPath, prefix + entry + entry)
        T.equal(try CleanupRecord.recent(f.env.logPath).map(\.offset), [prefix.utf8.count + entry.utf8.count, prefix.utf8.count])
    }
}
