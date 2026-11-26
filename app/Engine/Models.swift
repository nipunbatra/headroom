// The shapes in scan.json. Sizes are bytes on disk; `frees` is what deleting returns and is
// present only when it is smaller. The same file feeds the app and the read-only web snapshot.
import Foundation

struct Scan: Codable {
    var version = 2
    var scannedAt: Double
    var seconds: Double
    var os: String
    var root: String
    var disk: Disk
    var stats: Stats
    var tree: Node
    var kinds: [KindTotal]
    var exts: [ExtTotal]?
    var rules: [Rule]
    var found: [Found]?
    var tagTotals: [String: TagTotal]?
    var bigFiles: [BigFile]?
    var dupes: [DupeGroup]?
    var downloads: [Download]?
    var apps: [AppInfo]?
    var denied: [String]?
    var deniedCount: Int?
    var changes: Changes?
}

struct Disk: Codable {
    var total: Int64
    var free: Int64
    var snapshots: Int?
    var scanned: Int64
    var unique: Int64?
}

struct Stats: Codable {
    var files: Int
    var dirs: Int
    var dataless: Int?
}

/// One folder (or large file) in the disk map.
final class Node: Codable, Identifiable {
    var n: String
    var s: Int64
    var f: Int?
    var r: Int64?           // what deleting returns, when less than s
    var c: [Node]?
    var t: String?          // a tag such as node_modules
    var k: String?          // "f" for a file
    var h: Int?             // 1 on the home folder, whose name is replaced by ~
    var o: Int?             // 1 when the contents are not shown (an app bundle, a tagged folder)
    var path = ""
    weak var parent: Node?

    enum CodingKeys: String, CodingKey { case n, s, f, r, c, t, k, h, o }

    init(n: String, s: Int64, f: Int? = nil, r: Int64? = nil, k: String? = nil) {
        self.n = n
        self.s = s
        self.f = f
        self.r = r
        self.k = k
    }

    var id: String { path }
    var children: [Node] { c ?? [] }
    var returns: Int64 { r ?? s }
    var isFile: Bool { k == "f" }
}

struct KindTotal: Codable, Identifiable {
    var kind: String
    var bytes: Int64
    var files: Int
    var id: String { kind }
}

struct ExtTotal: Codable {
    var ext: String
    var bytes: Int64
    var files: Int
}

struct TagTotal: Codable {
    var bytes: Int64
    var count: Int
}

struct Rest: Codable {
    var count: Int
    var bytes: Int64
}

struct Rule: Codable, Identifiable {
    var id: String
    var group: String
    var safety: String
    var title: String
    var paths: [String]
    var bytes: Int64
    var why: String
    var cmd: String?
    var frees: Int64?
    var perm: Bool?
    var items: [RuleItem]?
    var itemsRest: Rest?

    var returns: Int64 { frees ?? bytes }
    /// False for rules that are handled by hand in the app that owns them.
    var pickable: Bool { safety != "keep" && !(cmd?.hasPrefix("@") ?? false) }
    var cleanID: String { "rule:" + id }
}

struct RuleItem: Codable {
    var id: String
    var name: String = ""
    var kind: String?
    var path: String?
    var bytes: Int64
    var frees: Int64?
    var seen: Double?
    var changed: Double?
    var dir: Bool?
    var flag: String?
    var note: String?
    var returns: Int64 { frees ?? bytes }
}

struct Found: Codable {
    var tag: String
    var path: String
    var bytes: Int64
    var files: Int?
    var projectMtime: Double?
    var frees: Int64?
    var returns: Int64 { frees ?? bytes }
}

struct BigFile: Codable {
    var path: String
    var bytes: Int64
    var mtime: Double
    var kind: String
    var frees: Int64?
    var returns: Int64 { frees ?? bytes }
}

struct DupeGroup: Codable {
    struct Copy: Codable {
        var path: String
        var mtime: Double
        var frees: Int64?
    }
    var bytes: Int64
    var files: [Copy]
    var verified: Bool?
    var extraBytes: Int64 { files.dropFirst().reduce(0) { $0 + ($1.frees ?? bytes) } }
}

struct Download: Codable {
    var name: String
    var bytes: Int64
    var mtime: Double
    var dir: Bool
    var frees: Int64?
    var returns: Int64 { frees ?? bytes }
    var path: String { "~/Downloads/" + name }
}

struct AppInfo: Codable {
    struct Leftover: Codable {
        var path: String
        var bytes: Int64
        var frees: Int64?
        var returns: Int64 { frees ?? bytes }
    }
    var name: String
    var path: String
    var bytes: Int64
    var frees: Int64?
    var lastUsed: Double?
    var bundleId: String?
    var leftovers: [Leftover]?
    var returns: Int64 { frees ?? bytes }
    var leftoverBytes: Int64 { (leftovers ?? []).reduce(0) { $0 + $1.returns } }
}

struct Changes: Codable {
    struct Item: Codable {
        var path: String
        var bytes: Int64
        var delta: Int64
        var new: Bool?
        var gone: Bool?
    }
    var since: Double
    var freeThen: Int64?
    var items: [Item]
}

// MARK: - What the engine answers

struct CleanResult {
    var id: String
    var ok = false
    var errors: [String] = []
    var preview: [ReviewedStep]?
    var freed: Int64 = 0
    var trashed = 0
    var completed = 0
    var summary = ""
    var free: Int64?
    var output: String?
}

struct Listing {
    struct Entry {
        var name: String
        var path: String
        var dir = false
        var bytes: Int64 = 0
        var mtime: Double = 0
        var link = false
        var files: Int?
        var partial = false
        var frees: Int64?
        var returns: Int64 { frees ?? bytes }
    }
    var path: String
    var entries: [Entry]
    var rest: Rest?
}

struct Sample: Codable, Identifiable {
    var t: Double
    var free: Int64
    var total: Int64?
    var scan: Int?
    var id: Double { t }
    var date: Date { Date(timeIntervalSince1970: t) }
}
