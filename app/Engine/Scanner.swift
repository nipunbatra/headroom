// The walk: every folder on the volume read once, in parallel, read-only.
// Workers read folders and size their files; a single pass afterwards adds the tree up,
// credits clone-shared space, and keeps the folders worth showing.
//
// Never enters a mounted volume or a cloud placeholder (a dataless folder): listing one
// makes macOS download it. Hard links are counted once; sizes are allocated bytes.
import Foundation

struct ScanOptions {
    var root: String
    var dataRoot = "/System/Volumes/Data"
    var minNode: Int64 = 200 * MB       // smallest folder kept in the map
    var maxDepth = 9                    // deepest level kept in the map
    var bigFile: Int64 = 50 * MB        // collected for the large-file and duplicate lists
    var foundMin: Int64 = 20 * MB       // smallest dev leftover worth listing
    var ruleMin: Int64 = 50 * MB        // smallest rule worth listing
    var sizeDepth = 10                  // folder sizes are remembered down to this depth
    var sizeMin: Int64 = MB             // and only for folders at least this big
    var threads = max(2, min(12, ProcessInfo.processInfo.activeProcessorCount))
}

/// What a scan is doing right now, read by the UI while it runs.
final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _files = 0
    private var _path = ""
    private var _phase = "Starting"
    private var _cancelled = false

    func add(files: Int, path: String) {
        lock.lock()
        _files += files
        _path = path
        lock.unlock()
    }

    func set(phase: String) {
        lock.lock()
        _phase = phase
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        _cancelled = true
        lock.unlock()
    }

    var snapshot: (files: Int, path: String, phase: String) {
        lock.lock()
        defer { lock.unlock() }
        return (_files, _path, _phase)
    }

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _cancelled
    }
}

struct BigRec {
    var bytes: Int64
    var path: String
    var mtime: Int64
    var length: Int64
    var ino: UInt64
    var opaque: Bool
    var ext: String
    var priv: Int64
}

struct FoundRec {
    var tag: String
    var path: String
    var bytes: Int64
    var files: Int
    var returns: Int64
}

/// The raw result of a walk, before rules and reports are built from it.
struct ScanCore {
    var total: Int64 = 0
    var unique: Int64 = 0
    var tree = Node(n: "Macintosh HD", s: 0, f: 0)
    var sizes: [String: Int64] = [:]
    var privs: [String: Int64] = [:]
    var extra: [String: Int64] = [:]
    var ext: [String: (bytes: Int64, files: Int)] = [:]
    var big: [BigRec] = []
    var found: [FoundRec] = []
    var denied: [String] = []
    var files = 0
    var dirs = 0
    var dataless = 0
    var tagTotals: [String: (bytes: Int64, count: Int)] = [:]

    /// What deleting this folder returns, or nil when the scan did not keep its size.
    func frees(_ lpath: String) -> Int64? {
        guard let size = sizes[lpath] else { return nil }
        return min(size, (privs[lpath] ?? size) + (extra[lpath] ?? 0))
    }
}

private final class DirNode {
    let name: String
    unowned(unsafe) let parent: DirNode?
    let depth: Int
    let opaque: Bool
    let visible: Bool
    let tagok: Bool
    let tag: String?
    var children: [DirNode] = []
    var leaves: [Node] = []
    var total: Int64 = 0        // own files after the walk, the whole subtree after adding up
    var priv: Int64 = 0
    var nfiles = 0
    var extra: Int64 = 0        // clone-shared bytes that come back when this folder goes
    var denied = false

    init(name: String, parent: DirNode?, depth: Int, opaque: Bool, visible: Bool, tagok: Bool, tag: String?) {
        self.name = name
        self.parent = parent
        self.depth = depth
        self.opaque = opaque
        self.visible = visible
        self.tagok = tagok
        self.tag = tag
    }
}

/// Clones made by one copy operation share a clone id, their sizes and their modified time, and
/// so share the same blocks: asking macOS about one answers for all of them. A copy that was
/// written to afterwards has a newer modified time and is asked on its own.
struct CloneKey: Hashable {
    var cid: UInt64
    var bytes: Int64
    var length: Int64
    var mtime: Int64
}

private struct CloneRec {
    var cid: UInt64
    var node: DirNode
    var shared: Int64
    var copies: Int?
}

private struct Job {
    var node: DirNode
    var path: String
}

/// A stack of folders waiting to be read, shared by the workers. pop() blocks until there is
/// work, and returns nil once nothing is queued and nobody is still working.
private final class WorkQueue {
    private var items: [Job] = []
    private var active = 0
    private var stopped = false
    private let cond = NSCondition()

    func push(_ batch: [Job]) {
        guard !batch.isEmpty else { return }
        cond.lock()
        items.append(contentsOf: batch)
        cond.broadcast()
        cond.unlock()
    }

    func pop() -> Job? {
        cond.lock()
        defer { cond.unlock() }
        while items.isEmpty && active > 0 && !stopped { cond.wait() }
        if stopped || items.isEmpty {
            cond.broadcast()
            return nil
        }
        active += 1
        return items.removeLast()
    }

    func done() {
        cond.lock()
        active -= 1
        if items.isEmpty && active == 0 { cond.broadcast() }
        cond.unlock()
    }

    func stop() {
        cond.lock()
        stopped = true
        cond.broadcast()
        cond.unlock()
    }
}

private struct Local {
    var ext: [String: (bytes: Int64, files: Int)] = [:]
    var big: [BigRec] = []
    var clones: [CloneRec] = []
    var denied: [String] = []
    var files = 0
    var dirs = 0
    var dataless = 0
    var pending = 0
}

enum Scanner {
    /// Runs `body` on a thread with a deep stack: the adding-up pass recurses as deep as the folder tree.
    static func onBigStack<T>(_ body: @escaping () -> T) -> T {
        var result: T?
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result = body()
            done.signal()
        }
        thread.stackSize = 64 << 20
        thread.start()
        done.wait()
        return result!
    }

    static func classify(_ name: String, parent: String, path: String) -> String? {
        switch name {
        case "node_modules": return "node_modules"
        case ".git": return "git"
        case "__pycache__": return "pycache"
        case ".venv", "venv", "env", ".env":
            if access(path + "/pyvenv.cfg", F_OK) == 0 { return "venv" }
        case "target":
            if access(parent + "/Cargo.toml", F_OK) == 0 { return "rust-target" }
        case ".next", ".nuxt": return "web-build"
        case "Pods":
            if access(parent + "/Podfile", F_OK) == 0 { return "pods" }
        default: break
        }
        if Rules.toolCaches.contains(name) { return "toolcache" }
        if Rules.mlLogs.contains(name) { return "ml-logs" }
        return nil
    }

    /// The part of a file name after its last dot, lower-cased, when it looks like an extension.
    static func ext(of name: String) -> String {
        let u = name.utf8
        guard let i = u.lastIndex(of: 46), i != u.startIndex else { return "" }
        let tail = name[u.index(after: i)...]
        return tail.unicodeScalars.count <= 11 ? tail.lowercased() : ""
    }

    /// Walks `opts.root`. Returns nil if the scan was cancelled.
    static func walk(_ opts: ScanOptions, env: Env, progress: ScanProgress) -> ScanCore? {
        let root = opts.root
        let strip = (root != "/" && root == opts.dataRoot) ? root.utf8.count : 0
        let homeReal = strip > 0 ? root + env.home : env.home
        let rootDev = lstatOf(root)?.st_dev
        func logical(_ path: String) -> String {
            if strip == 0 { return path }
            return path.utf8.count > strip ? String(path.dropFirst(strip)) : "/"
        }

        let rootNode = DirNode(name: "Macintosh HD", parent: nil, depth: 0, opaque: false, visible: true, tagok: false, tag: nil)
        let queue = WorkQueue()
        queue.push([Job(node: rootNode, path: root)])
        let linkLock = NSLock()
        var seenLinks = Set<UInt64>()
        let cloneLock = NSLock()
        var cloneCache: [CloneKey: (Int64?, Int?)] = [:]
        var asked = 0, reused = 0
        let workers = max(1, opts.threads)
        var locals = [Local](repeating: Local(), count: workers)
        progress.set(phase: "Measuring files")

        locals.withUnsafeMutableBufferPointer { slots in
            let slots = slots
            DispatchQueue.concurrentPerform(iterations: workers) { w in
                let buf = UnsafeMutableRawPointer.allocate(byteCount: 1 << 18, alignment: 8)
                defer { buf.deallocate() }
                var local = Local()
                while let job = queue.pop() {
                    if progress.cancelled {
                        queue.stop()
                        queue.done()
                        break
                    }
                    let node = job.node, path = job.path
                    let lpath = logical(path)
                    let entries: [DirEntry]
                    do {
                        entries = try Reader.readDir(path, rootDev: rootDev, buffer: buf)
                    } catch {
                        node.denied = true
                        local.denied.append(lpath)
                        queue.done()
                        continue
                    }
                    var total: Int64 = 0, priv: Int64 = 0, nfiles = 0
                    var jobs: [Job] = []
                    var children: [DirNode] = []
                    let atHome = path == homeReal
                    for e in entries {
                        if !e.isDir {
                            if e.links > 1 {
                                linkLock.lock()
                                let first = seenLinks.insert(e.id).inserted
                                linkLock.unlock()
                                if !first { continue }
                            }
                            var pv = e.bytes
                            if e.mayShare, e.bytes > 0 {
                                let key = CloneKey(cid: e.cloneID, bytes: e.bytes, length: e.length, mtime: e.mtime)
                                cloneLock.lock()
                                let hit = e.cloneID != 0 ? cloneCache[key] : nil
                                if hit != nil { reused += 1 } else { asked += 1 }
                                cloneLock.unlock()
                                let p: Int64?, copies: Int?
                                if let hit {
                                    (p, copies) = hit
                                } else {
                                    (p, copies) = Reader.cloneInfo(path + "/" + e.name)
                                    cloneLock.lock()
                                    cloneCache[key] = (p, copies)
                                    cloneLock.unlock()
                                }
                                if let p, p < e.bytes {
                                    pv = p
                                    local.clones.append(CloneRec(cid: e.cloneID, node: node, shared: e.bytes - p, copies: copies))
                                }
                            }
                            total += e.bytes
                            priv += pv
                            nfiles += 1
                            let x = ext(of: e.name)
                            if let t = local.ext[x] { local.ext[x] = (t.bytes + e.bytes, t.files + 1) } else { local.ext[x] = (e.bytes, 1) }
                            if e.bytes >= opts.bigFile {
                                local.big.append(BigRec(bytes: e.bytes, path: (lpath == "/" ? "" : lpath) + "/" + e.name, mtime: e.mtime,
                                                        length: e.length, ino: e.id, opaque: node.opaque, ext: x, priv: pv))
                                if !node.opaque, e.bytes >= opts.minNode, node.depth < opts.maxDepth {
                                    node.leaves.append(Node(n: e.name, s: e.bytes, r: pv < e.bytes ? pv : nil, k: "f"))
                                }
                            }
                        } else if e.skip != .none {
                            if e.skip == .dataless { local.dataless += 1 }
                        } else {
                            let dp = path + "/" + e.name
                            var cOpaque = node.opaque, cTagok = node.tagok
                            var tag: String?
                            if atHome { cTagok = !(e.name.hasPrefix(".") || Rules.noTagHome.contains(e.name)) }
                            if !node.opaque {
                                if cTagok { tag = classify(e.name, parent: path, path: dp) }
                                if tag != nil || Rules.opaqueSuffixes.contains(where: e.name.hasSuffix) { cOpaque = true }
                            }
                            let child = DirNode(name: e.name, parent: node, depth: node.depth + 1, opaque: cOpaque,
                                                visible: !node.opaque, tagok: cTagok, tag: tag)
                            children.append(child)
                            jobs.append(Job(node: child, path: dp))
                        }
                    }
                    node.total = total
                    node.priv = priv
                    node.nfiles = nfiles
                    node.children = children
                    local.files += nfiles
                    local.dirs += 1
                    local.pending += nfiles
                    if local.dirs & 63 == 0 {
                        progress.add(files: local.pending, path: lpath)
                        local.pending = 0
                    }
                    queue.push(jobs)
                    queue.done()
                }
                progress.add(files: local.pending, path: "")
                slots[w] = local
            }
        }
        if progress.cancelled { return nil }
        if ProcessInfo.processInfo.environment["HEADROOM_TIMING"] != nil {
            FileHandle.standardError.write(Data("  walk done: \(locals.reduce(0) { $0 + $1.clones.count }) cloned files, \(asked) asked for their private size, \(reused) answered from a matching clone\n".utf8))
        }
        progress.set(phase: "Adding up folders")
        let results = locals

        return onBigStack {
            var core = ScanCore()
            for l in results {
                for (x, t) in l.ext {
                    if let have = core.ext[x] { core.ext[x] = (have.bytes + t.bytes, have.files + t.files) } else { core.ext[x] = t }
                }
                core.big += l.big
                core.denied += l.denied
                core.files += l.files
                core.dirs += l.dirs
                core.dataless += l.dataless
            }

            // A clone group whose every copy sits under a folder is freed when that folder goes:
            // credit its shared bytes to the deepest such folder and to everything above it.
            func covers(_ a: DirNode, _ b: DirNode) -> Bool {
                var n = b
                while n.depth > a.depth, let p = n.parent { n = p }
                return n === a
            }
            var groups: [UInt64: (top: DirNode, shared: Int64, seen: Int, copies: Int?)] = [:]
            for l in results {
                for c in l.clones {
                    if var g = groups[c.cid] {
                        while !covers(g.top, c.node), let p = g.top.parent { g.top = p }
                        g.shared = max(g.shared, c.shared)
                        g.seen += 1
                        groups[c.cid] = g
                    } else {
                        groups[c.cid] = (c.node, c.shared, 1, c.copies)
                    }
                }
            }
            for g in groups.values where g.seen >= 2 && (g.copies == nil || g.seen >= g.copies!) {
                var n: DirNode? = g.top     // a copy that lives where the scan did not reach keeps the space alive
                while let d = n {
                    d.extra += g.shared
                    n = d.parent
                }
            }

            let rootLogical = logical(root)
            func lpath(_ d: DirNode) -> String {
                var parts: [String] = []
                var n = d
                while let p = n.parent {
                    parts.append(n.name)
                    n = p
                }
                return (rootLogical == "/" ? "" : rootLogical) + (parts.isEmpty ? (rootLogical == "/" ? "/" : "") : "/" + parts.reversed().joined(separator: "/"))
            }

            func addUp(_ d: DirNode) -> Node? {
                if d.denied { return nil }
                var kids = d.leaves
                for c in d.children {
                    let node = addUp(c)
                    d.total += c.total
                    d.priv += c.priv
                    d.nfiles += c.nfiles
                    if let tag = c.tag {
                        let t = core.tagTotals[tag] ?? (0, 0)
                        core.tagTotals[tag] = (t.bytes + c.total, t.count + 1)
                        if c.total >= opts.foundMin {
                            core.found.append(FoundRec(tag: tag, path: lpath(c), bytes: c.total, files: c.nfiles, returns: c.priv + c.extra))
                        }
                        node?.t = tag
                    }
                    if let node, !d.opaque { kids.append(node) }
                }
                if d.depth <= opts.sizeDepth, d.total >= opts.sizeMin {
                    let lp = lpath(d)
                    core.sizes[lp] = d.total
                    if d.priv < d.total { core.privs[lp] = d.priv }
                    if d.extra > 0 { core.extra[lp] = d.extra }
                }
                guard d.visible, d.total >= opts.minNode, d.depth <= opts.maxDepth else { return nil }
                let node = Node(n: d.name, s: d.total, f: d.nfiles)
                let back = d.priv + d.extra
                if back < d.total { node.r = back }
                if !kids.isEmpty {
                    kids.sort { $0.s != $1.s ? $0.s > $1.s : $0.n < $1.n }
                    node.c = kids
                }
                if d.opaque { node.o = 1 }
                return node
            }
            let tree = addUp(rootNode)
            core.total = rootNode.total
            core.unique = min(rootNode.total, rootNode.priv + rootNode.extra)
            core.tree = tree ?? Node(n: "Macintosh HD", s: rootNode.total, f: rootNode.nfiles)
            return core
        }
    }
}
