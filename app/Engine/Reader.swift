// Reads folders with getattrlistbulk: one call returns a whole folder with each file's size,
// link count, clone id and a "may share blocks" flag. Files with that flag are asked for their
// private size (what deleting returns at once) and how many clone copies exist.
import Darwin
import Foundation

let SF_DATALESS_FLAG: UInt32 = 0x4000_0000

struct DirEntry {
    enum Skip: UInt8 { case none, mount, dataless }
    var name: String
    var isDir: Bool
    var mtime: Int64 = 0
    var id: UInt64 = 0
    var skip = Skip.none        // a folder that must not be entered: a mounted volume, or a cloud placeholder that would download
    var links: UInt32 = 0
    var bytes: Int64 = 0        // allocated on disk
    var length: Int64 = 0
    var cloneID: UInt64 = 0
    var mayShare = false
}

enum Reader {
    private static let bufferSize = 1 << 18
    /// False once a file system refuses the bulk call; the plain reader takes over.
    private static var fast = true
    /// False once the system refuses the clone copy count (older macOS).
    private static var copies = true
    private static let lock = NSLock()

    private static var bulkAttrs: attrlist = {
        var a = attrlist()
        a.bitmapcount = 5
        a.commonattr = 0x8000_0000 | 0x1 | 0x8 | 0x400 | 0x40000 | 0x200_0000   // returned-attrs | name | type | modified | flags | file id
        a.dirattr = 0x4                                                         // mount status
        a.fileattr = 0x1 | 0x4 | 0x200                                          // link count | allocated | data length
        a.forkattr = 0x100 | 0x200                                              // clone id | extended flags
        return a
    }()

    /// One folder's files and folders; other things (links, sockets) are left out.
    /// `rootDev` lets the plain reader spot mounted volumes. Throws POSIXError if the folder cannot be opened.
    static func readDir(_ path: String, rootDev: dev_t? = nil, buffer: UnsafeMutableRawPointer? = nil) throws -> [DirEntry] {
        if fast {
            let fd = open(path, O_RDONLY | O_DIRECTORY)
            if fd < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            let own = buffer == nil
            let buf = buffer ?? UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
            defer { if own { buf.deallocate() } }
            var out: [DirEntry] = []
            var attrs = bulkAttrs
            while true {
                let count = getattrlistbulk(fd, &attrs, buf, bufferSize, 0x28)
                if count <= 0 {
                    if count < 0, out.isEmpty {
                        let e = errno
                        if e == EINVAL || e == ENOTSUP {
                            lock.lock()
                            fast = false            // this file system cannot do it
                            lock.unlock()
                            return try plainRead(path, rootDev: rootDev)
                        }
                        throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
                    }
                    return out
                }
                var p = UnsafeRawPointer(buf)
                for _ in 0..<count {
                    let length = Int(p.loadUnaligned(as: UInt32.self))
                    let dirAttrs = p.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
                    let fileAttrs = p.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
                    let nameOff = Int(p.loadUnaligned(fromByteOffset: 24, as: Int32.self))
                    let nameLen = Int(p.loadUnaligned(fromByteOffset: 28, as: UInt32.self))
                    let type = p.loadUnaligned(fromByteOffset: 32, as: UInt32.self)
                    if type == 1 || type == 2 {     // VREG, VDIR
                        let name = String(decoding: UnsafeRawBufferPointer(start: p + 24 + nameOff, count: max(0, nameLen - 1)), as: UTF8.self)
                        var e = DirEntry(name: name, isDir: type == 2)
                        e.mtime = p.loadUnaligned(fromByteOffset: 36, as: Int64.self)
                        e.id = p.loadUnaligned(fromByteOffset: 56, as: UInt64.self)
                        if type == 1 {
                            if fileAttrs != 0 {
                                e.links = p.loadUnaligned(fromByteOffset: 64, as: UInt32.self)
                                e.bytes = p.loadUnaligned(fromByteOffset: 68, as: Int64.self)
                                e.length = p.loadUnaligned(fromByteOffset: 76, as: Int64.self)
                                e.cloneID = p.loadUnaligned(fromByteOffset: 84, as: UInt64.self)
                                e.mayShare = p.loadUnaligned(fromByteOffset: 92, as: UInt64.self) & 1 != 0
                                out.append(e)
                            }
                        } else {
                            let flags = p.loadUnaligned(fromByteOffset: 52, as: UInt32.self)
                            let mounted = dirAttrs != 0 && p.loadUnaligned(fromByteOffset: 64, as: UInt32.self) & 1 != 0
                            e.skip = mounted ? .mount : flags & SF_DATALESS_FLAG != 0 ? .dataless : .none
                            out.append(e)
                        }
                    }
                    p += length
                }
            }
        }
        return try plainRead(path, rootDev: rootDev)
    }

    private static func plainRead(_ path: String, rootDev: dev_t?) throws -> [DirEntry] {
        guard let names = listNames(path) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var out: [DirEntry] = []
        for name in names {
            guard let st = lstatOf(path + "/" + name) else { continue }
            if st.isFile {
                var e = DirEntry(name: name, isDir: false)
                e.mtime = Int64(st.st_mtimespec.tv_sec)
                e.id = UInt64(st.st_ino)
                e.links = UInt32(st.st_nlink)
                e.bytes = st.allocated
                e.length = Int64(st.st_size)
                out.append(e)
            } else if st.isDir {
                var e = DirEntry(name: name, isDir: true)
                e.mtime = Int64(st.st_mtimespec.tv_sec)
                e.id = UInt64(st.st_ino)
                e.skip = (rootDev != nil && st.st_dev != rootDev!) ? .mount : st.st_flags & SF_DATALESS_FLAG != 0 ? .dataless : .none
                out.append(e)
            }
        }
        return out
    }

    private static func extended(_ path: String, _ forkattr: UInt32) -> (Int64, UInt32)? {
        var a = attrlist()
        a.bitmapcount = 5
        a.forkattr = forkattr
        var buf = [UInt8](repeating: 0, count: 16)
        guard getattrlist(path, &a, &buf, 16, 0x21) == 0 else { return nil }     // no-follow | extended
        return buf.withUnsafeBytes { ($0.loadUnaligned(fromByteOffset: 4, as: Int64.self), $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self)) }
    }

    /// Bytes that come back at once if this file is deleted: 0 for a pure clone. Nil if unknown.
    static func privateBytes(_ path: String) -> Int64? {
        guard fast else { return nil }
        // Working out the private size can take seconds on a large, fragmented file. A file that
        // is not flagged as possibly sharing blocks shares nothing, so its size on disk is the answer.
        var a = attrlist()
        a.bitmapcount = 5
        a.fileattr = 0x4            // allocated size
        a.forkattr = 0x200          // extended flags
        var buf = [UInt8](repeating: 0, count: 24)
        if getattrlist(path, &a, &buf, 24, 0x21) == 0 {
            let (alloc, flags) = buf.withUnsafeBytes { ($0.loadUnaligned(fromByteOffset: 4, as: Int64.self), $0.loadUnaligned(fromByteOffset: 12, as: UInt64.self)) }
            if flags & 1 == 0 { return alloc }
        }
        return extended(path, 0x8)?.0
    }

    /// (bytes deleting this file returns, how many clone copies exist or nil if the system cannot say).
    static func cloneInfo(_ path: String) -> (Int64?, Int?) {
        guard fast else { return (nil, nil) }
        if copies {
            if let (priv, n) = extended(path, 0x8 | 0x1000) { return (priv, Int(n)) }
            if errno == EINVAL {
                lock.lock()
                copies = false
                lock.unlock()
            }
        }
        return (privateBytes(path), nil)
    }

    struct Measure {
        var bytes: Int64 = 0
        var returns: Int64 = 0
        var files = 0
        var newest: Int64 = 0
        var partial = false
    }

    /// One folder tree measured on the spot. Clones whose every copy sits inside the tree count
    /// once toward what deleting returns. Stops early at `deadline` and says so.
    static func measure(_ path: String, deadline: Date? = nil) -> Measure {
        var m = Measure()
        var priv: Int64 = 0
        var groups: [UInt64: (shared: Int64, seen: Int, copies: Int?)] = [:]
        var stack = [path]
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buf.deallocate() }
        while let dir = stack.popLast() {
            if let deadline, Date() > deadline {
                m.partial = true
                break
            }
            guard let entries = try? readDir(dir, buffer: buf) else { continue }
            for e in entries {
                if !e.isDir {
                    var pv = e.bytes
                    if e.mayShare, e.bytes > 0 {
                        let (p, n) = cloneInfo(dir + "/" + e.name)
                        if let p, p < e.bytes {
                            pv = p
                            if var g = groups[e.cloneID] {
                                g.shared = max(g.shared, e.bytes - p)
                                g.seen += 1
                                groups[e.cloneID] = g
                            } else {
                                groups[e.cloneID] = (e.bytes - p, 1, n)
                            }
                        }
                    }
                    m.bytes += e.bytes
                    priv += pv
                    m.files += 1
                    m.newest = max(m.newest, e.mtime)
                } else if e.skip == .none {
                    stack.append(dir + "/" + e.name)
                }
            }
        }
        // shared space comes back only when every copy of the clone is inside this tree
        for g in groups.values where g.seen > 1 && (g.copies == nil || g.seen >= g.copies!) { priv += g.shared }
        m.returns = min(m.bytes, priv)
        return m
    }
}
