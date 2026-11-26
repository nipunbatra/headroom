// The list every page uses: rows with a tick box for the cleanup list, native
// multi-selection, a context menu, Quick Look on Space and Clean on Delete.
import AppKit
import SwiftUI

@MainActor enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ path: String) -> NSImage {
        if let hit = cache[path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: expandTilde(path))
        cache[path] = image
        return image
    }
}

private struct FlatSection: Identifiable {
    var section: RowSection
    var rows: [FlatRow]
    var id: String { section.id }
}

@MainActor struct RowList: View {
    @Environment(AppModel.self) private var model
    let sections: [RowSection]
    var header: AnyView?            // a summary shown above the first section, scrolling with the rows
    @State private var selection: Set<String> = []

    var body: some View {
        let flats = sections.map { FlatSection(section: $0, rows: model.flatten($0.rows, prefix: $0.id + "/")) }
        let index = Dictionary(flats.flatMap(\.rows).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        Group {
            if header == nil, flats.allSatisfy(\.rows.isEmpty), !model.search.isEmpty {
                ContentUnavailableView.search(text: model.search)
                    .onAppear { selection.removeAll(); model.highlighted = [] }
            } else {
                List(selection: $selection) {
                    if let header {
                        header.selectionDisabled().listRowSeparator(.hidden)
                    }
                    ForEach(flats) { sec in
                        Section {
                            if sec.rows.isEmpty {
                                Text(sec.section.empty.isEmpty ? "Nothing here." : sec.section.empty)
                                    .foregroundStyle(.secondary)
                                    .selectionDisabled()
                            }
                            ForEach(sec.rows) { flat in
                                RowView(flat: flat)
                                    .tag(flat.id)
                                    .selectionDisabled(flat.row.note)
                            }
                        } header: {
                            SectionHeader(section: sec.section)
                        }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { ids in
                    RowMenu(flats: ids.compactMap { index[$0] })
                } primaryAction: { ids in
                    guard ids.count == 1, let flat = ids.first.flatMap({ index[$0] }) else { return }
                    if model.page == .map, let p = flat.row.mapPath {
                        model.zoom(p)
                    } else if flat.expandable {
                        model.toggleExpanded(flat.id, browse: flat.row.browse)
                    } else if let p = flat.row.reveal {
                        model.preview(p)
                    }
                }
                .onChange(of: selection) { _, new in
                    model.highlighted = new.compactMap { index[$0]?.row }.filter { !$0.note }
                }
                .onChange(of: flats.flatMap(\.rows).map(\.id)) { _, visible in
                    selection.formIntersection(visible)
                    model.highlighted = selection.compactMap { index[$0]?.row }.filter { !$0.note }
                }
                .onDeleteCommand { model.review(model.highlighted.compactMap(\.cleanID)) }
                .onKeyPress(.space) {
                    guard let p = model.highlighted.first?.reveal else { return .ignored }
                    model.preview(p)
                    return .handled
                }
                .onDisappear { model.highlighted = [] }
            }
        }
    }
}

@MainActor private struct SectionHeader: View {
    @Environment(AppModel.self) private var model
    let section: RowSection

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title).font(.headline).foregroundStyle(.primary)
                if !section.subtitle.isEmpty {
                    Text(section.subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.m)
            ForEach(section.bulk) { action in
                BulkButton(action: action)
            }
        }
        .textCase(nil)
        .padding(.vertical, 6)
    }
}

@MainActor struct BulkButton: View {
    @Environment(AppModel.self) private var model
    let action: BulkAction

    var body: some View {
        let live = action.ids.filter { model.candidates[$0] != nil }
        let allIn = !live.isEmpty && live.allSatisfy(model.inPlan)
        Button(allIn ? "Remove from List" : action.label) { model.togglePlan(live) }
            .controlSize(.small)
            .disabled(live.isEmpty)
            .help(action.help)
    }
}

/// The same commands for one row or many, wherever a row can be acted on.
@MainActor struct RowMenu: View {
    @Environment(AppModel.self) private var model
    let flats: [FlatRow]

    var body: some View {
        let rows = flats.map(\.row).filter { !$0.note }
        let ids = rows.compactMap(\.cleanID).filter { model.candidates[$0] != nil }
        let paths = rows.compactMap(\.reveal)
        if !ids.isEmpty {
            Button(ids.allSatisfy(model.inPlan) ? "Remove from Cleanup List" : "Add to Cleanup List") { model.togglePlan(ids) }
            Button(ids.count == 1 ? "Clean…" : "Clean \(ids.count) Items…") { model.review(ids) }
            Divider()
        }
        if flats.count == 1, let flat = flats.first, !flat.row.note {
            if let id = flat.row.cleanID, id.hasPrefix("rule:"), model.candidates[id]?.safety == "safe" {
                let skipped = model.skippedRules.contains(id)
                Button(skipped ? "Include in Quick Cleanup" : "Skip in Quick Cleanup") {
                    model.includeInQuickCleanup(id, skipped)
                }
            }
            if flat.expandable {
                Button(flat.expanded ? "Hide Contents" : "Look Inside") { model.toggleExpanded(flat.id, browse: flat.row.browse) }
            }
            if let p = flat.row.mapPath, model.page != .map || p != model.mapNode?.path {
                Button("Show in Disk Map") { model.zoom(p) }
            }
            if let p = flat.row.reveal {
                Button("Quick Look") { model.preview(p) }
            }
        }
        if !paths.isEmpty {
            Button("Show in Finder") { model.reveal(paths) }
            Button(paths.count == 1 ? "Copy Path" : "Copy \(paths.count) Paths") { model.copyPaths(paths) }
        }
    }
}

@MainActor struct RowView: View {
    @Environment(AppModel.self) private var model
    let flat: FlatRow
    @State private var hover = false

    private var row: Row { flat.row }
    private var indent: CGFloat { CGFloat(flat.depth) * 22 }

    var body: some View {
        if row.note { note } else { item }
    }

    private var note: some View {
        HStack(spacing: Space.s) {
            if row.loading { ProgressView().controlSize(.small) }
            Text(row.title).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s)
            if let action = row.action { BulkButton(action: action) }
        }
        .padding(.leading, indent + 46)
        .padding(.vertical, 2)
    }

    private var item: some View {
        let cleared = model.isCleared(row)
        let cleanable = model.isCleanable(row)
        return HStack(alignment: .top, spacing: Space.s) {
            Button {
                model.toggleExpanded(flat.id, browse: row.browse)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(flat.expanded ? 90 : 0))
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(flat.expandable ? 1 : 0)
            .disabled(!flat.expandable)
            .help(flat.expanded ? "Hide what is inside" : "Show what is inside")
            .accessibilityLabel(flat.expanded ? "Hide contents of \(row.title)" : "Look inside \(row.title)")

            check(cleared: cleared, cleanable: cleanable)

            if let app = row.appPath {
                Image(nsImage: AppIcons.icon(app)).resizable().frame(width: 28, height: 28).accessibilityHidden(true)
            }
            if let swatch = row.swatch {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(swatch).frame(width: 10, height: 10).padding(.top, 4)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title).lineLimit(1).truncationMode(.middle).help(row.title)
                    if cleared { PillView(pill: Pill(text: "Cleaned", kind: .safe)) } else {
                        ForEach(row.pills, id: \.self) { PillView(pill: $0) }
                    }
                }
                if !row.why.isEmpty {
                    Text(row.why).font(.callout).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                if !row.path.isEmpty {
                    Text(row.path).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).help(row.path)
                }
                if !row.cmd.isEmpty {
                    Text("$ " + row.cmd).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .help("Cleaning runs this command: " + row.cmd)
                }
                if let link = row.link {
                    Button("Open \(link.title)") { model.go(link) }.buttonStyle(.link).font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Clean…") { if let id = row.cleanID { model.review([id]) } }
                .controlSize(.small)
                .opacity(hover && cleanable ? 1 : 0)
                .disabled(!cleanable)
                .help("Review what cleaning this does, then confirm")
                .accessibilityHidden(!cleanable)

            VStack(alignment: .trailing, spacing: 2) {
                Text((row.approx ? "at least " : "") + (row.amount ?? fmt(row.bytes))).monospacedDigit().fontWeight(.medium)
                if let disk = row.disk, row.amount == nil, row.bytes < disk * 9 / 10 {
                    Text("of \(fmt(disk)) on disk").font(.caption).foregroundStyle(.secondary)
                        .help("Cleaning this returns \(fmt(row.bytes)). The rest of its \(fmt(disk)) is shared with cloned copies kept elsewhere.")
                }
                if !row.meta.isEmpty {
                    Text(row.meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                MiniBar(fraction: Double(row.bytes) / Double(max(1, flat.max))).frame(width: 96).padding(.top, 2)
            }
            .frame(minWidth: 105, alignment: .trailing)
        }
        .padding(.leading, indent)
        .padding(.vertical, 3)
        .opacity(cleared ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    @ViewBuilder private func check(cleared: Bool, cleanable: Bool) -> some View {
        if cleared {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.safe.color).frame(width: 16, height: 18)
                .help("Cleaned").accessibilityLabel("Cleaned")
        } else if cleanable, let id = row.cleanID {
            Toggle("Add \(row.title) to the cleanup list",
                   isOn: Binding(get: { model.inPlan(id) }, set: { model.setPlan([id], $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 16, height: 18)
                .help("Add to the cleanup list")
        } else {
            Color.clear.frame(width: 16, height: 18)
        }
    }
}
