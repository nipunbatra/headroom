import Foundation

struct CleanupRecord: Decodable, Identifiable {
    let at: String
    let idString: String
    let did: String
    let ok: Bool
    let errors: [String]?
    let session: String?
    let title: String?
    let trashed: Int?
    let completed: Int?
    var offset = 0
    var id: Int { offset }

    enum CodingKeys: String, CodingKey { case at, idString = "id", did, ok, errors, session, title, trashed, completed }

    /// Read the newest portion of the log. A partial first line or damaged legacy entry is skipped.
    static func recent(_ path: String) throws -> [Self] {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd == -1 && errno == ENOENT { return [] }
        guard fd >= 0 else { throw EngineError("The cleanup log cannot be opened.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.isFile else { throw EngineError("The cleanup log is unavailable.") }
        let start = max(0, st.st_size - 1024 * 1024)
        try handle.seek(toOffset: UInt64(start))
        let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
        var lines = data[...]
        if start > 0 {
            guard let newline = data.firstIndex(of: 10) else { return [] }
            lines = data.suffix(from: newline + 1)
        }
        let decoder = JSONDecoder()
        return lines.split(separator: 10).reversed().lazy.compactMap { line -> Self? in
            guard var item = try? decoder.decode(Self.self, from: line) else { return nil }
            item.offset = Int(start) + line.startIndex
            return item
        }.prefix(200).map { $0 }
    }
}
