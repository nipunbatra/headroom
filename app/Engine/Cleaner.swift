// The only code that removes anything. Rules it holds itself to:
//   * Callers pass item ids, never commands or free-form instructions. What an id means (which
//     command, which folder) is decided here, from the tables in Rules.swift.
//   * Free-form paths ("file:" ids) must pass userPathOK(): inside the home folder, at least two
//     levels deep (three under ~/Library), never a .git folder, never reached through a symlink;
//     or an app directly in /Applications.
//   * Caches and rebuildable folders are deleted outright. Everything else is moved to the Trash
//     unless the person ticks "delete immediately".
//   * Every action is appended to the action log.
import Foundation

enum Step: Equatable {
    case run(String)
    case delete(String)
    case trash(String)
}

final class Cleaner: @unchecked Sendable {
    let env: Env
    private let lock = NSLock()

    init(env: Env) { self.env = env }

    // MARK: - Path policy

    /// Must stay in step with AppModel.pickable(), which only decides what the UI offers.
    static func userPathOK(_ p: String, env: Env) -> Bool {
        guard p.hasPrefix("/"), isNormal(p) else { return false }
        if (p + "/").contains("/.git/") { return false }
        if p.range(of: #"^/Applications/[^/\n]+\.app\z"#, options: .regularExpression) != nil { return true }
        guard p.hasPrefix(env.home + "/") else { return false }
        let seg = p.dropFirst(env.home.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        if seg.count < (seg[0] == "Library" ? 3 : 2) { return false }
        guard let parent = realPath(parentPath(p)), let home = realPath(env.home) else { return false }
        return parent == home || parent.hasPrefix(home + "/")
    }

    func inHome(_ p: String) -> Bool {
        guard let real = realPath(p), let home = realPath(env.home) else { return false }
        return real == home || real.hasPrefix(home + "/")
    }

    private func children(_ path: String) throws -> [String] {
        guard let st = lstatOf(path), st.isDir else { throw Refused("not a folder any more: " + env.disp(path)) }
        if realPath(path) != path { throw Refused("reached through a symlink, so it is left alone: " + env.disp(path)) }
        guard let names = listNames(path) else { throw Refused("cannot read " + env.disp(path)) }
        return names.sorted().map { path + "/" + $0 }
    }

    /// True for paths inside a folder the rules list as a cache (safe, or a download cache).
    func insideCacheRule(_ p: String) -> Bool {
        Report.allRules(env).contains { ($0.safety == "safe" || Rules.permanent.contains($0.id)) && p.hasPrefix(env.expand($0.path) + "/") }
    }

    static func appRunning(_ app: String) throws -> Bool {
        let (code, out) = try runTool("/bin/ps", ["-axo", "comm="], timeout: 10)
        if code != 0 { throw EngineError("ps failed") }
        return out.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix(app + "/") }
    }

    // MARK: - What an id means

    /// Turns an id into concrete steps. `scan` supplies the folder lists of cache rules.
    func resolve(_ id: String, hard: Bool, scan: Scan?) throws -> [Step] {
        if id.hasPrefix("rule:") {
            let rid = String(id.dropFirst(5))
            if rid == "pycache" { return [.run(Rules.pycacheCommand)] }
            if let def = Report.allRules(env).first(where: { $0.id == rid }) {
                if def.safety == "keep" || (def.cmd?.hasPrefix("@") ?? false) {
                    throw Refused("this one is handled by hand, in the app that owns it")
                }
                if let cmd = def.cmd { return [.run(cmd)] }
                let outright = def.safety == "safe" || hard || Rules.permanent.contains(rid)
                return try children(env.expand(def.path)).map { outright ? .delete($0) : .trash($0) }
            }
            if rid.hasPrefix("cache:") || rid.hasPrefix("cache-rest:") {
                guard let scan else { throw Refused("no scan to check this against") }
                guard let rule = scan.rules.first(where: { $0.id == rid }) else { throw Refused("not in the current scan") }
                let containers = Set(Rules.cacheContainers.map(env.expand))
                var steps: [Step] = []
                for shown in rule.paths {
                    let p = env.expand(shown)
                    guard isNormal(p), containers.contains(parentPath(p)) else { throw Refused("not a cache folder: " + env.disp(p)) }
                    if lexists(p) { steps += try children(p).map { .delete($0) } }
                }
                return steps
            }
            throw Refused("unknown item")
        }
        if id.hasPrefix("file:") {
            let p = env.expand(String(id.dropFirst(5)))
            guard Cleaner.userPathOK(p, env: env) else { throw Refused("outside the folders Headroom is allowed to touch: " + env.disp(p)) }
            guard lexists(p) else { throw Refused("already gone: " + env.disp(p)) }
            let outright = hard || Rules.rebuildable.contains(lastComponent(p)) || insideCacheRule(p)
            return [outright ? .delete(p) : .trash(p)]
        }
        if id.hasPrefix("app:") {       // an app plus the support files it left in ~/Library
            let p = env.expand(String(id.dropFirst(4)))
            let name = String(lastComponent(p).dropLast(4))
            guard p.hasSuffix(".app"), Cleaner.userPathOK(p, env: env), ["/Applications", env.home + "/Applications"].contains(parentPath(p)) else {
                throw Refused("not an app Headroom can remove: " + env.disp(p))
            }
            guard let st = lstatOf(p), st.isDir else { throw Refused("already gone: " + env.disp(p)) }
            guard let plist = lstatOf(p + "/Contents/Info.plist"), plist.isFile else { throw Refused("not an app bundle: " + env.disp(p)) }
            if let own = env.ownBundle, realPath(p) == realPath(own) { throw Refused("Headroom cannot remove itself. Drag it to the Trash in Finder.") }
            guard let running = try? Cleaner.appRunning(p) else { throw Refused("could not check whether \(name) is running") }
            if running { throw Refused("quit \(name) first, then try again") }
            let all = [p] + Report.appLeftovers(p, shared: Report.sharedAppNames(env), env: env)
            return all.map { hard ? .delete($0) : .trash($0) }
        }
        if id.hasPrefix("hfrepo:") || id.hasPrefix("hforphans:") {
            let orphans = id.hasPrefix("hforphans:")
            let p = env.expand(String(id[id.index(after: id.firstIndex(of: ":")!)...]))
            let hub = orphans ? p : parentPath(p)
            guard isNormal(p), Rules.hfHubs.map(env.expand).contains(hub), realPath(hub) == hub else {
                throw Refused("not a Hugging Face cache folder: " + env.disp(p))
            }
            let (links, shared) = Report.hfLinks(hub)
            var steps: [Step] = []
            let blobs: [String]
            if orphans {
                blobs = Report.hfOrphans(links, shared: shared)
            } else {
                guard let mine = links[p] else { throw Refused("already gone: " + env.disp(p)) }
                let others = links.filter { $0.key != p }.values.reduce(into: Set<String>()) { $0.formUnion($1) }
                blobs = mine.subtracting(others).sorted()
                steps = [.delete(p)]
            }
            for b in blobs {            // only ever plain files inside this hub's blob store
                guard b.hasPrefix(shared + "/"), let st = lstatOf(b), st.isFile else { throw Refused("unexpected file in the blob store: " + env.disp(b)) }
            }
            return steps + blobs.map { .delete($0) }
        }
        throw Refused("unknown item")
    }

    static func summarise(_ steps: [Step]) -> String {
        guard let first = steps.first else { return "Nothing left to remove" }
        if case .run(let cmd) = first { return "Runs: " + cmd }
        let d = steps.filter { if case .delete = $0 { return true } else { return false } }.count
        let t = steps.count - d
        var parts: [String] = []
        if d > 0 { parts.append("Deletes \(d) item\(d == 1 ? "" : "s") for good") }
        if t > 0 { parts.append("Moves \(t) item\(t == 1 ? "" : "s") to the Trash") }
        return parts.joined(separator: " and ")
    }

    // MARK: - Doing it

    static func remove(_ p: String) throws {
        guard let st = lstatOf(p) else { return }
        if !st.isDir {
            if unlink(p) != 0 { throw EngineError(String(cString: strerror(errno))) }
            return
        }
        try? FileManager.default.removeItem(atPath: p)
        if lexists(p) { throw EngineError("some files are in use or protected and were left behind") }
    }

    func runCommand(_ cmd: String) throws -> String {
        var e = ProcessInfo.processInfo.environment
        if e["UV_LOCK_TIMEOUT"] == nil { e["UV_LOCK_TIMEOUT"] = "30" }       // fail fast when another uv process holds the cache
        e["PATH"] = (Rules.extraPath.map { ($0 as NSString).expandingTildeInPath } + [e["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        let (code, out) = try runTool("/bin/zsh", ["-lc", cmd], env: e, timeout: 1800)
        if code == 127 { throw EngineError("the tool for this is not installed or not on PATH") }
        if code != 0 { throw EngineError(out.isEmpty ? "exit code \(code)" : String(out.suffix(300))) }
        return String(out.suffix(400))
    }

    func freeBytes() -> Int64 {
        var sv = statvfs()
        guard statvfs(isDirectory("/System/Volumes/Data") ? "/System/Volumes/Data" : "/", &sv) == 0 else { return 0 }
        return Int64(sv.f_bavail) * Int64(sv.f_frsize)
    }

    /// Carries out one id, or with `dry` only says what it would do.
    func clean(_ id: String, hard: Bool, dry: Bool, scan: Scan?) -> CleanResult {
        var res = CleanResult(id: id)
        let steps: [Step]
        do {
            steps = try resolve(id, hard: hard, scan: scan)
        } catch let r as Refused {
            res.errors.append(r.message)
            return res
        } catch {
            res.errors.append(error.localizedDescription)
            return res
        }
        res.summary = Cleaner.summarise(steps)
        if dry {
            res.ok = true
            return res
        }
        lock.lock()                     // one cleanup at a time
        defer { lock.unlock() }
        let before = freeBytes()
        var failed = 0
        for step in steps {
            do {
                switch step {
                case .run(let cmd): res.output = try runCommand(cmd)
                case .delete(let p): try Cleaner.remove(p)
                case .trash(let p):
                    try env.trasher(p)
                    res.trashed += 1
                }
            } catch {
                failed += 1
                if res.errors.count < 4 {
                    let target: String
                    switch step {
                    case .run(let cmd): target = cmd
                    case .delete(let p), .trash(let p): target = env.disp(p)
                    }
                    res.errors.append("\(target): \(error.localizedDescription)")
                }
            }
        }
        if failed > res.errors.count { res.errors.append("and \(failed - res.errors.count) more") }
        res.ok = failed == 0
        res.free = freeBytes()
        res.freed = max(0, (res.free ?? 0) - before)
        log(id: id, hard: hard, res)
        return res
    }

    private func log(id: String, hard: Bool, _ res: CleanResult) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let entry: [String: Any] = ["at": f.string(from: Date()), "id": id, "hard": hard, "did": res.summary, "ok": res.ok,
                                    "freed": res.freed, "errors": res.errors]
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        if let h = FileHandle(forWritingAtPath: env.logPath) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            FileManager.default.createFile(atPath: env.logPath, contents: data)
        }
    }

    // MARK: - Looking inside a folder

    /// Live contents of one folder in the home folder, largest first. Read-only. Folder sizes are
    /// measured on the spot; anything not finished within `budget` seconds comes back as "at least".
    func list(_ shown: String, budget: TimeInterval = 6) throws -> Listing {
        let p = env.expand(shown)
        guard p.hasPrefix("/"), isNormal(p), let st = lstatOf(p), st.isDir else { throw Refused("not a folder: " + env.disp(p)) }
        guard inHome(p) else { throw Refused("Headroom only looks inside your home folder") }
        if st.st_flags & SF_DATALESS_FLAG != 0 { throw Refused("this folder lives in the cloud; opening it would download it") }
        guard let names = listNames(p) else { throw Refused("macOS would not open " + env.disp(p)) }
        let deadline = Date().addingTimeInterval(budget)
        var slots = [Listing.Entry?](repeating: nil, count: names.count)
        slots.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: names.count) { i in
                let path = p + "/" + names[i]
                guard let s = lstatOf(path) else { return }
                var e = Listing.Entry(name: names[i], path: env.disp(path), mtime: s.mtime)
                if s.isLink {
                    e.link = true
                } else if s.isDir {
                    e.dir = true
                    if s.st_flags & SF_DATALESS_FLAG == 0 {         // a cloud placeholder is listed but never entered
                        let m = Reader.measure(path, deadline: deadline)
                        e.bytes = m.bytes
                        e.files = m.files
                        e.mtime = max(Double(m.newest), s.mtime)
                        e.partial = m.partial
                        if !m.partial { e.frees = Report.withFrees(m.bytes, m.returns) }
                    }
                } else {
                    e.bytes = s.allocated
                    e.frees = Report.withFrees(s.allocated, Reader.privateBytes(path))
                }
                out[i] = e
            }
        }
        let entries = slots.compactMap { $0 }.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
        let rest = entries.dropFirst(250)
        return Listing(path: env.disp(p), entries: Array(entries.prefix(250)),
                       rest: rest.isEmpty ? nil : Rest(count: rest.count, bytes: rest.reduce(0) { $0 + $1.bytes }))
    }
}
