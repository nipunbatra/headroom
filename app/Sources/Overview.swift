// The first page: how full the disk is, what fills it, and the one button that matters.
import Charts
import SwiftUI

/// Headroom's signature: the disk as a level meter, each tick an equal slice coloured by what fills it.
@MainActor struct LevelMeter: View {
    struct Segment: Identifiable {
        let id: String
        let label: String
        let bytes: Int64
        let color: Color
    }

    let segments: [Segment]
    let total: Int64
    @Binding var hover: String?

    private func ticks(_ n: Int) -> [Segment] {
        guard total > 0, let last = segments.last else { return [] }
        var out = [Segment?](repeating: nil, count: n)
        var acc: Int64 = 0
        for s in segments {
            let a = Int((Double(acc) / Double(total) * Double(n)).rounded())
            acc += s.bytes
            let z = s.id == "free" ? n : Int((Double(acc) / Double(total) * Double(n)).rounded())
            for i in max(0, min(a, n))..<max(0, min(max(a, z), n)) { out[i] = s }
        }
        let fallback = segments.count > 1 ? segments[segments.count - 2] : last
        return out.map { $0 ?? fallback }
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let n = max(24, min(96, Int(geo.size.width / 11)))
                let cells = ticks(n)
                let gap: CGFloat = 3
                let w = (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n)
                Canvas { ctx, size in
                    for (i, seg) in cells.enumerated() {
                        let rect = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: size.height)
                        let path = Path(roundedRect: rect, cornerRadius: 2.5)
                        let dim = hover != nil && hover != seg.id
                        if seg.id == "free" {
                            ctx.fill(path, with: .color(Palette.track.color.opacity(dim ? 0.5 : 1)))
                            ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2.5),
                                       with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                        } else {
                            ctx.fill(path, with: .color(seg.color.opacity(dim ? 0.35 : 1)))
                        }
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let i = Int(p.x / (w + gap))
                        hover = cells.indices.contains(i) ? cells[i].id : nil
                    case .ended:
                        hover = nil
                    }
                }
            }
            .frame(height: 30)
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Spacer()
                    VStack(spacing: 2) {
                        Rectangle().fill(.secondary.opacity(0.6)).frame(height: 1)
                        Text("last 10%").font(.caption2).foregroundStyle(.secondary).fixedSize()
                    }
                    .frame(width: geo.size.width * 0.1)
                }
            }
            .frame(height: 18)
        }
        .accessibilityElement()
        .accessibilityLabel("How full the disk is, by what fills it")
        .accessibilityValue(segments.map { "\($0.label) \(fmt($0.bytes))" }.joined(separator: ", "))
    }
}

/// Lays children out left to right and wraps to a new line when they run out of room.
struct FlowLayout: Layout {
    var spacing: CGFloat = 16
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, point) in zip(subviews, arrange(width: bounds.width, subviews: subviews).points) {
            view.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let s = view.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width {
                x = 0
                y += line + lineSpacing
                line = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            line = max(line, s.height)
            widest = max(widest, x - spacing)
        }
        return (points, CGSize(width: widest, height: y + line))
    }
}

/// Named amounts as horizontal bars, largest first.
@MainActor struct BarList: View {
    struct Item: Identifiable {
        let id: String
        let name: String
        let bytes: Int64
        var note = ""
        var action: (() -> Void)?
    }

    let items: [Item]

    var body: some View {
        let top = max(1, items.map(\.bytes).max() ?? 1)
        VStack(spacing: 6) {
            ForEach(items) { item in
                BarRow(item: item, top: top)
            }
        }
    }

    private struct BarRow: View {
        let item: Item
        let top: Int64
        @State private var hover = false

        var body: some View {
            let line = HStack(spacing: Space.s) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(item.action != nil && hover ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .frame(width: 150, alignment: .leading)
                MiniBar(fraction: Double(item.bytes) / Double(top), color: .accentColor.opacity(0.8)).frame(height: 6)
                Text(fmt(item.bytes)).monospacedDigit().foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .help(item.note.isEmpty ? "\(item.name): \(fmt(item.bytes))" : "\(item.name): \(fmt(item.bytes)). \(item.note)")
            if let action = item.action {
                Button(action: action) { line }.buttonStyle(.plain)
            } else {
                line
            }
        }
    }
}

/// Free space at each scan and reading. One series, so the card title names it.
@MainActor struct FreeSpaceChart: View {
    let samples: [Sample]
    @Binding var hover: Sample?

    private func gb(_ s: Sample) -> Double { Double(s.free) / 1e9 }

    var body: some View {
        let values = samples.map(gb)
        let lo = max(0, (values.min() ?? 0) - 5), hi = (values.max() ?? 1) + 5
        Chart {
            ForEach(samples) { s in
                LineMark(x: .value("Date", s.date), y: .value("Free", gb(s)))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Color.accentColor)
            }
            ForEach(samples.filter { $0.scan != nil }) { s in
                PointMark(x: .value("Date", s.date), y: .value("Free", gb(s)))
                    .symbolSize(40)
                    .foregroundStyle(Color.accentColor)
            }
            if let h = hover {
                RuleMark(x: .value("Date", h.date)).foregroundStyle(.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Date", h.date), y: .value("Free", gb(h))).symbolSize(90).foregroundStyle(Color.accentColor)
            }
        }
        .chartYScale(domain: lo...hi)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text("\(Int(v)) GB") }
                }
            }
        }
        .chartXAxis {
            // Readings a few hours apart need the time of day; weeks of them need only the date.
            let short = (samples.last?.t ?? 0) - (samples.first?.t ?? 0) < 4 * 86400
            AxisMarks(values: .automatic(desiredCount: short ? 2 : 4)) { _ in
                AxisValueLabel(format: short ? .dateTime.day().month(.abbreviated).hour() : .dateTime.month(.abbreviated).day())
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            guard let frame = proxy.plotFrame else { return }
                            let x = p.x - geo[frame].origin.x
                            guard let date: Date = proxy.value(atX: x) else { return }
                            hover = samples.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                        case .ended:
                            hover = nil
                        }
                    }
            }
        }
        .frame(height: 140)
        .accessibilityLabel("Free space over time")
    }
}

@MainActor struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var hoverSegment: String?
    private enum Panel: String, CaseIterable {
        case review = "Review", items = "Cleanup items", places = "Folders", kinds = "File types", notes = "Scan notes"
    }
    @State private var panel = Panel.review

    var body: some View {
        if !model.search.isEmpty {
            RowList(sections: searchSections)
        } else if let scan = model.scan {
            ViewThatFits(in: .vertical) {
                dashboard(scan).fixedSize(horizontal: false, vertical: true)
                ScrollView { dashboard(scan) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func dashboard(_ scan: Scan) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            hero(scan)
            Picker("Overview section", selection: $panel) {
                ForEach(Panel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            switch panel {
            case .review: reviewCard(scan)
            case .items: winsCard
            case .places: placesCard(scan)
            case .kinds: kindsCard(scan)
            case .notes: notesCard(scan)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: 1000, alignment: .leading)
    }

    /// Typing in the search field from here looks through every page at once.
    private var searchSections: [RowSection] {
        func tagged(_ prefix: String, _ sections: [RowSection]) -> [RowSection] {
            sections.filter { !$0.rows.isEmpty }.map { s in
                var s = s
                s.id = prefix + s.id
                s.subtitle = ""
                s.bulk = []
                return s
            }
        }
        return tagged("c/", model.cleanupSections()) + tagged("f/", model.fileSections()) + tagged("p/", model.projectSections())
            + tagged("d/", model.downloadSections()) + tagged("a/", model.appSections())
    }

    private var segments: [LevelMeter.Segment] {
        let t = model.totals
        var segs = [
            LevelMeter.Segment(id: "safe", label: "Safe to clear", bytes: t.safe, color: Palette.safe.color),
            LevelMeter.Segment(id: "review", label: "Worth reviewing", bytes: t.review, color: Palette.review.color),
            LevelMeter.Segment(id: "files", label: "Everything else scanned", bytes: t.files, color: Palette.series[1].color),
            LevelMeter.Segment(id: "system", label: "System and unreadable", bytes: t.system, color: Palette.series[0].color),
        ].filter { $0.bytes > 0 }
        segs.append(LevelMeter.Segment(id: "free", label: "Free", bytes: model.free, color: Palette.track.color))
        return segs
    }

    private func hero(_ scan: Scan) -> some View {
        let safe = model.safeItems
        let safeTotal = model.totalOf(safe)
        return Card {
            HStack(alignment: .top, spacing: Space.l) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Startup disk", systemImage: "internaldrive").font(.headline).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                            Text(fmt(model.free)).font(.system(size: 42, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text("available").font(.title2).foregroundStyle(.secondary)
                        }
                        Text("\(fmt(model.free)) free").font(.title.bold()).monospacedDigit()
                    }
                    Text("\(fmt(model.totals.used)) used of \(fmt(model.total))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: Space.m)
                if !safe.isEmpty {
                    VStack(alignment: .trailing, spacing: 6) {
                        Button("Quick Cleanup…") { model.reviewSafe() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .help("Review the caches and build folders that rebuild themselves, then confirm (⇧⌘K)")
                        Text("Review up to \(fmt(safeTotal))").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            LevelMeter(segments: segments, total: model.total, hover: $hoverSegment)
            FlowLayout {
                ForEach(segments) { s in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(s.color)
                            .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(.secondary.opacity(s.id == "free" ? 0.4 : 0), lineWidth: 1))
                            .frame(width: 10, height: 10)
                        Text(s.label).foregroundStyle(.secondary)
                        Text(fmt(s.bytes)).monospacedDigit().fontWeight(hoverSegment == s.id ? .bold : .medium)
                    }
                    .font(.callout)
                    .opacity(hoverSegment == nil || hoverSegment == s.id ? 1 : 0.5)
                }
            }
        }
    }

    private func reviewCard(_ scan: Scan) -> some View {
        let downloads = (scan.downloads ?? []).filter { !model.cleared.contains("file:" + $0.path) }
        let installers = downloads.filter(\.installer)
        let old = downloads.filter { $0.mtime > 0 && model.days($0.mtime) > 365 }
        let groups = model.remainingDuplicateGroups
        let idle = (scan.found ?? []).filter { model.foundSafety($0) == "safe" && !model.cleared.contains("file:" + $0.path) }
        return Card("Where to start") {
            VStack(spacing: 0) {
                route("Installers", symbol: "shippingbox", detail: plural(installers.count, "download"),
                      bytes: installers.reduce(0) { $0 + $1.returns }, page: .downloads, focus: .installers)
                Divider()
                route("Older downloads", symbol: "calendar", detail: "Last changed over a year ago",
                      bytes: old.reduce(0) { $0 + $1.returns }, page: .downloads, focus: .older)
                Divider()
                route("Idle build folders", symbol: "hammer", detail: "Projects quiet for over 90 days",
                      bytes: idle.reduce(0) { $0 + $1.returns }, page: .projects, focus: .idle)
                Divider()
                route("Duplicate groups", symbol: "doc.on.doc", detail: plural(groups.count, "group"),
                      bytes: groups.reduce(0) { $0 + $1.extraBytes }, page: .files, focus: .duplicates)
            }
        }
    }

    private func route(_ title: String, symbol: String, detail: String, bytes: Int64, page: Page, focus: ReviewFocus) -> some View {
        Button { model.go(page, focus: focus) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.tint).frame(width: 27, height: 27)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text(fmt(bytes)).monospacedDigit().foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Review " + title.lowercased())
    }

    private var winsCard: some View {
        let wins = model.flatten(model.wins(), prefix: "wins/")
        return Card("Largest cleanup items",
                    trailing: AnyView(Button("See All") { model.go(.cleanup) }.controlSize(.small))) {
            VStack(spacing: 0) {
                ForEach(wins) { flat in
                    RowView(flat: flat)
                        .contextMenu { RowMenu(flats: [flat]) }
                    if flat.id != wins.last?.id { Divider().padding(.leading, 46) }
                }
                if wins.isEmpty { Text("Nothing worth clearing was found.").foregroundStyle(.secondary) }
            }
        }
    }

    private func placesCard(_ scan: Scan) -> some View {
        let base = model.homeNode ?? scan.tree
        var nodes = base.children
        if model.homeNode != nil && base !== scan.tree { nodes += scan.tree.children.filter { $0.n != "Users" } }
        let items = nodes.sorted { $0.s > $1.s }.prefix(9).map { n in
            BarList.Item(id: n.path, name: n.path, bytes: n.s, note: "Click to open it in the disk map", action: { model.zoom(n.path) })
        }
        return Card("Where the Space Is", subtitle: "Largest folders. Click one to open it in the map.") {
            BarList(items: Array(items))
        }
    }

    private func kindsCard(_ scan: Scan) -> some View {
        Card("By Kind of File") {
            BarList(items: scan.kinds.prefix(8).map { BarList.Item(id: $0.kind, name: $0.kind, bytes: $0.bytes, note: plural($0.files, "file")) })
        }
    }

    private func notesCard(_ scan: Scan) -> some View {
        var notes: [(String, String)] = []
        notes.append(("\(scan.stats.files.formatted()) files", " in \(scan.stats.dirs.formatted()) folders were measured in \(Int(scan.seconds.rounded())) seconds. Scanning changes nothing."))
        if let unique = scan.disk.unique, scan.disk.scanned - unique > GB {
            notes.append(("\(fmt(scan.disk.scanned - unique)) is shared between cloned files.", " Package managers, Finder duplicates and browser updates make copies that share space. Estimates take shared blocks into account."))
        }
        if model.purgeable > GB {
            notes.append(("macOS can free about \(fmt(model.purgeable)) more on its own.", " Local snapshots and purgeable caches are released when space runs short, so Finder counts them as available."))
        }
        if let git = scan.tagTotals?["git"], git.bytes > 5 * GB {
            notes.append(("Git history takes \(fmt(git.bytes))", " across \(git.count.formatted()) repositories. The largest are listed under Projects; git gc --aggressive shrinks one without losing anything."))
        }
        if model.totals.system > GB {
            notes.append((fmt(model.totals.system), " sits outside what the scan can see: the sealed macOS volume, local snapshots, and folders macOS protects."))
        }
        if let snaps = scan.disk.snapshots, snaps > 0 {
            notes.append((plural(snaps, "local Time Machine snapshot") + ".", " macOS thins them when space runs low."))
        }
        if let dataless = scan.stats.dataless, dataless > 0 {
            notes.append(("\(plural(dataless, "cloud-only folder"))", " \(dataless == 1 ? "was" : "were") skipped. They live in iCloud or a cloud drive and use no local space."))
        }
        let denied = scan.deniedCount ?? 0
        return Card("Notes from the Scan") {
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(notes, id: \.0) { note in
                    (Text(note.0).fontWeight(.semibold) + Text(note.1).foregroundColor(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if denied > 0 {
                    DisclosureGroup(plural(denied, "folder") + " could not be opened") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(scan.denied ?? [], id: \.self) { path in
                                Text(path).font(.caption.monospaced()).textSelection(.enabled)
                            }
                            if denied > (scan.denied?.count ?? 0) {
                                Text("Showing the first \(scan.denied?.count ?? 0) recorded paths.").font(.caption)
                            }
                            if !model.fullDiskAccess {
                                Button("Open Full Disk Access Settings…") { openFullDiskAccess() }.controlSize(.small)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

@MainActor func openFullDiskAccess() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
        NSWorkspace.shared.open(url)
    }
}
