// The only code that removes anything. Rules it holds itself to:
//   * Callers pass item ids, never commands or free-form instructions. What an id means (which
//     command, which folder) is decided here, from the tables in Rules.swift.
//   * Free-form paths ("file:" ids) must pass userPathOK(): inside the home folder, at least two
//     levels deep (three under ~/Library), never a .git folder, never reached through a symlink;
//     or an app directly in /Applications.
//   * Caches and rebuildable folders are deleted outright. Everything else is moved to the Trash
//     unless the person ticks "delete immediately".
//   * Every action is appended to the action log.
import CryptoKit
import Foundation

enum Step: Equatable {
    case run(String)
    case delete(String)
    case trash(String)
}

/// The targets the user saw, including filesystem identity for path-based actions.
struct ReviewedStep: Equatable {
    let step: Step
    let inode: ino_t?
    let device: dev_t?
    let changedSeconds: Int?
    let changedNanoseconds: Int?

    let contents: SHA256.Digest?

    init(_ step: Step) throws {
        self.step = step
        let st: stat?
        switch step {
        case .run: st = nil
        case .delete(let path), .trash(let path):
            let parent = parentPath(path)
            guard realPath(parent) == parent, let parentStat = lstatOf(parent), let target = lstatOf(path),
                  target.st_dev == parentStat.st_dev else { throw Refused("the target moved, is mounted, or has a linked parent") }
            st = target
        }
        if case .delete(let path) = step, let st, st.isDir {
            contents = try Self.directoryDigest(path, device: st.st_dev)
        } else {
            contents = nil
        }
        inode = st?.st_ino
        device = st?.st_dev
        changedSeconds = st?.st_ctimespec.tv_sec
        changedNanoseconds = st?.st_ctimespec.tv_nsec
    }
    /// Verify the entire subtree before an irreversible recursive delete. Hash metadata without
    /// reading file contents or following symlinks. Inaccessible and mounted directories fail closed.
    private static func directoryDigest(_ root: String, device: dev_t) throws -> SHA256.Digest {
        var hash = SHA256()
        var stack = [root]
        var buffer = Data()
        while let directory = stack.popLast() {
            guard let names = listNames(directory) else { throw Refused("cannot verify all contents of this folder") }
            for name in names.sorted() {
                let path = directory + "/" + name
                guard let st = lstatOf(path), st.st_dev == device, st.st_flags & SF_DATALESS_FLAG == 0 else {
                    throw Refused("a mounted, cloud-only, or changed item prevents permanent cleanup")
                }
                buffer.append(contentsOf: path.utf8)
                buffer.append(0)
                for value in [UInt64(st.st_ino), UInt64(st.st_mode), UInt64(bitPattern: Int64(st.st_ctimespec.tv_sec)),
                              UInt64(st.st_ctimespec.tv_nsec)] {
                    withUnsafeBytes(of: value) { buffer.append(contentsOf: $0) }
                }
                if buffer.count >= 65_536 { hash.update(data: buffer); buffer.removeAll(keepingCapacity: true) }
                if st.isDir { stack.append(path) }
            }
        }
        hash.update(data: buffer)
        return hash.finalize()
    }

}

final class Cleaner: @unchecked Sendable {
    let env: Env
    private let lock = NSLock()

    init(env: Env) { self.env = env }

    // MARK: - Path policy

    /// Must stay in step with AppModel.pickable(), which only decides what the UI offers.
    static func userPathOK(_ p: String, env: Env) -> Bool {
        guard p.hasPrefix("/"), isNormal(p) else { return false }
        if (p.lowercased() + "/").contains("/.git/") { return false }
        if p.range(of: #"^/Applications/[^/\n]+\.app\z"#, options: .regularExpression) != nil { return true }
        guard p.hasPrefix(env.home + "/") else { return false }
        let seg = p.dropFirst(env.home.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        if seg.count < (seg[0].lowercased() == "library" ? 3 : 2) { return false }
        guard let parent = realPath(parentPath(p)), let home = realPath(env.home) else { return false }
        return parent == parentPath(p) && (parent == home || parent.hasPrefix(home + "/"))
    }

    static func insideInstalledApp(_ shown: String) -> Bool {
        for base in ["/applications/", "~/applications/"] where shown.lowercased().hasPrefix(base) {
            return shown.dropFirst(base.count).split(separator: "/").contains { $0.lowercased().hasSuffix(".app") }
        }
        return false
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
    func resolve(_ id: String, hard: Bool, scan: Scan?, selectedSupport: Set<String> = []) throws -> [Step] {
        if id.hasPrefix("rule:") {
            let rid = String(id.dropFirst(5))
            if rid == "pycache" { throw Refused("review individual bytecode folders in the disk map") }
            if let def = Report.allRules(env).first(where: { $0.id == rid }) {
                if def.safety == "keep" || (def.cmd?.hasPrefix("@") ?? false) {
                    throw Refused("this one is handled by hand, in the app that owns it")
                }
                if let cmd = def.cmd { return [.run(cmd)] }
                if rid == "trash" { return try children(env.expand(def.path)).map(Step.delete) }
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
                    guard isNormal(p), containers.contains(parentPath(p)),
                          !Rules.table.contains(where: { env.expand($0.path) == p }) else { throw Refused("not a cache folder: " + env.disp(p)) }
                    if lexists(p) { steps += try children(p).map { .delete($0) } }
                }
                return steps
            }
            throw Refused("unknown item")
        }
        if id.hasPrefix("duplicate:") {
            let shown = String(id.dropFirst("duplicate:".count))
            let path = env.expand(shown)
            guard let group = scan?.dupes?.first(where: { $0.files.dropFirst().contains { $0.path == shown } }),
                  let keeper = group.files.first.map({ env.expand($0.path) }),
                  path.hasPrefix(env.home + "/"), keeper.hasPrefix(env.home + "/"),
                  Self.userPathOK(path, env: env), Self.userPathOK(keeper, env: env),
                  !Self.insideInstalledApp(shown), Report.copiesStillMatch(path, keeper) else {
                throw Refused("the retained copy is missing or its contents no longer match")
            }
            return [hard ? .delete(path) : .trash(path)]
        }
        if id.hasPrefix("file:") {
            let p = env.expand(String(id.dropFirst(5)))
            guard Cleaner.userPathOK(p, env: env) else { throw Refused("outside the folders Headroom is allowed to touch: " + env.disp(p)) }
            guard let st = lstatOf(p) else { throw Refused("already gone: " + env.disp(p)) }
            if Self.insideInstalledApp(env.disp(p)) {
                throw Refused("review the app in Applications to uninstall it")
            }
            let name = lastComponent(p)
            let rebuildable = st.isDir && Rules.rebuildable.contains(name)
                && Scanner.classify(name, parent: parentPath(p), path: p) != nil
            let outright = hard || rebuildable || insideCacheRule(p)
            return [outright ? .delete(p) : .trash(p)]
        }
        if id.hasPrefix("app:") {
            let p = env.expand(String(id.dropFirst(4)))
            let name = String(lastComponent(p).dropLast(4))
            guard p.hasSuffix(".app"), Cleaner.userPathOK(p, env: env), ["/Applications", env.home + "/Applications"].contains(parentPath(p)) else {
                throw Refused("not an app Headroom can remove: " + env.disp(p))
            }
            guard let st = lstatOf(p), st.isDir else { throw Refused("already gone: " + env.disp(p)) }
            guard realPath(p + "/Contents") == p + "/Contents", let plist = lstatOf(p + "/Contents/Info.plist"), plist.isFile else { throw Refused("not an app bundle: " + env.disp(p)) }
            if let own = env.ownBundle, realPath(p) == realPath(own) { throw Refused("Headroom cannot remove itself. Drag it to the Trash in Finder.") }
            guard let running = try? Cleaner.appRunning(p) else { throw Refused("could not check whether \(name) is running") }
            if running { throw Refused("quit \(name) first, then try again") }
            var paths = [p]
            if !selectedSupport.isEmpty {
                let matched = Report.appLeftovers(p, shared: Report.sharedAppNames(env), env: env)
                let selected = Set(selectedSupport.map(env.expand))
                guard selected.isSubset(of: Set(matched)) else {
                    throw Refused("A selected support file is missing or no longer belongs to this app. Review the selection again.")
                }
                paths += matched.filter(selected.contains)
            }
            return paths.map { hard ? .delete($0) : .trash($0) }
        }
        if id.hasPrefix("hfrepo:") || id.hasPrefix("hforphans:") {
            let orphans = id.hasPrefix("hforphans:")
            let p = env.expand(String(id[id.index(after: id.firstIndex(of: ":")!)...]))
            let hub = orphans ? p : parentPath(p)
            guard isNormal(p), Rules.hfHubs.map(env.expand).contains(hub), realPath(hub) == hub else {
                throw Refused("not a Hugging Face cache folder: " + env.disp(p))
            }
            let (links, shared) = try Report.hfLinks(hub)
            var steps: [Step] = []
            let blobs: [String]
            if orphans {
                blobs = try Report.hfOrphans(links, shared: shared)
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

    static func remove(_ p: String, expected: ReviewedStep? = nil) throws {
        let parent = parentPath(p)
        guard realPath(parent) == parent else { throw Refused("the parent folder changed") }
        let fd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw EngineError(String(cString: strerror(errno))) }
        defer { close(fd) }
        let name = lastComponent(p)
        var st = stat(), dir = stat()
        guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0, fstat(fd, &dir) == 0,
              st.st_dev == dir.st_dev else { throw Refused("the target moved or is mounted") }
        if let expected, st.st_ino != expected.inode || st.st_dev != expected.device ||
            st.st_ctimespec.tv_sec != expected.changedSeconds || st.st_ctimespec.tv_nsec != expected.changedNanoseconds {
            throw Refused("the target changed after review")
        }
        let result = st.isDir ? removefileat(fd, name, nil, removefile_flags_t(REMOVEFILE_RECURSIVE)) : unlinkat(fd, name, 0)
        if result != 0 { throw EngineError(String(cString: strerror(errno))) }
    }

    func runCommand(_ cmd: String) throws -> String {
        var e = ProcessInfo.processInfo.environment
        e["HOME"] = env.home
        if e["UV_LOCK_TIMEOUT"] == nil { e["UV_LOCK_TIMEOUT"] = "30" }       // fail fast when another uv process holds the cache
        e["PATH"] = (Rules.extraPath.map(env.expand) + [e["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        let (code, out) = try runTool("/bin/zsh", ["-c", cmd], env: e, timeout: 1800)
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
    func clean(_ id: String, hard: Bool, dry: Bool, scan: Scan?, reviewed: [ReviewedStep]? = nil,
               selectedSupport: Set<String> = []) -> CleanResult {
        if !dry { lock.lock() }
        defer { if !dry { lock.unlock() } }
        var res = CleanResult(id: id)
        let steps: [Step]
        let current: [ReviewedStep]
        do {
            steps = try resolve(id, hard: hard, scan: scan, selectedSupport: selectedSupport)
            current = dry ? try steps.map(ReviewedStep.init) : []
        } catch let r as Refused {
            res.errors.append(r.message)
            return res
        } catch {
            res.errors.append(error.localizedDescription)
            return res
        }
        res.summary = Cleaner.summarise(steps)
        if let reviewed, steps != reviewed.map(\.step) {
            res.errors = ["The targets changed after review. Review this item again."]
            return res
        }
        if dry {
            res.preview = current
            res.ok = true
            return res
        }
        let before = freeBytes()
        var failed = 0
        for (index, step) in steps.enumerated() {
            do {
                let expected = reviewed?[index]
                if let expected, try ReviewedStep(step) != expected { throw Refused("the target changed after review") }
                switch step {
                case .run(let cmd): res.output = try runCommand(cmd)
                case .delete(let p): try Cleaner.remove(p, expected: expected)
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
                // Later steps depend on successfully removing the bundle or model repository.
                if index == 0 && (id.hasPrefix("app:") || id.hasPrefix("hfrepo:")) { break }
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
        let fd = open(env.logPath, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.isFile else { return }
        try? handle.write(contentsOf: data)
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
