// Starts the bundled scanner (scan.py) as a local helper and talks to it.
// The helper decides what every id means and refuses anything outside its rules;
// this side only ever sends ids, never commands or paths to delete.
import Foundation

struct EngineError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class Engine: @unchecked Sendable {
    let scanURL: URL
    private var base: URL?
    private var token = ""
    private var process: Process?
    private let session: URLSession

    init() {
        let env = ProcessInfo.processInfo.environment
        if let out = env["HEADROOM_OUT"], !out.isEmpty {
            scanURL = URL(fileURLWithPath: out)
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Headroom", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            scanURL = dir.appendingPathComponent("scan.json")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 3 * 3600      // a tool's own cleaner can take a long time
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: config)
    }

    var supportDirectory: URL { scanURL.deletingLastPathComponent() }
    var actionLogURL: URL { supportDirectory.appendingPathComponent("headroom-actions.log") }

    static func findPython() -> String? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func findScript() -> String? {
        let env = ProcessInfo.processInfo.environment
        var places = [String]()
        if let p = env["HEADROOM_PY"] { places.append(p) }
        if let r = Bundle.main.resourcePath { places.append(r + "/scan.py") }
        places.append(FileManager.default.currentDirectoryPath + "/scan.py")
        return places.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Launches the helper and waits for the address and token it prints.
    func start() async throws {
        guard let python = Engine.findPython() else { throw EngineError("python") }
        guard let script = Engine.findScript() else { throw EngineError("Headroom's scanner is missing from the app. Build it again.") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [script, "app", "--no-open", "--stay", "--port", "0", "--out", scanURL.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var buffer = Data()
            var url: URL?
            var token: String?
            var done = false
        }
        let box = Box()
        let handle = pipe.fileHandleForReading
        let (url, tok): (URL, String) = try await withCheckedThrowingContinuation { cont in
            @Sendable func finish(_ result: Result<(URL, String), Error>) {
                box.lock.lock()
                let first = !box.done
                box.done = true
                box.lock.unlock()
                if first {
                    handle.readabilityHandler = nil
                    cont.resume(with: result)
                }
            }
            handle.readabilityHandler = { h in
                let data = h.availableData
                if data.isEmpty {
                    finish(.failure(EngineError("Headroom's helper stopped before it was ready.")))
                    return
                }
                box.lock.lock()
                box.buffer.append(data)
                let text = String(decoding: box.buffer, as: UTF8.self)
                for line in text.split(separator: "\n") {
                    if line.hasPrefix("HEADROOM_TOKEN ") { box.token = String(line.dropFirst(15)).trimmingCharacters(in: .whitespaces) }
                    if line.hasPrefix("HEADROOM_URL ") { box.url = URL(string: String(line.dropFirst(13)).trimmingCharacters(in: .whitespaces)) }
                }
                let ready = box.url != nil && box.token != nil && text.hasSuffix("\n")
                let pair = (box.url, box.token)
                box.lock.unlock()
                if ready, let u = pair.0, let t = pair.1 { finish(.success((u, t))) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                finish(.failure(EngineError("Headroom's helper did not start in time.")))
            }
        }
        base = url
        token = tok
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    private func send(_ path: String, body: [String: Any]?, timeout: TimeInterval) async throws -> Data {
        guard let base, let url = URL(string: path, relativeTo: base) else {
            throw EngineError("Headroom's helper is not running. Quit Headroom and open it again.")
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue(token, forHTTPHeaderField: "X-Headroom-Token")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw EngineError(message ?? "Headroom's helper did not answer (\(http.statusCode)).")
        }
        return data
    }

    private func call<T: Decodable>(_ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 30) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send(path, body: body, timeout: timeout))
    }

    func status() async throws -> Status { try await call("api/status") }
    func history() async throws -> [Sample] { (try await call("api/history") as History).samples }
    func rescan() async throws -> Status { try await call("api/rescan", body: [:]) }
    func list(_ path: String) async throws -> Listing { try await call("api/list", body: ["path": path], timeout: 60) }

    /// What the helper would do for these ids, without doing it.
    func dryRun(_ ids: [String], hard: Bool) async throws -> [CleanResult] {
        (try await call("api/clean", body: ["ids": ids, "hard": hard, "dryRun": true], timeout: 120) as CleanResponse).results
    }

    func clean(_ id: String, hard: Bool) async throws -> CleanResult {
        let r: CleanResponse = try await call("api/clean", body: ["ids": [id], "hard": hard], timeout: 3 * 3600)
        guard let first = r.results.first else { throw EngineError("Headroom's helper sent an empty answer.") }
        return first
    }

    func loadScan() throws -> Scan {
        try JSONDecoder().decode(Scan.self, from: Data(contentsOf: scanURL))
    }
}
