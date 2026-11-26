// The disk map: a squarified treemap. Area is size on disk; each colour is one
// folder at the current level. Click a block to step inside.
import SwiftUI

struct MapTile: Identifiable {
    var id: Int
    var rect: CGRect
    var name: String
    var full: String
    var bytes: Int64
    var files: Int?
    var returns: Int64?
    var slot: Int
    var rest = false
    var header = false
    var label = false
    var zoom: String?
    var path: String?
}

enum Treemap {
    private struct Part {
        var node: Node?
        var value: Double
        var index: Int
    }

    private static func squarify(_ items: [Part], _ box: CGRect) -> [(Part, CGRect)] {
        let total = items.reduce(0) { $0 + $1.value }
        guard total > 0, box.width > 0, box.height > 0 else { return [] }
        let k = Double(box.width * box.height) / total
        var rect = box
        var row: [(Part, Double)] = []
        var out: [(Part, CGRect)] = []
        func worst(_ r: [(Part, Double)], _ side: Double) -> Double {
            let s = r.reduce(0) { $0 + $1.1 }
            let mx = r.map(\.1).max() ?? 0, mn = r.map(\.1).min() ?? 1
            return max(side * side * mx / (s * s), s * s / (side * side * mn))
        }
        func flush() {
            let s = row.reduce(0) { $0 + $1.1 }
            if rect.width >= rect.height {
                let cw = CGFloat(s) / rect.height
                var cy = rect.minY
                for (p, a) in row {
                    let ch = CGFloat(a) / cw
                    out.append((p, CGRect(x: rect.minX, y: cy, width: cw, height: ch)))
                    cy += ch
                }
                rect = CGRect(x: rect.minX + cw, y: rect.minY, width: rect.width - cw, height: rect.height)
            } else {
                let ch = CGFloat(s) / rect.width
                var cx = rect.minX
                for (p, a) in row {
                    let cw = CGFloat(a) / ch
                    out.append((p, CGRect(x: cx, y: rect.minY, width: cw, height: ch)))
                    cx += cw
                }
                rect = CGRect(x: rect.minX, y: rect.minY + ch, width: rect.width, height: rect.height - ch)
            }
            row = []
        }
        for item in items {
            let cell = (item, item.value * k)
            let side = Double(min(rect.width, rect.height))
            if !row.isEmpty, worst(row + [cell], side) > worst(row, side) { flush() }
            row.append(cell)
        }
        if !row.isEmpty { flush() }
        return out
    }

    private static func parts(_ node: Node, area: CGFloat) -> [Part] {
        let total = Double(max(node.s, 1))
        let floor = total * 40 / Double(max(area, 1))
        var rest = Double(node.s - node.children.reduce(0) { $0 + $1.s })
        var out: [Part] = []
        for (i, k) in node.children.enumerated() {
            if Double(k.s) >= floor { out.append(Part(node: k, value: Double(k.s), index: i)) } else { rest += Double(k.s) }
        }
        if rest >= floor, !out.isEmpty { out.append(Part(node: nil, value: rest, index: -1)) }
        return out.sorted { $0.value > $1.value }
    }

    static func layout(_ node: Node, size: CGSize) -> [MapTile] {
        var tiles: [MapTile] = []
        func add(_ t: MapTile) {
            var t = t
            t.id = tiles.count
            tiles.append(t)
        }
        let groups = parts(node, area: size.width * size.height)
        if groups.isEmpty {
            add(MapTile(id: 0, rect: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1), name: node.n, full: node.n, bytes: node.s,
                        files: node.f, returns: node.r, slot: 1, label: true, path: node.path))
            return tiles
        }
        for (g, box) in squarify(groups, CGRect(origin: .zero, size: size)) {
            let gname = g.node?.n ?? "Smaller items"
            let slot = g.node == nil ? 0 : (g.index < 7 ? g.index + 1 : 0)
            let hasKids = !(g.node?.children.isEmpty ?? true)
            let hdr: CGFloat = hasKids && box.width > 70 && box.height > 52 ? 20 : 0
            if hdr > 0, let n = g.node {
                add(MapTile(id: 0, rect: CGRect(x: box.minX, y: box.minY, width: box.width, height: hdr), name: gname, full: gname,
                            bytes: n.s, files: n.f, returns: n.r, slot: slot, header: true, zoom: n.path, path: n.path))
            }
            let inner = CGRect(x: box.minX, y: box.minY + hdr, width: box.width, height: box.height - hdr)
            let kids = hasKids ? squarify(parts(g.node!, area: inner.width * inner.height), inner) : []
            if kids.isEmpty {
                add(MapTile(id: 0, rect: inner.insetBy(dx: 1, dy: 1), name: gname, full: gname, bytes: Int64(g.value), files: g.node?.f,
                            returns: g.node?.r, slot: slot, rest: g.node == nil, label: box.width > 86 && box.height > 32,
                            zoom: g.node?.path, path: g.node?.path))
            }
            for (t, r) in kids {
                let tname = t.node?.n ?? "Smaller items"
                let target = t.node.map { $0.children.isEmpty ? g.node!.path : $0.path } ?? g.node!.path
                add(MapTile(id: 0, rect: r.insetBy(dx: 1, dy: 1), name: tname, full: gname + " / " + tname, bytes: Int64(t.value),
                            files: t.node?.f, returns: t.node?.r, slot: slot, rest: t.node == nil, label: r.width > 86 && r.height > 32,
                            zoom: target, path: t.node?.path))
            }
        }
        return tiles
    }
}

@MainActor struct TreemapView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let node: Node
    @State private var hover: Int?
    @State private var pointer = CGPoint.zero

    var body: some View {
        GeometryReader { geo in
            let tiles = Treemap.layout(node, size: geo.size)
            let hit = hover.flatMap { tiles.indices.contains($0) ? tiles[$0] : nil }
            Canvas { ctx, _ in
                for t in tiles {
                    let swatch = Palette.series[t.slot]
                    if t.header {
                        var c = ctx
                        c.clip(to: Path(t.rect))
                        let text = Text(t.name).font(.caption.weight(.semibold)).foregroundColor(.primary)
                            + Text("  " + fmt(t.bytes)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        c.draw(text, at: CGPoint(x: t.rect.minX + 4, y: t.rect.midY), anchor: .leading)
                        continue
                    }
                    guard t.rect.width > 0, t.rect.height > 0 else { continue }
                    let shape = Path(roundedRect: t.rect, cornerRadius: min(4, min(t.rect.width, t.rect.height) / 3))
                    ctx.fill(shape, with: .color(swatch.color.opacity(t.rest ? 0.45 : 1)))
                    if t.label {
                        var c = ctx
                        c.clip(to: Path(t.rect.insetBy(dx: 4, dy: 3)))
                        let ink = t.rest ? Color.primary : swatch.ink(scheme)
                        c.draw(Text(t.name).font(.caption.weight(.medium)).foregroundColor(ink),
                               at: CGPoint(x: t.rect.minX + 6, y: t.rect.minY + 5), anchor: .topLeading)
                        c.draw(Text(fmt(t.bytes)).font(.caption.monospacedDigit()).foregroundColor(ink.opacity(0.85)),
                               at: CGPoint(x: t.rect.minX + 6, y: t.rect.minY + 20), anchor: .topLeading)
                    }
                }
                if let h = hit {
                    ctx.stroke(Path(roundedRect: h.rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: h.header ? 2 : 4),
                               with: .color(.primary), lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    pointer = p
                    hover = tiles.last { $0.rect.contains(p) }?.id
                case .ended:
                    hover = nil
                }
            }
            .onTapGesture(count: 1) { (p: CGPoint) in
                if let z = tiles.last(where: { $0.rect.contains(p) })?.zoom { model.zoom(z) }
            }
            .contextMenu {
                if let p = hit?.path {
                    let id = "file:" + p
                    if model.candidates[id] != nil {
                        Button(model.inPlan(id) ? "Remove from Cleanup List" : "Add to Cleanup List") { model.togglePlan([id]) }
                        Button("Clean…") { model.review([id]) }
                        Divider()
                    }
                    Button("Show in Finder") { model.reveal([p]) }
                    Button("Copy Path") { model.copyPaths([p]) }
                }
            }
            .overlay(alignment: .topLeading) {
                if let h = hit {
                    tooltip(h)
                        .offset(x: min(pointer.x + 14, max(0, geo.size.width - 270)), y: min(pointer.y + 18, max(0, geo.size.height - 96)))
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityLabel("Disk map of \(node.n). The list below holds the same folders.")
    }

    private func tooltip(_ t: MapTile) -> some View {
        let share = node.s > 0 ? Double(t.bytes) / Double(node.s) * 100 : 0
        return VStack(alignment: .leading, spacing: 2) {
            Text(t.full).fontWeight(.semibold).lineLimit(2)
            Text("\(fmt(t.bytes)) · \(String(format: "%.1f", share))% of this view").monospacedDigit().foregroundStyle(.secondary)
            if let f = t.files, f > 0 { Text(plural(f, "file")).foregroundStyle(.secondary) }
            if let r = t.returns, r < t.bytes * 9 / 10 {
                Text("Deleting returns \(fmt(r)); the rest is shared with clones").foregroundStyle(.secondary)
            }
            if t.rest { Text("Folders under the map's size cutoff").foregroundStyle(.secondary) }
        }
        .font(.callout)
        .padding(8)
        .frame(maxWidth: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}

@MainActor struct MapView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let node = model.mapNode {
            VSplitView {
                VStack(alignment: .leading, spacing: Space.s) {
                    crumbs(node)
                    TreemapView(node: node)
                }
                .padding([.horizontal, .bottom], Space.m)
                .padding(.top, Space.s)
                .frame(minHeight: 220, idealHeight: 380)

                RowList(sections: [RowSection(id: "map", title: "Inside \(node.n)",
                                              subtitle: fmt(node.s) + (node.f.map { " in " + plural($0, "file") } ?? "")
                                                + ". Area in the map is size on disk.",
                                              rows: model.mapRows(node), empty: "Nothing larger than the map's cutoff in here.")])
                    .frame(minHeight: 160)
            }
        }
    }

    private func chain(_ node: Node) -> [Node] {
        var out: [Node] = []
        var n: Node? = node
        while let x = n {
            out.insert(x, at: 0)
            n = x.parent
        }
        return out
    }

    private func crumbs(_ node: Node) -> some View {
        let path = chain(node)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(path) { n in
                    if n === node {
                        Text(n.n).fontWeight(.semibold)
                    } else {
                        Button(n.n) { model.zoom(n.path) }.buttonStyle(.link).help("Go up to \(n.path)")
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .font(.callout)
        }
    }
}
