// Read-only, bounded largest-file ranking for a selected folder or mounted volume.
import Foundation

struct LocationReport {
    struct Item: Identifiable {
        var path: String
        var bytes: Int64
        var directory: Bool
        var note: String? = nil
        var onlineOnly = false
        var id: String { path }
        var name: String { lastComponent(path) }
    }

    let path: String
    let identity: String?
    let bytes: Int64
    let files: Int
    let available: Int64
    let entries: [Item]
    let largest: [Item]
    let denied: [String]
    let onlineOnlyItems: Int
    let scannedAt: Double

    private struct Directory {
        var path: String
        var owner: Int?
        var opaque: Bool
    }

    private static func rank(_ a: Item, _ b: Item) -> Bool {
        a.bytes != b.bytes ? a.bytes > b.bytes : a.path < b.path
    }

    static func measure(_ selected: String, progress: ScanProgress) throws -> Self? {
        guard let root = realPath(selected), let before = lstatOf(root), before.isDir,
              before.st_flags & SF_DATALESS_FLAG == 0 else { throw EngineError("This folder is unavailable or online-only.") }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1 << 18, alignment: 8)
        defer { buffer.deallocate() }
        var queue = [Directory(path: root, owner: nil, opaque: false)]
        var entries: [Item] = [], largest: [Item] = [], denied: [String] = []
        var countedLinks = Set<UInt64>(), visibleLinks = Set<UInt64>()
        var bytes: Int64 = 0, files = 0, onlineOnly = 0
        while let dir = queue.popLast() {
            if progress.cancelled { return nil }
            let contents: [DirEntry]
            do { contents = try Reader.readDir(dir.path, rootDev: before.st_dev, buffer: buffer) }
            catch {
                if dir.owner == nil { throw EngineError("The folder could not be read or its volume changed.") }
                denied.append(dir.path)
                if let owner = dir.owner { entries[owner].note = "Partially measured" }
                continue
            }
            var children: [Directory] = []
            // A stable visitation order gives hard-linked bytes a consistent owning folder.
            for e in contents.sorted(by: { $0.name < $1.name }) {
                if progress.cancelled { return nil }
                let path = (dir.path == "/" ? "" : dir.path) + "/" + e.name
                let owner = dir.owner ?? entries.count
                if dir.owner == nil {
                    entries.append(Item(path: path, bytes: 0, directory: e.isDir))
                }
                if e.skip != .none {
                    if e.skip == .dataless { onlineOnly += 1 }
                    if dir.owner == nil {
                        entries[owner].onlineOnly = e.skip == .dataless
                        entries[owner].note = e.skip == .dataless ? "Online only" : "Separate volume"
                    }
                    continue
                }
                if e.isDir {
                    children.append(Directory(path: path, owner: owner, opaque: dir.opaque || Rules.opaqueSuffixes.contains(where: e.name.hasSuffix)))
                    continue
                }
                if e.links < 2 || countedLinks.insert(e.id).inserted {
                    files += 1
                    bytes += e.bytes
                    entries[owner].bytes += e.bytes
                } else if dir.owner == nil {
                    entries[owner].note = "Hard link · counted once"
                }
                guard !dir.opaque, e.bytes >= MB, (largest.count < 100 || e.bytes >= largest.last!.bytes),
                      e.links < 2 || visibleLinks.insert(e.id).inserted else { continue }
                let item = Item(path: path, bytes: e.bytes, directory: false)
                largest.insert(item, at: largest.firstIndex(where: { rank(item, $0) }) ?? largest.endIndex)
                if largest.count > 100 { largest.removeLast() }
            }
            queue.append(contentsOf: children.reversed())
        }
        guard !progress.cancelled else { return nil }
        guard let after = lstatOf(root), after.st_ino == before.st_ino, after.st_dev == before.st_dev else {
            throw EngineError("The folder or its volume changed during measurement.")
        }
        let uuid = try? URL(fileURLWithPath: root).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        return Self(path: root, identity: uuid.map { $0 + "/" + String(before.st_ino) }, bytes: bytes, files: files,
                    available: Report.diskNumbers(ScanOptions(root: root)).free, entries: entries.sorted(by: rank),
                    largest: largest, denied: denied, onlineOnlyItems: onlineOnly, scannedAt: Date().timeIntervalSince1970)
    }
}
