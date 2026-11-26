// Where the engine looks and writes. Everything that depends on "this Mac" goes through
// here, so tests can point the whole engine at a throwaway home folder.
import Foundation

let MB: Int64 = 1_000_000
let GB: Int64 = 1_000_000_000

struct EngineError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Thrown when the engine declines to touch something. The message is shown to the person.
struct Refused: LocalizedError {
    var message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

final class Env: @unchecked Sendable {
    /// The home folder, with no trailing slash.
    let home: String
    /// Where scan.json, history.json and the action log live.
    let support: String
    let scanPath: String
    /// Folders that hold installed apps.
    let appDirs: [String]
    /// This user's /private/var/folders/xx/yyy folder, or nil to leave temp rules out.
    let tempBase: String?
    /// The running app's own bundle, which it refuses to uninstall.
    let ownBundle: String?
    /// Moves one item to the Trash. Replaced in tests.
    var trasher: (String) throws -> Void

    init(home: String, support: String, appDirs: [String]? = nil, tempBase: String? = nil, ownBundle: String? = nil,
         scanFile: String? = nil, trasher: ((String) throws -> Void)? = nil) {
        self.home = home
        self.support = support
        self.scanPath = scanFile ?? support + "/scan.json"
        self.appDirs = appDirs ?? ["/Applications", "/Applications/Utilities", home + "/Applications"]
        self.tempBase = tempBase
        self.ownBundle = ownBundle
        self.trasher = trasher ?? Env.systemTrash
    }

    /// The real Mac: the user's home, Application Support, and the system temp folder.
    static func live() -> Env {
        let home = NSHomeDirectory()
        let override = ProcessInfo.processInfo.environment["HEADROOM_OUT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).standardizedFileURL.path }
        let support = override.map { ($0 as NSString).deletingLastPathComponent }
            ?? home + "/Library/Application Support/Headroom"
        try? FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)
        var temp: String?
        var buf = [CChar](repeating: 0, count: 1024)
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count) > 0, let real = realPath(String(cString: buf)) {
            temp = (real as NSString).deletingLastPathComponent
        }
        let bundle = Bundle.main.bundlePath
        return Env(home: home, support: support, tempBase: temp, ownBundle: bundle.hasSuffix(".app") ? bundle : nil, scanFile: override)
    }

    /// Developer-only cleanup runs in an explicitly named disposable home with its own Trash.
    static func fixture(_ path: String?) throws -> Env {
        guard let path, let root = realPath(path), isDirectory(root),
              lastComponent(root).hasPrefix("HeadroomFixture"), lstatOf(root)?.st_uid == getuid(),
              [NSTemporaryDirectory(), "/tmp"].compactMap(realPath).contains(parentPath(root)) else {
            throw Refused("set HEADROOM_FIXTURE_HOME to a HeadroomFixture directory directly inside the system temp folder")
        }
        let work = root + "/.headroom-" + UUID().uuidString
        let trash = work + "/Trash"
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        return Env(home: root, support: work, appDirs: [], trasher: { path in
            try FileManager.default.moveItem(atPath: path, toPath: trash + "/" + UUID().uuidString + "-" + lastComponent(path))
        })
    }

    var historyPath: String { support + "/history.json" }
    var logPath: String { support + "/headroom-actions.log" }

    /// "~/x" -> "/Users/me/x".
    func expand(_ p: String) -> String {
        if p == "~" { return home }
        if p.hasPrefix("~/") { return home + p.dropFirst(1) }
        return p
    }

    /// The logical path with the home folder shortened to ~, so a shared scan carries no account name.
    func disp(_ p: String) -> String {
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p
    }

    static func systemTrash(_ path: String) throws {
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/trash") {
            let (code, out) = try runTool("/usr/bin/trash", [path], timeout: 900)
            if code != 0 { throw EngineError(out.isEmpty ? "could not move it to the Trash" : String(out.suffix(300))) }
        } else {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        }
    }
}

// MARK: - Small path and process helpers

func realPath(_ p: String) -> String? {
    guard let r = realpath(p, nil) else { return nil }
    defer { free(r) }
    return String(cString: r)
}

func parentPath(_ p: String) -> String {
    guard let i = p.lastIndex(of: "/") else { return "." }
    return i == p.startIndex ? "/" : String(p[..<i])
}

func lastComponent(_ p: String) -> String {
    guard let i = p.lastIndex(of: "/") else { return p }
    return String(p[p.index(after: i)...])
}

/// A path with no "." or ".." parts, no doubled or trailing slash: what os.path.normpath leaves unchanged.
func isNormal(_ p: String) -> Bool {
    guard !p.utf8.contains(0) else { return false }
    if p == "/" { return true }
    guard p.hasPrefix("/"), !p.hasSuffix("/") else { return false }
    for part in p.dropFirst().split(separator: "/", omittingEmptySubsequences: false) where part.isEmpty || part == "." || part == ".." {
        return false
    }
    return true
}

func lstatOf(_ p: String) -> stat? {
    var st = stat()
    return lstat(p, &st) == 0 ? st : nil
}

func statOf(_ p: String) -> stat? {
    var st = stat()
    return stat(p, &st) == 0 ? st : nil
}

extension stat {
    var isDir: Bool { st_mode & S_IFMT == S_IFDIR }
    var isFile: Bool { st_mode & S_IFMT == S_IFREG }
    var isLink: Bool { st_mode & S_IFMT == S_IFLNK }
    var allocated: Int64 { Int64(st_blocks) * 512 }
    var mtime: Double { Double(st_mtimespec.tv_sec) }
    var atime: Double { Double(st_atimespec.tv_sec) }
}

func isLink(_ p: String) -> Bool { lstatOf(p)?.isLink ?? false }
func isDirectory(_ p: String) -> Bool { statOf(p)?.isDir ?? false }       // follows links, like os.path.isdir
func lexists(_ p: String) -> Bool { lstatOf(p) != nil }

/// Names in a folder, or nil if it cannot be read. Never follows the folder if it is a placeholder: callers check first.
func listNames(_ p: String) -> [String]? {
    guard let st = lstatOf(p), st.isDir, st.st_flags & SF_DATALESS_FLAG == 0, let d = opendir(p) else { return nil }
    defer { closedir(d) }
    var out: [String] = []
    while true {
        errno = 0
        guard let e = readdir(d) else { return errno == 0 ? out : nil }
        let name = withUnsafePointer(to: &e.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(e.pointee.d_namlen) + 1) { String(cString: $0) } }
        if name != "." && name != ".." { out.append(name) }
    }
}

/// Runs a program and returns (exit code, combined output). Kills it after `timeout` seconds.
@discardableResult
func runTool(_ tool: String, _ args: [String], env: [String: String]? = nil, timeout: TimeInterval) throws -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    if let env { p.environment = env }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    killer.cancel()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

/// `body` applied to every item on several threads at once; results keep the items' order.
func parallelMap<T, R>(_ items: [T], _ body: (T) -> R) -> [R] {
    var out = [R?](repeating: nil, count: items.count)
    out.withUnsafeMutableBufferPointer { slots in
        let slots = slots
        DispatchQueue.concurrentPerform(iterations: items.count) { i in slots[i] = body(items[i]) }
    }
    return out.map { $0! }
}
