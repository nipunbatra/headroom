// The app's door to the engine. Scanning and cleaning run in this process, off the main
// thread; there is no helper and no network. The UI hands over ids and gets results back:
// what an id means is decided in Cleaner.swift.
import Foundation

final class Engine: @unchecked Sendable {
    let env: Env
    let cleaner: Cleaner
    private let work = DispatchQueue(label: "headroom.engine", qos: .userInitiated, attributes: .concurrent)

    init(env: Env = .live()) { self.env = env; cleaner = Cleaner(env: env) }

    var hasScan: Bool { FileManager.default.fileExists(atPath: env.scanPath) }
    var actionLogPath: String { env.logPath }

    private func background<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in
            work.async { cont.resume(returning: body()) }
        }
    }

    func loadScan() async -> Scan? {
        await background { Report.loadScan(self.env.scanPath) }
    }

    /// The whole disk, read-only. Nil if cancelled.
    func scan(progress: ScanProgress) async throws -> Scan? {
        let result: Result<Scan?, Error> = await background {
            let data = "/System/Volumes/Data"
            let opts = ScanOptions(root: isDirectory(data) ? data : "/")
            return Result { try Report.run(opts, env: self.env, progress: progress) }
        }
        return try result.get()
    }

    /// What cleaning these ids would do, without doing it.
    func dryRun(_ items: [Candidate], hard: Bool, scan: Scan?) async -> [CleanResult] {
        await background {
            var results = items.map { self.cleaner.clean($0.id, hard: hard, dry: true, scan: scan, selectedSupport: $0.selectedSupport) }
            guard results.count > 1 else { return results }
            let conflicts = self.conflicts(in: results, items: items, scan: scan)
            for i in results.indices {
                if let reason = conflicts[results[i].id] {
                    results[i].ok = false
                    results[i].errors = [reason]
                    results[i].preview = nil
                }
            }
            return results
        }
    }

    private func conflicts(in results: [CleanResult], items: [Candidate], scan: Scan?) -> [String: String] {
        let titles = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.title) })
        var owners: [String: Set<String>] = [:]
        for result in results {
            for target in result.preview ?? [] {
                switch target.step {
                case .run: continue
                case .delete(let p), .trash(let p): owners[p, default: []].insert(result.id)
                }
            }
        }
        func covering(_ path: String) -> Set<String> {
            guard isNormal(path) else { return [] }
            var ids = Set<String>(), ancestor = path
            while ancestor != "/" {
                if let owners = owners[ancestor] { ids.formUnion(owners) }
                ancestor = parentPath(ancestor)
            }
            return ids
        }
        var conflicts: [String: String] = [:]
        for (path, ids) in owners {
            let enclosing = covering(path)
            for id in ids {
                if let other = enclosing.subtracting([id]).sorted().first {
                    conflicts[id] = "Overlaps with “" + (titles[other] ?? other) + "”. Leave one item out to continue."
                    conflicts[other] = "Overlaps with “" + (titles[id] ?? id) + "”. Leave one item out to continue."
                }
            }
        }
        for group in scan?.dupes ?? [] {
            guard let first = group.files.first else { continue }
            let removingKeeper = covering(env.expand(first.path))
            guard !removingKeeper.isEmpty else { continue }
            for copy in group.files.dropFirst() where titles["duplicate:" + copy.path] != nil {
                for id in removingKeeper.union(["duplicate:" + copy.path]) {
                    conflicts[id] = "This selection also removes the retained copy. Leave one of the conflicting items out."
                }
            }
        }
        for app in items where !app.supportOptions.isEmpty {
            for option in app.supportOptions {
                let owners = covering(env.expand(option.path)).subtracting([app.id])
                for other in owners {
                    let reason = "This support file is also listed under “" + app.title + "”. Remove its separate selection and choose it in the app review."
                    conflicts[app.id] = reason
                    conflicts[other] = reason
                }
            }
        }
        return conflicts
    }

    func clean(_ item: Candidate, hard: Bool, scan: Scan?, reviewed: [ReviewedStep]) async -> CleanResult {
        await background {
            self.cleaner.clean(item.id, hard: hard, dry: false, scan: scan, reviewed: reviewed, selectedSupport: item.selectedSupport)
        }
    }

    func list(_ path: String) async throws -> Listing {
        let result: Result<Listing, Error> = await background { Result { try self.cleaner.list(path) } }
        do { return try result.get() } catch let r as Refused { throw EngineError(r.message) }
    }

    /// Free space over time; adds a reading at most every three hours.
    func history(free: Int64, total: Int64) async -> [Sample] {
        await background {
            Report.addHistory(self.env, Sample(t: Date().timeIntervalSince1970.rounded(.down), free: free, total: total), minGap: 3 * 3600)
        }
    }
}

/// `Headroom --scan`: measure the disk from a terminal and write scan.json, no window.
enum CLI {
    static func options(_ args: [String]) throws -> ScanOptions {
        let data = "/System/Volumes/Data"
        var opts = ScanOptions(root: isDirectory(data) ? data : "/")
        var args = args.dropFirst().makeIterator()
        while let option = args.next() {
            switch option {
            case "--scan": continue
            case "--root":
                guard let raw = args.next(), !raw.isEmpty, let path = realPath((raw as NSString).expandingTildeInPath), isDirectory(path) else {
                    throw EngineError("--root requires an existing directory")
                }
                opts.root = path
            case "--threads":
                guard let raw = args.next(), let n = Int(raw), (1...64).contains(n) else {
                    throw EngineError("--threads requires a number between 1 and 64")
                }
                opts.threads = n
            default: throw EngineError("Unknown scan option " + option)
            }
        }
        return opts
    }

    static func scan(_ args: [String]) -> Int32 {
        let opts: ScanOptions
        do { opts = try options(args) }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); return 2 }
        let env = Env.live()
        let progress = ScanProgress()
        let err = FileHandle.standardError
        err.write(Data("Scanning \(opts.root) (read-only)...\n".utf8))
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler {
            let s = progress.snapshot
            err.write(Data("  \(s.files) files  \(s.phase)  \(s.path.prefix(90))\n".utf8))
        }
        timer.resume()
        do {
            guard let scan = try Report.run(opts, env: env, progress: progress) else { return 1 }
            timer.cancel()
            err.write(Data(String(format: "Wrote %@: %d files, %.1f GB (%.1f GB unique) in %.1fs\n", env.scanPath, scan.stats.files,
                                  Double(scan.disk.scanned) / 1e9, Double(scan.disk.unique ?? 0) / 1e9, scan.seconds).utf8))
            return 0
        } catch {
            err.write(Data("Scan failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
