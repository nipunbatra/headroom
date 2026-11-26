// The cleaner reads this local policy for both preview and execution, including after relaunch.
import Foundation

struct ProtectedPaths {
    let env: Env

    func read() throws -> [String] {
        let fd = open(env.protectionPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd == -1 && errno == ENOENT { return [] }
        let failure = Refused("Cannot read protected locations. Check Settings → Protection.")
        guard fd >= 0 else { throw failure }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        let limit = 1024 * 1024
        guard fstat(fd, &st) == 0, st.isFile, st.st_size <= limit,
              let data = try handle.read(upToCount: limit + 1), data.count <= limit,
              let paths = try? JSONDecoder().decode([String].self, from: data),
              paths.allSatisfy(isNormal) else { throw failure }
        return paths
    }

    func change(_ path: String, add: Bool) throws -> [String] {
        try withLock(LOCK_EX | LOCK_NB) { try update(path, add: add) }
    }

    func withLock<Value>(_ mode: Int32, _ body: () throws -> Value) throws -> Value {
        let fd = open(env.protectionLockPath, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw EngineError("Unable to save protected locations.") }
        defer { close(fd) }
        guard flock(fd, mode) == 0 else { throw EngineError("Protection is busy. Try again after the current operation finishes.") }
        return try body()
    }

    private func update(_ path: String, add: Bool) throws -> [String] {
        var paths = Set(try read())
        if add {
            guard let p = realPath(path), isNormal(p) else { throw EngineError("Choose an existing file or folder.") }
            paths.insert(p)
        } else { paths.remove(path) }
        let result = paths.sorted()
        let data = try JSONEncoder().encode(result)
        guard data.count <= 1024 * 1024 else { throw EngineError("Protected locations exceed the storage limit.") }
        try data.write(to: URL(fileURLWithPath: env.protectionPath), options: .atomic)
        return result
    }

    static func overlaps(_ a: String, _ b: String) -> Bool {
        let a = a.precomposedStringWithCanonicalMapping.lowercased()
        let b = b.precomposedStringWithCanonicalMapping.lowercased()
        return a == "/" || b == "/" || a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    func validate(_ steps: [Step], paths: [String]) throws {
        for step in steps {
            switch step {
            case .run where paths.isEmpty: continue
            case .run:
                throw Refused("This tool chooses its own targets and cannot honor protected locations. Review its files individually.")
            case .delete(let path), .trash(let path):
                let aliases = [path, realPath(path)].compactMap { $0 }
                for protected in paths + [env.protectionPath, env.protectionLockPath] where aliases.contains(where: { Self.overlaps($0, protected) }) {
                    throw Refused("This would affect the protected location " + env.disp(protected))
                }
            }
        }
    }
}
