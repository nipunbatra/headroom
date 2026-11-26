// The app's door to the engine. Scanning and cleaning run in this process, off the main
// thread; there is no helper and no network. The UI hands over ids and gets results back:
// what an id means is decided in Cleaner.swift.
import Foundation

final class Engine: @unchecked Sendable {
    let env = Env.live()
    let cleaner: Cleaner
    private let work = DispatchQueue(label: "headroom.engine", qos: .userInitiated, attributes: .concurrent)

    init() { cleaner = Cleaner(env: env) }

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
    func dryRun(_ ids: [String], hard: Bool, scan: Scan?) async -> [CleanResult] {
        await background { ids.map { self.cleaner.clean($0, hard: hard, dry: true, scan: scan) } }
    }

    func clean(_ id: String, hard: Bool, scan: Scan?) async -> CleanResult {
        await background { self.cleaner.clean(id, hard: hard, dry: false, scan: scan) }
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
    static func scan(_ args: [String]) -> Int32 {
        let env = Env.live()
        let data = "/System/Volumes/Data"
        var opts = ScanOptions(root: isDirectory(data) ? data : "/")
        if let i = args.firstIndex(of: "--root"), i + 1 < args.count, let real = realPath((args[i + 1] as NSString).expandingTildeInPath) {
            opts.root = real
        }
        if let i = args.firstIndex(of: "--threads"), i + 1 < args.count, let n = Int(args[i + 1]) { opts.threads = n }
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
