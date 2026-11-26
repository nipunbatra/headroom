// Turns a finished walk into scan.json: rules measured on this disk, the pieces inside each
// rule, Hugging Face models, duplicates, apps with their leftovers, downloads, and what
// changed since the scan before. Everything here only reads.
import CoreServices
import CryptoKit
import Foundation

enum Report {
    static let itemKeep = 80

    // MARK: - Rules

    /// Rules for this user's /private/var/folders area (T = temp, C = caches, X = clones).
    static func tempRules(_ env: Env) -> [RuleDef] {
        guard let base = env.tempBase else { return [] }
        var out = [
            RuleDef(id: "tmp-user", group: "system", safety: "review", title: "Temporary files", path: base + "/T",
                    why: "Temporary files may belong to running apps. Quit the owning app before reviewing its files.", cmd: "@manual"),
            RuleDef(id: "cache-user", group: "system", safety: "keep", title: "System-managed app caches", path: base + "/C",
                    why: "Wallpapers, compiled shaders and similar. macOS rebuilds and trims them itself.", cmd: "@manual"),
        ]
        for n in (listNames(base + "/X") ?? []).sorted() where n.hasSuffix(".code_sign_clone") {
            out.append(RuleDef(id: "clone-" + n, group: "caches", safety: "safe",
                               title: "Browser update clones: " + n.dropLast(".code_sign_clone".count), path: base + "/X/" + n,
                               why: "Copies of the browser that Chromium makes while updating and often fails to remove. Quit the browser first. They are APFS clones, so the space returned can be less than the size shown.",
                               cmd: nil))
        }
        return out
    }

    static func allRules(_ env: Env) -> [RuleDef] { Rules.table + tempRules(env) }

    static func withFrees(_ bytes: Int64, _ back: Int64?) -> Int64? {
        if let back, back < bytes { return back }
        return nil
    }

    static func buildRules(_ core: ScanCore, env: Env, opts: ScanOptions) -> [Rule] {
        var out: [Rule] = []
        if let pyc = core.tagTotals["pycache"], pyc.bytes >= opts.ruleMin {
            out.append(Rule(id: "pycache", group: "dev", safety: "review", title: "Python bytecode (__pycache__)", paths: [], bytes: pyc.bytes,
                            why: "\(grouped(pyc.count)) folders of compiled .pyc files. Python rewrites them the next time the code runs.",
                            cmd: "@manual"))
        }
        let whole = opts.root == "/" || opts.root == opts.dataRoot
        let defs = whole || env.tempBase.map({ $0.hasPrefix(opts.root + "/") }) == true ? allRules(env) : Rules.table
        let specific = Set(defs.map { env.expand($0.path) })
        out += parallelMap(defs) { def -> Rule? in          // each rule looks only at its own folder
            let p = env.expand(def.path)
            let b = core.sizes[p] ?? 0
            if b < opts.ruleMin { return nil }
            var rule = Rule(id: def.id, group: def.group, safety: def.safety, title: def.title, paths: [env.disp(p)], bytes: b,
                            why: def.why, cmd: def.cmd)
            if Rules.permanent.contains(def.id) { rule.perm = true }
            rule.frees = withFrees(b, core.frees(p))
            let t0 = Date()
            let (items, rest) = ruleItems(def.id, path: p, core: core, env: env, opts: opts)
            if ProcessInfo.processInfo.environment["HEADROOM_TIMING"] != nil, Date().timeIntervalSince(t0) > 0.5 {
                FileHandle.standardError.write(Data(String(format: "          %5.2fs items of %@\n", Date().timeIntervalSince(t0), def.id).utf8))
            }
            if !items.isEmpty {
                rule.items = items
                rule.itemsRest = rest
            }
            return rule
        }.compactMap { $0 }
        for container in Rules.cacheContainers {
            let c = env.expand(container)
            guard whole || c == opts.root || c.hasPrefix(opts.root + "/") else { continue }
            guard let names = listNames(c)?.sorted() else { continue }
            var rest: [String] = []
            var restBytes: Int64 = 0, restBack: Int64 = 0
            for n in names {
                let p = c + "/" + n
                guard !specific.contains(p), let st = lstatOf(p), st.isDir else { continue }
                let b = core.sizes[p] ?? 0
                let back = core.frees(p)
                if b >= opts.ruleMin * 3 {
                    out.append(Rule(id: "cache:" + env.disp(p), group: "caches", safety: "safe", title: "Cache: " + n, paths: [env.disp(p)], bytes: b,
                                    why: "An app's cache folder. The app rebuilds it when it next runs; quit the app first.",
                                    cmd: nil, frees: withFrees(b, back)))
                } else if b > 0 {
                    rest.append(env.disp(p))
                    restBytes += b
                    restBack += back ?? b
                }
            }
            if restBytes >= opts.ruleMin * 2 / 5 {
                out.append(Rule(id: "cache-rest:" + container, group: "caches", safety: "safe", title: "\(rest.count) smaller caches in \(container)",
                                paths: rest, bytes: restBytes, why: "Small per-app cache folders. Rebuilt on demand.", cmd: nil,
                                frees: withFrees(restBytes, restBack)))
            }
        }
        return out.sorted { $0.returns != $1.returns ? $0.returns > $1.returns : $0.id < $1.id }
    }

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: - What is inside a rule

    /// (newest read-or-write, newest write) among a folder's files, looking at up to `cap` of them.
    /// macOS moves read times forward only now and then, so the first value is a lower bound on last use.
    static func lastSeen(_ path: String, cap: Int = 3000) -> (seen: Double, changed: Double) {
        guard let st = lstatOf(path) else { return (0, 0) }
        if !st.isDir { return (max(st.atime, st.mtime), st.mtime) }
        var seen = 0.0, changed = 0.0
        var stack = [path], n = 0
        while let dir = stack.popLast(), n < cap {
            for name in listNames(dir) ?? [] {
                guard let s = lstatOf(dir + "/" + name) else { continue }
                if s.isDir {
                    stack.append(dir + "/" + name)
                } else if s.isFile {
                    n += 1
                    seen = max(seen, s.atime, s.mtime)
                    changed = max(changed, s.mtime)
                    if n == cap { break }
                }
            }
        }
        return (seen, changed)
    }

    /// A partial index cannot establish that a blob is unused. Missing optional stores are
    /// ordinary, but linked, cloud-only, or unreadable directories make ownership unknown.
    static func filesUnder(_ root: String, _ visit: (String, Bool) throws -> Void) throws {
        if lstatOf(root) == nil, errno == ENOENT { return }
        var stack = [root]
        while let dir = stack.popLast() {
            guard realPath(dir) == dir, let names = listNames(dir) else {
                throw Refused("cannot inspect model cache directory " + dir)
            }
            for name in names {
                let p = dir + "/" + name
                guard let st = lstatOf(p) else { throw Refused("the model cache changed during inspection") }
                if st.isDir { stack.append(p) }
                else if st.isLink || st.isFile { try visit(p, st.isLink) }
            }
        }
    }

    static func isHFRepo(_ name: String) -> Bool {
        name.range(of: #"^(models|datasets|spaces)--[A-Za-z0-9._\-]+\z"#, options: .regularExpression) != nil
    }

    static func hfLinks(_ hub: String) throws -> (links: [String: Set<String>], shared: String) {
        let shared = hub + "/blobs"
        guard realPath(hub) == hub, let names = listNames(hub) else { throw Refused("cannot fully inspect the model cache") }
        var links: [String: Set<String>] = [:]
        for name in names where isHFRepo(name) {
            let repo = hub + "/" + name
            guard realPath(repo) == repo, lstatOf(repo)?.isDir == true else { throw Refused("cannot inspect a linked model folder") }
            var found = Set<String>()
            for sub in ["blobs", "snapshots"] {
                try filesUnder(repo + "/" + sub) { p, link in
                    if link {
                        guard let t = realPath(p) else {
                            if errno == ENOENT { return }  // a missing blob cannot keep an existing file alive
                            throw Refused("cannot resolve model cache link " + p)
                        }
                        guard lstatOf(t)?.isFile == true else { throw Refused("cannot inspect model cache link " + p) }
                        if t.hasPrefix(shared + "/") { found.insert(t) }
                    }
                }
            }
            links[repo] = found
        }
        return (links, shared)
    }

    static func hfOrphans(_ links: [String: Set<String>], shared: String) throws -> [String] {
        let used = links.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        var out: [String] = []
        try filesUnder(shared) { p, link in
            if !link, !used.contains(p) { out.append(p) }
        }
        return out.sorted()
    }

    static func hfItems(_ hub: String, core: ScanCore, env: Env, itemMin: Int64) -> [RuleItem] {
        guard let (links, shared) = try? hfLinks(hub) else { return [] }
        var owners: [String: Int] = [:]
        for ts in links.values { for t in ts { owners[t, default: 0] += 1 } }
        var items = parallelMap(links.sorted(by: { $0.key < $1.key })) { repo, ts -> RuleItem in
            let own = core.sizes[repo] ?? 0
            var back = core.frees(repo) ?? own
            var (seen, changed) = lastSeen(repo)
            var mine: Int64 = 0, common: Int64 = 0
            for t in ts {
                guard let st = statOf(t) else { continue }
                if owners[t] == 1 {
                    mine += st.allocated
                    back += Reader.privateBytes(t) ?? st.allocated
                } else {
                    common += st.allocated
                }
                seen = max(seen, st.atime, st.mtime)
                changed = max(changed, st.mtime)
            }
            let base = lastComponent(repo)
            let cut = base.range(of: "--")!
            var item = RuleItem(id: "hfrepo:" + env.disp(repo), name: base[cut.upperBound...].replacingOccurrences(of: "--", with: "/"),
                                kind: Rules.hfKind[String(base[..<cut.lowerBound])], path: env.disp(repo), bytes: own + mine,
                                seen: seen, changed: changed)
            item.frees = withFrees(item.bytes, back)
            if common >= 50 * MB {
                item.note = String(format: "Another %.1f GB is shared with other entries and stays until they go too.", Double(common) / 1e9)
            }
            return item
        }
        let orphans = (try? hfOrphans(links, shared: shared)) ?? []
        var b: Int64 = 0, back: Int64 = 0
        for p in orphans {
            guard let st = lstatOf(p) else { continue }
            b += st.allocated
            back += Reader.privateBytes(p) ?? st.allocated
        }
        if b >= itemMin {
            items.append(RuleItem(id: "hforphans:" + env.disp(hub), name: "Leftover blobs", kind: "Leftover", path: env.disp(shared), bytes: b,
                                  frees: withFrees(b, back), seen: 0, changed: 0, flag: "leftover",
                                  note: "\(grouped(orphans.count)) stored files that no model or dataset links to any more."))
        }
        return items
    }

    /// Paths matching a pattern such as "hub/*" under `base`. "*" is one level and skips hidden names.
    static func glob(_ base: String, _ pattern: String) -> [String] {
        var paths = [base]
        for part in pattern.split(separator: "/") {
            var next: [String] = []
            for p in paths {
                if part == "*" {
                    for n in listNames(p) ?? [] where !n.hasPrefix(".") { next.append(p + "/" + n) }
                } else if lexists(p + "/" + part) {
                    next.append(p + "/" + part)
                }
            }
            paths = next
        }
        return paths
    }

    /// Rule-specific names and hints for one item.
    private static func decorate(_ key: String, _ item: inout RuleItem, _ p: String, rulePath: String, env: Env) {
        let rel = String(p.dropFirst(rulePath.count + 1))
        var name = rel
        for prefix in ["models/", "hub/checkpoints/", "hub/", "node/"] where rel.hasPrefix(prefix) {
            name = String(rel.dropFirst(prefix.count))
            break
        }
        switch key {
        case "hf":
            if rel.hasPrefix("datasets/") {
                name = rel.dropFirst(9).replacingOccurrences(of: "___", with: "/")
                item.kind = "Prepared dataset"
            } else if rel == "xet" {
                name = "Xet transfer cache"
                item.kind = "Cache"
                item.flag = "leftover"
                item.note = "Download chunks kept to speed up later transfers."
            }
        case "claude-sessions":
            let enc = env.home.replacingOccurrences(of: "/", with: "-")
            if rel.hasPrefix(enc) {
                let rest = rel.dropFirst(enc.count).drop { $0 == "-" }
                name = rest.isEmpty ? "home folder" : String(rest)
            }
        case "simdevices":
            if let data = FileManager.default.contents(atPath: p + "/device.plist"),
               let d = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
                let device = d["name"] as? String ?? rel
                var runtime = (d["runtime"] as? String ?? "").split(separator: ".").last.map(String.init) ?? ""
                if let dash = runtime.firstIndex(of: "-") { runtime.replaceSubrange(dash...dash, with: " ") }
                runtime = runtime.replacingOccurrences(of: "-", with: ".")
                name = runtime.isEmpty ? device : "\(device) (\(runtime))"
            }
        default: break
        }
        item.name = name
    }

    /// VS Code keeps superseded extension versions around for a while; point them out.
    private static func flagOldVersions(_ items: inout [RuleItem], rulePath: String) {
        var obsolete: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: rulePath + "/.obsolete"),
           let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { obsolete = o }
        let re = try! NSRegularExpression(pattern: #"^(.+?)-(\d+(?:\.\d+)+)(?:-.+)?$"#)
        var newest: [String: (ver: [Int], text: String)] = [:]
        var parsed: [String: (base: String, ver: [Int])] = [:]
        for it in items {
            let ns = it.name as NSString
            guard let m = re.firstMatch(in: it.name, range: NSRange(location: 0, length: ns.length)) else { continue }
            let base = ns.substring(with: m.range(at: 1)), text = ns.substring(with: m.range(at: 2))
            let ver = text.split(separator: ".").map { Int($0) ?? 0 }
            parsed[it.id] = (base, ver)
            if (newest[base]?.ver ?? []).lexicographicallyPrecedes(ver) { newest[base] = (ver, text) }
        }
        for i in items.indices {
            let ext = parsed[items[i].id]
            let old = ext.map { $0.ver.lexicographicallyPrecedes(newest[$0.base]!.ver) } ?? false
            if obsolete[items[i].name] != nil || old {
                items[i].flag = "leftover"
                items[i].note = old ? "Superseded: version \(newest[ext!.base]!.text) is installed." : "VS Code has marked this version for removal."
            }
        }
    }

    /// The independent pieces inside a rule's folder, largest first, each with its size and age.
    static func ruleItems(_ rid: String, path: String, core: ScanCore, env: Env, opts: ScanOptions) -> ([RuleItem], Rest?) {
        let itemMin = opts.ruleMin / 5
        let key = rid.replacingOccurrences(of: #"-\d+$"#, with: "", options: .regularExpression)
        let hubs = Set(Rules.hfHubs.map(env.expand))
        var items: [RuleItem] = []
        var restN = 0
        var restB: Int64 = 0
        for hub in [path, path + "/hub"] where hubs.contains(hub) && isDirectory(hub) {
            for it in hfItems(hub, core: core, env: env, itemMin: itemMin) {
                if it.bytes >= itemMin { items.append(it) } else {
                    restN += 1
                    restB += it.bytes
                }
            }
        }
        var found = Set<String>()
        for pat in Rules.itemLevels[key] ?? [] { found.formUnion(glob(path, pat)) }
        let sorted = found.sorted()
        var ancestors = Set<String>()
        for item in sorted {
            var ancestor = parentPath(item)
            while ancestor.hasPrefix(path + "/") {
                if !ancestors.insert(ancestor).inserted { break }
                ancestor = parentPath(ancestor)
            }
        }
        var picked: [(path: String, dir: Bool, bytes: Int64, back: Int64?)] = []
        for p in sorted {
            let name = lastComponent(p)
            guard let st = lstatOf(p), !st.isLink, !name.hasPrefix("."), name != "CACHEDIR.TAG" else { continue }
            if hubs.contains(parentPath(p)), isHFRepo(name) || name == "blobs" { continue }      // handled by hfItems
            if ancestors.contains(p) { continue }                    // a parent of other items, not an item itself
            let b: Int64, back: Int64?
            if st.isDir {
                b = core.sizes[p] ?? 0
                back = core.frees(p)
            } else {
                b = st.allocated
                back = Reader.privateBytes(p)
            }
            if b < itemMin {
                restN += 1
                restB += b
                continue
            }
            picked.append((p, st.isDir, b, back))
        }
        items += parallelMap(picked) { c -> RuleItem in      // reading dates is the slow part
            let (seen, changed) = lastSeen(c.path)
            var item = RuleItem(id: "file:" + env.disp(c.path), path: env.disp(c.path), bytes: c.bytes, frees: withFrees(c.bytes, c.back),
                                seen: seen, changed: changed)
            if c.dir { item.dir = true }
            decorate(key, &item, c.path, rulePath: path, env: env)
            return item
        }
        if key == "vscode-ext" { flagOldVersions(&items, rulePath: path) }
        items.sort { $0.returns != $1.returns ? $0.returns > $1.returns : $0.id < $1.id }
        for it in items.dropFirst(itemKeep) {
            restN += 1
            restB += it.bytes
        }
        return (Array(items.prefix(itemKeep)), restN > 0 ? Rest(count: restN, bytes: restB) : nil)
    }

    // MARK: - Duplicates, apps, downloads

    /// Only read local regular files still matching the scan. Keep memory bounded for large media.
    private static func fingerprint(_ f: BigRec, prefix: String, full: Bool, progress: ScanProgress) -> SHA256.Digest? {
        let path = prefix + f.path
        guard let initial = lstatOf(path), initial.isFile, initial.st_flags & SF_DATALESS_FLAG == 0 else { return nil }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.isFile, before.st_flags & SF_DATALESS_FLAG == 0,
              before.st_ino == f.ino, before.st_size == f.length, before.st_mtimespec.tv_sec == f.mtime else { return nil }
        var sha = SHA256()
        do {
            if full {
                var left = f.length
                while left > 0 {
                    guard !progress.cancelled, let data = try h.read(upToCount: Int(min(left, 2 * MB))), !data.isEmpty else { return nil }
                    sha.update(data: data)
                    left -= Int64(data.count)
                }
            } else {
                let offsets = f.length > 4 * MB ? [0, f.length / 2, f.length - MB] : [0]
                for offset in offsets {
                    try h.seek(toOffset: UInt64(offset))
                    guard let data = try h.read(upToCount: Int(MB)) else { return nil }
                    sha.update(data: data)
                }
            }
        } catch { return nil }
        guard fstat(fd, &after) == 0, after.st_size == before.st_size,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else { return nil }
        return sha.finalize()
    }

    /// The retained copy must still match the selected file when a duplicate action is reviewed or run.
    static func copiesStillMatch(_ first: String, _ second: String) -> Bool {
        func record(_ path: String) -> BigRec? {
            guard let st = lstatOf(path), st.isFile, st.st_flags & SF_DATALESS_FLAG == 0 else { return nil }
            return BigRec(bytes: st.allocated, path: path, mtime: Int64(st.mtime), length: st.st_size,
                          ino: st.st_ino, opaque: false, ext: "", priv: 0)
        }
        guard let a = record(first), let b = record(second), a.length == b.length, a.ino != b.ino else { return false }
        let progress = ScanProgress()
        guard let digest = fingerprint(a, prefix: "", full: true, progress: progress) else { return false }
        return fingerprint(b, prefix: "", full: true, progress: progress) == digest
    }

    /// Size and sample hashes shortlist candidates. Only a full content digest confirms a group.
    static func findDupes(_ big: [BigRec], stripRoot: String, env: Env, progress: ScanProgress, fullReadBudget: Int64 = 4 * GB) -> [DupeGroup] {
        let own = env.home + "/"
        let files = big.filter { f in
            guard f.path.hasPrefix(own), !f.opaque, f.bytes > 0 else { return false }
            let rel = f.path.dropFirst(own.count)
            return !rel.hasPrefix(".") && !Rules.noTagHome.contains(String(rel.split(separator: "/").first ?? ""))
        }
        var groups: [DupeGroup] = []
        // A matching pair of multi-terabyte media files must not turn a routine scan into a full read.
        var remaining = fullReadBudget
        func append(_ peers: [BigRec], verified: Bool) {
            let items = peers.sorted { ($0.mtime, $0.path) < ($1.mtime, $1.path) }
            groups.append(DupeGroup(bytes: items[0].bytes, files: items.map {
                DupeGroup.Copy(path: env.disp($0.path), mtime: Double($0.mtime), frees: $0.priv)
            }, verified: verified))
        }
        let sizes = Dictionary(grouping: files, by: \.length)
        for length in sizes.keys.sorted() {
            guard let peers = sizes[length], peers.count > 1 else { continue }
            var samples: [SHA256.Digest: [BigRec]] = [:]
            for f in peers.sorted(by: { $0.path < $1.path }) {
                if progress.cancelled { return [] }
                if let key = fingerprint(f, prefix: stripRoot, full: false, progress: progress) { samples[key, default: []].append(f) }
            }
            for matches in samples.values.sorted(by: { ($0.first?.path ?? "") < ($1.first?.path ?? "") }) where matches.count > 1 {
                if length > remaining / Int64(matches.count) {
                    append(matches, verified: false)
                    continue
                }
                remaining -= length * Int64(matches.count)
                var exact: [SHA256.Digest: [UInt64: BigRec]] = [:]
                for f in matches {
                    if let key = fingerprint(f, prefix: stripRoot, full: true, progress: progress) { exact[key, default: [:]][f.ino] = f }
                }
                for same in exact.values where same.count > 1 {
                    append(Array(same.values), verified: true)
                }
            }
        }
        return Array(groups.sorted { $0.extraBytes != $1.extraBytes ? $0.extraBytes > $1.extraBytes : $0.files[0].path < $1.files[0].path }.prefix(60))
    }

    /// (bundle id, name) from an app's Info.plist. Either is nil when missing or oddly formed.
    static func appIdentity(_ app: String) -> (id: String?, name: String?) {
        let plist = app + "/Contents/Info.plist"
        if isLink(plist) || isLink(app + "/Contents") { return (nil, nil) }      // an identity borrowed through a link is not trusted
        guard let data = FileManager.default.contents(atPath: plist),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return (nil, nil) }
        func plain(_ v: Any?) -> String? {
            guard let s = v as? String, !s.contains(".."),
                  s.range(of: #"^[A-Za-z0-9][A-Za-z0-9 ._\-]{2,120}\z"#, options: .regularExpression) != nil else { return nil }
            return s
        }
        var bid = plain(info["CFBundleIdentifier"])
        if let b = bid, b.filter({ $0 == "." }).count < 2 { bid = nil }          // needs the full reverse-DNS form, such as com.vendor.app
        let rawName = info["CFBundleName"] as? String
        return (bid, plain((rawName?.isEmpty ?? true) ? String(lastComponent(app).dropLast(4)) : rawName))
    }

    /// Lower-cased names and bundle ids that more than one installed app uses. A folder carrying
    /// one of them cannot be pinned on a single app, so it is never offered as a leftover.
    static func sharedAppNames(_ env: Env) -> Set<String> {
        var seen = Set<String>(), twice = Rules.vendorFolders
        for base in env.appDirs {
            for n in listNames(base) ?? [] where n.hasSuffix(".app") {
                let ident = appIdentity(base + "/" + n)
                for key in [ident.id, ident.name].compactMap({ $0?.lowercased() }) where !seen.insert(key).inserted {
                    twice.insert(key)
                }
            }
        }
        return twice
    }

    /// Support files this app left in ~/Library: existing paths that pass the path policy, are
    /// reached without any symlink, and carry the app's own bundle id or exact name.
    static func appLeftovers(_ app: String, shared: Set<String>, env: Env) -> [String] {
        let ident = appIdentity(app)
        var out: [String] = []
        for spot in Rules.leftoverSpots {
            guard let key = spot.contains("{id}") ? ident.id : ident.name, !shared.contains(key.lowercased()) else { continue }
            let p = env.expand(spot.replacingOccurrences(of: "{id}", with: key).replacingOccurrences(of: "{name}", with: key))
            let parent = parentPath(p)
            if !out.contains(p), lexists(p), Cleaner.userPathOK(p, env: env), realPath(parent) == parent { out.append(p) }
        }
        return out
    }

    static func appList(_ core: ScanCore, env: Env, root: String) -> [AppInfo] {
        let shared = sharedAppNames(env)
        var apps: [AppInfo] = []
        func inScope(_ path: String) -> Bool { root == "/" || path == root || path.hasPrefix(root + "/") }
        for base in env.appDirs where inScope(base) {
            for n in listNames(base) ?? [] where n.hasSuffix(".app") {
                let p = base + "/" + n
                let bytes = core.sizes[p] ?? 0
                var a = AppInfo(name: String(n.dropLast(4)), path: env.disp(p), bytes: bytes, frees: withFrees(bytes, core.frees(p)))
                a.bundleId = appIdentity(p).id
                var left: [AppInfo.Leftover] = []
                for lp in appLeftovers(p, shared: shared, env: env) where inScope(lp) {
                    guard let st = lstatOf(lp) else { continue }
                    if st.isDir {
                        let b = core.sizes[lp] ?? 0
                        left.append(AppInfo.Leftover(path: env.disp(lp), bytes: b, frees: withFrees(b, core.frees(lp))))
                    } else {
                        left.append(AppInfo.Leftover(path: env.disp(lp), bytes: st.allocated))
                    }
                }
                if !left.isEmpty { a.leftovers = left.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path } }
                if let item = MDItemCreate(nil, p as CFString), let used = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
                    a.lastUsed = used.timeIntervalSince1970.rounded(.down)
                }
                apps.append(a)
            }
        }
        return apps.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
    }

    /// Items of 5 MB or more in ~/Downloads, or nil when macOS will not let the folder be read.
    static func downloads(_ core: ScanCore, env: Env, minBytes: Int64 = 5 * MB) -> [Download]? {
        let d = env.home + "/Downloads"
        guard let names = listNames(d) else { return nil }
        var out: [Download] = []
        for n in names where !n.hasPrefix(".") {
            guard let st = lstatOf(d + "/" + n) else { continue }
            let b = st.isDir ? core.sizes[d + "/" + n] ?? 0 : st.allocated
            let back = st.isDir ? core.frees(d + "/" + n) : Reader.privateBytes(d + "/" + n)
            if b >= minBytes { out.append(Download(name: n, bytes: b, mtime: st.mtime, dir: st.isDir, frees: withFrees(b, back))) }
        }
        return Array(out.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }.prefix(150))
    }

    // MARK: - Changes and history

    static let changeMin = 250 * MB     // smallest change in a folder's size worth reporting

    /// What grew and what shrank between two scans, as the deepest folders that explain the change.
    /// Sizes are what deleting would return, so a new clone of something already on disk is not growth.
    /// A scan only keeps folders above the map's size cutoff, so one that crosses it shows as new or gone.
    static func diffTrees(old: Node, new: Node, root: String, minChange: Int64 = changeMin) -> [Changes.Item] {
        var out: [Changes.Item] = []
        func size(_ n: Node?) -> Int64 { n?.returns ?? 0 }
        func walk(_ o: Node?, _ n: Node?, _ path: String) {
            let d = size(n) - size(o)
            guard let o, let n else {                       // appeared or vanished: report it whole
                if abs(d) >= 2 * minChange {
                    out.append(Changes.Item(path: path, bytes: size(n), delta: d, new: n != nil ? true : nil, gone: n == nil ? true : nil))
                }
                return
            }
            let ok = Dictionary(o.children.map { ($0.n, $0) }, uniquingKeysWith: { a, _ in a })
            let nk = Dictionary(n.children.map { ($0.n, $0) }, uniquingKeysWith: { a, _ in a })
            let big = Set(ok.keys).union(nk.keys).sorted().filter { abs(size(nk[$0]) - size(ok[$0])) >= minChange }
            let explained = big.reduce(Int64(0)) { $0 + abs(size(nk[$1]) - size(ok[$1])) }
            if !big.isEmpty, Double(explained) >= 0.6 * Double(abs(d)) {
                for name in big {
                    let home = (ok[name] ?? nk[name])?.h != nil
                    walk(ok[name], nk[name], home ? "~" : (path == "/" ? "" : path) + "/" + name)
                }
            } else if abs(d) >= minChange {
                out.append(Changes.Item(path: path, bytes: size(n), delta: d))
            }
        }
        walk(old, new, root.isEmpty ? "/" : root)
        return Array(out.sorted { abs($0.delta) != abs($1.delta) ? abs($0.delta) > abs($1.delta) : $0.path < $1.path }.prefix(80))
    }

    static func readHistory(_ env: Env) -> [Sample] {
        guard let data = FileManager.default.contents(atPath: env.historyPath),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        return raw.compactMap { item in       // keep only well-formed readings
            guard let d = item as? [String: Any], let t = d["t"] as? Double, let free = (d["free"] as? NSNumber)?.int64Value else { return nil }
            return Sample(t: t, free: free, total: (d["total"] as? NSNumber)?.int64Value, scan: d["scan"] as? Int)
        }
    }

    private static let historyLock = NSLock()

    /// Appends one free-space reading to history.json. Numbers only, no paths.
    @discardableResult
    static func addHistory(_ env: Env, _ sample: Sample, minGap: Double = 0) -> [Sample] {
        historyLock.lock()
        defer { historyLock.unlock() }
        var hist = readHistory(env)
        if minGap > 0, let last = hist.last, sample.t - last.t < minGap { return hist }
        if let last = hist.last, last.t == sample.t {
            if last.scan == nil || sample.scan != nil { hist[hist.count - 1] = sample }
        } else { hist = Array((hist + [sample]).suffix(1500)) }
        guard let data = try? JSONEncoder().encode(hist) else { return hist }
        try? data.write(to: URL(fileURLWithPath: env.historyPath), options: .atomic)
        return hist
    }

    static func diskNumbers(_ opts: ScanOptions) -> (total: Int64, free: Int64) {
        var sv = statvfs()
        let target = opts.root
        guard statvfs(target, &sv) == 0 else { return (0, 0) }
        return (Int64(sv.f_blocks) * Int64(sv.f_frsize), Int64(sv.f_bavail) * Int64(sv.f_frsize))
    }

    // MARK: - The whole scan

    static func loadScan(_ path: String) -> Scan? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Scan.self, from: data)
    }

    /// Latest change among a project's own top-level entries.
    static func projectMtime(_ parent: String, skip: String) -> Double {
        var latest = 0.0
        guard let names = listNames(parent) else { return 0 }
        for n in names where n != skip && n != ".DS_Store" {
            if let st = lstatOf(parent + "/" + n) { latest = max(latest, st.mtime) }
        }
        for extra in [".git/index", ".git/HEAD"] {
            if let st = statOf(parent + "/" + extra) { latest = max(latest, st.mtime) }
        }
        return latest
    }

    /// Scans, builds every report, compares with the scan it replaces, and writes scan.json.
    /// Returns nil if cancelled; throws if the result cannot be written.
    static func run(_ opts: ScanOptions, env: Env, progress: ScanProgress, write: Bool = true) throws -> Scan? {
        if write, [env.historyPath, env.logPath, env.protectionPath, env.protectionLockPath].contains(where: { $0.caseInsensitiveCompare(env.scanPath) == .orderedSame }) {
            throw EngineError("Choose a scan output filename different from the history, action log, and protection files.")
        }
        guard let rootStat = lstatOf(opts.root), rootStat.isDir, rootStat.st_flags & SF_DATALESS_FLAG == 0 else {
            throw EngineError("The scan root must be an available local directory.")
        }
        let started = Date()
        var mark = Date()
        func lap(_ what: String) {      // HEADROOM_TIMING=1 prints how long each part took
            if ProcessInfo.processInfo.environment["HEADROOM_TIMING"] != nil {
                FileHandle.standardError.write(Data(String(format: "  %6.2fs  %@\n", Date().timeIntervalSince(mark), what).utf8))
            }
            mark = Date()
        }
        guard let core = Scanner.walk(opts, env: env, progress: progress) else { return nil }
        guard !progress.cancelled else { return nil }
        guard core.dirs > 0 || core.denied.isEmpty else { throw EngineError("The scan root could not be read.") }
        lap("walk and add up")
        progress.set(phase: "Finding leftovers, duplicates and what changed")
        let root = opts.root
        let whole = root == opts.dataRoot || root == "/"
        let stripRoot = root == opts.dataRoot && root != "/" ? root : ""

        var kinds: [String: (bytes: Int64, files: Int)] = [:]
        for (x, t) in core.ext {
            let k = Rules.extKind[x] ?? "Everything else"
            kinds[k] = ((kinds[k]?.bytes ?? 0) + t.bytes, (kinds[k]?.files ?? 0) + t.files)
        }
        let exts = core.ext.map { ExtTotal(ext: $0.key.isEmpty ? "(none)" : $0.key, bytes: $0.value.bytes, files: $0.value.files) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.ext < $1.ext }.prefix(40)

        var found: [Found] = []
        for f in core.found where f.tag != "pycache" {
            found.append(Found(tag: f.tag, path: env.disp(f.path), bytes: f.bytes, files: f.files,
                               projectMtime: projectMtime(stripRoot + parentPath(f.path), skip: lastComponent(f.path)),
                               frees: withFrees(f.bytes, f.returns)))
        }
        found.sort { $0.returns != $1.returns ? $0.returns > $1.returns : $0.path < $1.path }

        let big = core.big.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
        let bigFiles = big.filter { !$0.opaque }.prefix(400).map {
            BigFile(path: env.disp($0.path), bytes: $0.bytes, mtime: Double($0.mtime), kind: Rules.extKind[$0.ext] ?? "Everything else",
                    frees: withFrees($0.bytes, $0.priv))
        }

        let logicalRoot = stripRoot.isEmpty ? root : "/"
        let tree = core.tree
        if whole {      // rename the home node to "~" so scan.json carries no account name
            var node: Node? = tree
            for part in env.home.split(separator: "/") { node = node?.children.first { $0.n == part } }
            node?.n = "~"
            node?.h = 1
        } else {
            tree.n = env.disp(root)
        }

        let numbers = diskNumbers(opts)
        var snapshots = 0
        if whole, let (_, out) = try? runTool("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 15) {
            snapshots = out.split(separator: "\n").filter { $0.contains("com.apple") }.count
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        lap("kinds, found, big files, snapshots")
        var rules: [Rule] = [], dupes: [DupeGroup] = [], downloadList: [Download]?, apps: [AppInfo] = []
        DispatchQueue.concurrentPerform(iterations: 3) { part in       // independent reports, side by side
            switch part {
            case 0: rules = buildRules(core, env: env, opts: opts)
            case 1:
                dupes = findDupes(core.big, stripRoot: stripRoot, env: env, progress: progress)
            default:
                if whole || root == env.home || (env.home + "/Downloads").hasPrefix(root + "/") || root == env.home + "/Downloads" {
                    downloadList = downloads(core, env: env, minBytes: opts.ruleMin / 10)
                }
                if whole || root == env.home || env.appDirs.contains(where: { $0 == root || $0.hasPrefix(root + "/") }) {
                    apps = appList(core, env: env, root: logicalRoot)
                }
            }
        }
        guard !progress.cancelled else { return nil }
        lap("rules and items, duplicates, downloads and apps")
        var scan = Scan(scannedAt: Date().timeIntervalSince1970.rounded(.down), seconds: 0,
                        os: "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : ""),
                        root: env.disp(logicalRoot),
                        disk: Disk(total: numbers.total, free: numbers.free, snapshots: snapshots, scanned: core.total, unique: core.unique),
                        stats: Stats(files: core.files, dirs: core.dirs, dataless: core.dataless),
                        tree: tree,
                        kinds: kinds.map { KindTotal(kind: $0.key, bytes: $0.value.bytes, files: $0.value.files) }
                            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.kind < $1.kind },
                        exts: Array(exts),
                        rules: rules,
                        found: Array(found.prefix(600)),
                        tagTotals: core.tagTotals.mapValues { TagTotal(bytes: $0.bytes, count: $0.count) },
                        bigFiles: Array(bigFiles),
                        dupes: dupes,
                        downloads: downloadList,
                        apps: apps,
                        denied: Array(core.denied.map(env.disp).sorted { ($0.hasPrefix("~") ? 0 : 1, $0) < ($1.hasPrefix("~") ? 0 : 1, $1) }.prefix(200)),
                        deniedCount: core.denied.count)

        if let prev = loadScan(env.scanPath), prev.root == scan.root {      // compare with the scan this one replaces
            scan.changes = Changes(since: prev.scannedAt, freeThen: prev.disk.free, items: diffTrees(old: prev.tree, new: scan.tree, root: scan.root, minChange: opts.minNode * 5 / 4))

        }
        lap("changes")
        scan.seconds = (Date().timeIntervalSince(started) * 10).rounded() / 10
        if write {
            let data = try JSONEncoder().encode(scan)
            guard !progress.cancelled else { return nil }
            try data.write(to: URL(fileURLWithPath: env.scanPath), options: .atomic)
            if whole { addHistory(env, Sample(t: scan.scannedAt, free: numbers.free, total: numbers.total, scan: 1)) }
        }
        return scan
    }
}
