// The main window: sidebar pages, the working pane, and the cleanup list as a trailing inspector.
import QuickLook
import SwiftUI

@MainActor struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailView()
                .inspector(isPresented: $model.showInspector) {
                    CleanupListView().inspectorColumnWidth(min: 240, ideal: 280, max: 380)
                }
        }
        .searchable(text: $model.search, placement: .toolbar,
                    prompt: model.page == .overview ? "Search Everything" : "Filter \(model.page.title)")
        .sheet(item: $model.session) { session in
            CleanSheet(session: session).environment(model)
        }
        .quickLookPreview($model.quickLook)
        .alert("Unable to Finish the Scan", isPresented: Binding(get: { model.scanError != nil }, set: { if !$0 { model.scanError = nil } })) {
            Button("OK") { model.scanError = nil }
        } message: {
            Text((model.scanError ?? "") + " The earlier figures are still shown.")
        }
    }
}

@MainActor private struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding(get: { Optional(model.page) }, set: { if let p = $0 { model.go(p) } })) {
            Section {
                ForEach(Page.main) { row($0) }
            }
            Section("Explore") {
                ForEach(Page.explore) { row($0) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
    }

    private func row(_ page: Page) -> some View {
        Label(page.title, systemImage: page.symbol)
            .badge(badge(page).map { Text($0) })
            .tag(page)
    }

    private func badge(_ page: Page) -> String? {
        guard let scan = model.scan else { return nil }
        switch page {
        case .cleanup: return model.totals.safe > 0 ? fmt(model.totals.safe) : nil
        case .changes: return scan.changes.map { c in c.items.isEmpty ? nil : "\(c.items.count)" } ?? nil
        case .files: return (scan.bigFiles?.count).map { $0.formatted() }
        case .projects: return (scan.found?.count).map { $0.formatted() }
        case .apps: return (scan.apps?.count).map { $0.formatted() }
        default: return nil
        }
    }

    /// A small fact about the disk, not a control.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(fmt(model.free)).fontWeight(.semibold).monospacedDigit()
                Text("free of \(fmt(model.total))").foregroundStyle(.secondary)
            }
            .font(.callout)
            MiniBar(fraction: 1 - model.freeFraction,
                    color: model.freeFraction < 0.03 ? Palette.crit.color : model.freeFraction < 0.10 ? Palette.review.color : .accentColor)
            if model.scanning {
                ProgressView(value: model.scanFraction).controlSize(.small)
                Text(model.progress).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            } else if model.scan != nil {
                Text(model.scannedText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Space.m)
        .accessibilityElement(children: .combine)
    }
}

@MainActor private struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.scan != nil {
                page
            } else if model.scanning {
                ScanningView()
            } else if case .failed(let message) = model.phase {
                ContentUnavailableView {
                    Label("No Scan Yet", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Scan Disk") { model.rescan() }
                }
            } else {
                ProgressView("Opening the last scan").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(model.page.title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                filter
                if model.scanning {
                    Button("Stop Scan", systemImage: "stop.circle") { model.cancelScan() }
                        .help("Stop measuring and keep the current figures (⌘.)")
                } else {
                    Button("Scan", systemImage: "arrow.clockwise") { model.rescan() }
                        .help("Measure the disk again; takes under a minute (⌘R)")
                }
                Button("Cleanup List", systemImage: "checklist") { model.showInspector.toggle() }
                    .help(model.showInspector ? "Hide the cleanup list (⌃⌘I)" : "Show the items ticked for cleaning (⌃⌘I)")
            }
        }
    }

    @ViewBuilder private var page: some View {
        switch model.page {
        case .overview: OverviewView()
        case .cleanup: RowList(sections: model.cleanupSections())
        case .changes: ChangesView()
        case .map: MapView()
        case .files: RowList(sections: model.fileSections())
        case .projects: RowList(sections: model.projectSections())
        case .downloads:
            if model.scan?.downloads == nil {
                ContentUnavailableView("Downloads Could Not Be Read", systemImage: "arrow.down.circle",
                                       description: Text("Allow Headroom to use the Downloads folder in System Settings, then scan again."))
            } else {
                RowList(sections: model.downloadSections())
            }
        case .apps: RowList(sections: model.appSections())
        }
    }

    @ViewBuilder private var filter: some View {
        @Bindable var model = model
        if model.scan != nil {
            switch model.page {
            case .cleanup:
                Picker("Category", selection: $model.group) {
                    Text("All Categories").tag("all")
                    ForEach(model.ruleGroups, id: \.self) { Text(AppModel.groupNames[$0] ?? $0).tag($0) }
                }
                .help("Show one kind of place")
            case .files:
                Picker("Kind", selection: $model.kind) {
                    Text("All Kinds").tag("all")
                    ForEach(model.fileKinds, id: \.self) { Text($0).tag($0) }
                }
                .help("Show one kind of file")
                sortPicker(dates: true)
            case .projects:
                Picker("Folder Type", selection: $model.tag) {
                    Text("All Types").tag("all")
                    ForEach(model.projectTags, id: \.self) { Text(model.tagLabel($0)).tag($0) }
                }
                .help("Show one kind of project folder")
                sortPicker(dates: true)
            case .map:
                Button("Enclosing Folder", systemImage: "chevron.up") {
                    if let p = model.mapNode?.parent { model.zoom(p.path) }
                }
                .disabled(model.mapNode?.parent == nil)
                .help("Go up one level in the map (⌘↑)")
            case .downloads:
                sortPicker(dates: true)
            case .apps:
                sortPicker(dates: false)
            default:
                EmptyView()
            }
        }
    }

    private func sortPicker(dates: Bool) -> some View {
        @Bindable var model = model
        return Picker("Sort", selection: $model.sort) {
            Text("Largest First").tag("size")
            if dates {
                Text("Newest First").tag("newest")
                Text("Oldest First").tag("oldest")
            }
            Text("By Name").tag("name")
        }
        .help("Change the order of the list")
    }

    private var subtitle: String {
        if model.scanning { return model.progress }
        guard let scan = model.scan else { return "" }
        switch model.page {
        case .overview: return model.scannedText
        case .cleanup: return "\(fmt(model.totals.safe)) safe to clear"
        case .changes:
            return scan.changes.map { "Since " + Date(timeIntervalSince1970: $0.since).formatted(date: .abbreviated, time: .shortened) } ?? "No earlier scan"
        case .map: return model.mapNode.map { "\($0.path == "/" ? "Macintosh HD" : $0.path) · \(fmt($0.s))" } ?? ""
        case .files: return plural(scan.bigFiles?.count ?? 0, "file") + " of 50 MB or more"
        case .projects: return plural(scan.found?.count ?? 0, "folder")
        case .downloads: return fmt(model.nodes["~/Downloads"]?.s ?? (scan.downloads ?? []).reduce(0) { $0 + $1.bytes })
        case .apps: return plural((scan.apps ?? []).count, "app")
        }
    }
}

@MainActor private struct ScanningView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Space.l) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                Canvas { ctx, size in
                    let n = 48
                    let gap: CGFloat = 3
                    let w = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
                    let t = context.date.timeIntervalSinceReferenceDate
                    for i in 0..<n {
                        let wave = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(t * 2.6 - Double(i) * 0.28)
                        let rect = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: size.height)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(Color.accentColor.opacity(0.15 + 0.6 * wave)))
                    }
                }
            }
            .frame(width: 420, height: 36)
            .accessibilityHidden(true)
            VStack(spacing: Space.s) {
                Text("Measuring Every Folder").font(.title2).fontWeight(.semibold)
                if model.expectedFiles > 0 {
                    ProgressView(value: model.scanFraction).frame(width: 420)
                } else {
                    ProgressView().progressViewStyle(.linear).frame(width: 420)
                }
                Text(model.progress + (model.scanRate > 0 ? " · \(model.scanRate.formatted()) a second" : ""))
                    .monospacedDigit().foregroundStyle(.secondary)
                Text(model.scanPath.isEmpty ? " " : model.scanPath)
                    .font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).frame(width: 420)
            }
            Text("Under a minute on most disks. Nothing is changed while scanning. If macOS asks whether Headroom can look inside Documents, Downloads or Desktop, allowing it gives a fuller picture.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("Stop") { model.cancelScan() }
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop measuring (⌘.)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor private struct ChangesView: View {
    @Environment(AppModel.self) private var model
    @State private var hoverSample: Sample?

    var body: some View {
        if let ch = model.scan?.changes {
            var sections = model.changeSections()
            if sections.isEmpty, model.search.isEmpty {
                sections = [RowSection(id: "none", title: "Nothing Moved Much", rows: [],
                                       empty: "No folder grew or shrank by more than 250 MB between the last two scans.")]
            }
            return AnyView(RowList(sections: sections, header: AnyView(summary(ch))))
        }
        return AnyView(ContentUnavailableView {
            Label("One More Scan to Go", systemImage: "chart.line.uptrend.xyaxis")
        } description: {
            Text("Headroom compares each scan with the one before it. Scan again in a few days to see which folders grew.")
        } actions: {
            Button("Scan Now") { model.rescan() }
        })
    }

    private func summary(_ ch: Changes) -> some View {
        let delta = model.free - (ch.freeThen ?? model.free)
        let shown = hoverSample ?? model.history.last
        return HStack(alignment: .top, spacing: Space.l) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Since \(Date(timeIntervalSince1970: ch.since).formatted(.relative(presentation: .named)))")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(signed(delta)).font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("free space").font(.title3).foregroundStyle(.secondary)
                }
                Text("The folders below account for most of the change. A new copy that shares space with something already on disk is not counted as growth.")
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.history.count >= 2 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Free Space Over Time").font(.headline)
                    Text(shown.map { "\($0.date.formatted(date: .abbreviated, time: .shortened)): \(fmt($0.free)) free" } ?? "")
                        .font(.callout).foregroundStyle(.secondary)
                    FreeSpaceChart(samples: model.history, hover: $hoverSample)
                }
                .frame(width: 380)
            }
        }
        .padding(.vertical, Space.s)
    }
}
