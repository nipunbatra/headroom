// The shapes in scan.json and the helper's API answers. Sizes are bytes on disk;
// `frees` is what deleting returns and is present only when it is smaller.
import Foundation

struct Scan: Decodable {
    var scannedAt: Double
    var seconds: Double
    var os: String
    var root: String
    var disk: Disk
    var stats: Stats
    var tree: Node
    var kinds: [KindTotal]
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

struct Disk: Decodable {
    var total: Int64
    var free: Int64
    var snapshots: Int?
    var scanned: Int64
    var unique: Int64?
}

struct Stats: Decodable {
    var files: Int
    var dirs: Int
    var dataless: Int?
}

/// One folder (or large file) in the disk map.
final class Node: Decodable, Identifiable {
    let n: String
    let s: Int64
    let f: Int?
    let r: Int64?
    let c: [Node]?
    let t: String?
    let k: String?
    let h: Int?
    var path = ""
    weak var parent: Node?

    enum CodingKeys: String, CodingKey { case n, s, f, r, c, t, k, h }
    var id: String { path }
    var children: [Node] { c ?? [] }
    var returns: Int64 { r ?? s }
    var isFile: Bool { k == "f" }
}

struct KindTotal: Decodable, Identifiable {
    var kind: String
    var bytes: Int64
    var files: Int
    var id: String { kind }
}

struct TagTotal: Decodable {
    var bytes: Int64
    var count: Int
}

struct Rest: Decodable {
    var count: Int
    var bytes: Int64
}

struct Rule: Decodable, Identifiable {
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
    var pickable: Bool { !(cmd?.hasPrefix("@") ?? false) }
    var cleanID: String { "rule:" + id }
}

struct RuleItem: Decodable {
    var id: String
    var name: String
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

struct Found: Decodable {
    var tag: String
    var path: String
    var bytes: Int64
    var files: Int?
    var projectMtime: Double?
    var frees: Int64?
    var returns: Int64 { frees ?? bytes }
}

struct BigFile: Decodable {
    var path: String
    var bytes: Int64
    var mtime: Double
    var kind: String
    var frees: Int64?
    var returns: Int64 { frees ?? bytes }
}

struct DupeGroup: Decodable {
    struct Copy: Decodable {
        var path: String
        var mtime: Double
    }
    var bytes: Int64
    var files: [Copy]
}

struct Download: Decodable {
    var name: String
    var bytes: Int64
    var mtime: Double
    var dir: Bool
    var frees: Int64?
    var returns: Int64 { frees ?? bytes }
    var path: String { "~/Downloads/" + name }
}

struct AppInfo: Decodable {
    struct Leftover: Decodable {
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

struct Changes: Decodable {
    struct Item: Decodable {
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

// MARK: - Helper API

struct Status: Decodable {
    var free: Int64
    var total: Int64
    var scanning: Bool
    var progress: String
    var scanError: String
    var hasScan: Bool
}

struct CleanResult: Decodable {
    var id: String
    var ok: Bool
    var errors: [String]
    var freed: Int64?
    var trashed: Int?
    var summary: String?
    var free: Int64?
}

struct CleanResponse: Decodable {
    var results: [CleanResult]
}

struct Listing: Decodable {
    struct Entry: Decodable {
        var name: String
        var path: String
        var dir: Bool
        var bytes: Int64
        var mtime: Double
        var link: Bool?
        var files: Int?
        var partial: Bool?
        var frees: Int64?
        var returns: Int64 { frees ?? bytes }
    }
    var path: String
    var entries: [Entry]
    var rest: Rest?
}

struct Sample: Decodable, Identifiable {
    var t: Double
    var free: Int64
    var total: Int64?
    var scan: Int?
    var id: Double { t }
    var date: Date { Date(timeIntervalSince1970: t) }
}

struct History: Decodable {
    var samples: [Sample]
}
