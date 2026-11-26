// A small test harness (the Command Line Tools ship no XCTest) and a throwaway home folder.
// Every test works inside a temp folder; nothing here touches the real home.
import Darwin
import Foundation

enum T {
    static var passed = 0
    static var failed: [String] = []
    static var current = ""
    static var filter: String?

    static func test(_ name: String, _ body: () throws -> Void) {
        if let filter, !name.localizedCaseInsensitiveContains(filter) { return }
        current = name
        let before = failed.count
        do { try body() } catch let r as Refused { fail("threw Refused: \(r.message)") } catch { fail("threw \(error)") }
        print(failed.count == before ? "  ok    \(name)" : "  FAIL  \(name)")
    }

    static func fail(_ message: String, line: UInt = #line) {
        failed.append("\(current): \(message) (line \(line))")
        print("        \(message) (line \(line))")
    }

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String = "expected true", line: UInt = #line) {
        if condition { passed += 1 } else { fail(message(), line: line) }
    }

    static func equal<V: Equatable>(_ got: V, _ want: V, _ what: String = "", line: UInt = #line) {
        if got == want { passed += 1 } else { fail("\(what.isEmpty ? "" : what + ": ")got \(got), want \(want)", line: line) }
    }

    /// Passes when `body` is refused, and the reason mentions `containing`.
    static func refused(_ containing: String = "", line: UInt = #line, _ body: () throws -> Any) {
        do {
            let value = try body()
            fail("expected a refusal, got \(value)", line: line)
        } catch let r as Refused {
            expect(containing.isEmpty || r.message.contains(containing), "refused with \"\(r.message)\", wanted \"\(containing)\"", line: line)
        } catch {
            fail("threw \(error)", line: line)
        }
    }
}

/// A fake Mac: a home folder, an Applications folder and a Trash, all under one temp folder.
final class Fixture {
    let root: String
    let home: String
    let trash: String
    let env: Env
    var trashed: [String] = []

    init(_ label: String = "t", at base: String? = nil) {
        let made = base ?? NSTemporaryDirectory() + "headroom-tests-\(label)-\(getpid())-\(Int.random(in: 0..<1_000_000))"
        try? FileManager.default.createDirectory(atPath: made + "/home", withIntermediateDirectories: true)
        root = realPath(made)!
        home = root + "/home"
        trash = root + "/Trash"
        try? FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: root + "/support", withIntermediateDirectories: true)
        let trashDir = trash
        env = Env(home: home, support: root + "/support", appDirs: [home + "/Applications"], tempBase: nil, ownBundle: nil)
        env.trasher = { [unowned self] p in
            guard lexists(p) else { throw EngineError("not there") }
            try FileManager.default.moveItem(atPath: p, toPath: trashDir + "/" + lastComponent(p) + "-\(self.trashed.count)")
            self.trashed.append(p)
        }
    }

    deinit { destroy() }

    func destroy() {
        // restore permissions a test may have removed, then delete the whole fixture
        _ = try? runTool("/bin/chmod", ["-R", "u+rwx", root], timeout: 30)
        try? FileManager.default.removeItem(atPath: root)
    }

    func path(_ rel: String) -> String { rel.hasPrefix("/") ? rel : home + "/" + rel }

    @discardableResult
    func dir(_ rel: String) -> String {
        try? FileManager.default.createDirectory(atPath: path(rel), withIntermediateDirectories: true)
        return path(rel)
    }

    /// A file with `size` real bytes on disk. `fill` varies the content so files are not identical.
    @discardableResult
    func file(_ rel: String, size: Int = 4096, fill: UInt8 = 0) -> String {
        let p = path(rel)
        dir(parentPath(p))
        var data = Data(repeating: fill, count: size)
        if size >= 8 { data.replaceSubrange(0..<8, with: withUnsafeBytes(of: UInt64(size) &+ UInt64(fill)) { Data($0) }) }
        FileManager.default.createFile(atPath: p, contents: data)
        return p
    }

    @discardableResult
    func text(_ rel: String, _ content: String) -> String {
        let p = path(rel)
        dir(parentPath(p))
        FileManager.default.createFile(atPath: p, contents: Data(content.utf8))
        return p
    }

    func link(_ rel: String, to target: String) {
        dir(parentPath(path(rel)))
        symlink(target, path(rel))
    }

    func hardLink(_ rel: String, to existing: String) {
        dir(parentPath(path(rel)))
        Darwin.link(path(existing), path(rel))
    }

    /// An APFS clone: a second file sharing the first one's blocks.
    func clone(_ rel: String, of existing: String) {
        dir(parentPath(path(rel)))
        if clonefile(path(existing), path(rel), 0) != 0 { T.fail("clonefile failed: \(String(cString: strerror(errno)))") }
    }

    func app(_ name: String, id: String?, bundleName: String? = nil, in rel: String = "Applications") -> String {
        let p = path(rel + "/" + name + ".app")
        var plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>"
        if let id { plist += "<key>CFBundleIdentifier</key><string>\(id)</string>" }
        plist += "<key>CFBundleName</key><string>\(bundleName ?? name)</string></dict></plist>\n"
        text(rel + "/" + name + ".app/Contents/Info.plist", plist)
        file(rel + "/" + name + ".app/Contents/MacOS/" + name, size: 20_000)
        return p
    }

    func exists(_ rel: String) -> Bool { lexists(path(rel)) }

    func allocated(_ rel: String) -> Int64 { lstatOf(path(rel))?.allocated ?? -1 }

    /// Options small enough that kilobyte fixtures show up in every report.
    func options(root: String? = nil, threads: Int = 4) -> ScanOptions {
        var o = ScanOptions(root: root ?? home)
        o.minNode = 100_000
        o.bigFile = 1_000_000
        o.foundMin = 10_000
        o.ruleMin = 500_000
        o.sizeMin = 1_000
        o.threads = threads
        return o
    }

    func scan(threads: Int = 4, write: Bool = false) -> Scan {
        try! Report.run(options(threads: threads), env: env, progress: ScanProgress(), write: write)!
    }
}
