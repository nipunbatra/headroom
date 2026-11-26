import AppKit
import Observation
import SwiftUI

@MainActor @Observable final class LocationExplorer {
    let engine: Engine
    private let defaults: UserDefaults
    private var progress: ScanProgress?
    private(set) var report: LocationReport?
    private(set) var previousBytes: Int64?
    private(set) var pending: String?
    private(set) var error: String?
    private(set) var trail: [String] = []
    var largest = false
    var busy: Bool { pending != nil }

    init(engine: Engine, defaults: UserDefaults) {
        self.engine = engine
        self.defaults = defaults
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Analyze"
        panel.message = "Choose a folder or mounted drive to measure."
        if panel.runModal() == .OK, let url = panel.url { open(url.path) }
    }

    func open(_ path: String, drill: Bool = false) {
        let ancestors = drill ? trail : []
        start(path, ancestors: ancestors)
    }

    func back() {
        guard trail.count > 1 else { return }
        start(trail[trail.count - 2], ancestors: Array(trail.dropLast(2)))
    }

    func refresh() {
        guard let path = report?.path else { return }
        start(path, ancestors: Array(trail.dropLast()))
    }

    func cancel() {
        progress?.cancel()
        progress = nil
        pending = nil
    }

    private func start(_ path: String, ancestors: [String]) {
        cancel()
        let token = ScanProgress()
        progress = token
        pending = path
        error = nil
        Task {
            do {
                let result = try await engine.analyzeLocation(path, progress: token)
                guard progress === token else { return }
                if let result {
                    record(result)
                    report = result
                    trail = ancestors + [result.path]
                    largest = false
                }
            } catch {
                guard progress === token else { return }
                self.error = error.localizedDescription
            }
            progress = nil
            pending = nil
        }
    }

    private func record(_ result: LocationReport) {
        previousBytes = nil
        guard let key = result.identity, result.denied.isEmpty, result.onlineOnlyItems == 0 else { return }
        var history = defaults.dictionary(forKey: "locationMeasurements") as? [String: [String: NSNumber]] ?? [:]
        previousBytes = history[key]?["bytes"]?.int64Value
        history[key] = ["bytes": NSNumber(value: result.bytes), "time": NSNumber(value: result.scannedAt)]
        if history.count > 64, let oldest = history.min(by: {
            ($0.value["time"]?.doubleValue ?? 0) < ($1.value["time"]?.doubleValue ?? 0)
        }) { history.removeValue(forKey: oldest.key) }
        defaults.set(history, forKey: "locationMeasurements")
    }
}

@MainActor struct LocationView: View {
    @Environment(AppModel.self) private var model
    let explorer: LocationExplorer

    var body: some View {
        @Bindable var explorer = explorer
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Choose Folder or Drive…", systemImage: "folder.badge.plus") { explorer.choose() }
                    .buttonStyle(.borderedProminent)
                if explorer.trail.count > 1 {
                    Button("Back", systemImage: "chevron.left") { explorer.back() }
                }
                Spacer()
                if explorer.busy {
                    ProgressView().controlSize(.small)
                    Text("Measuring " + lastComponent(explorer.pending ?? "")).lineLimit(1)
                    Button("Stop") { explorer.cancel() }
                } else if explorer.report != nil {
                    Button("Measure Again", systemImage: "arrow.clockwise") { explorer.refresh() }
                }
            }.padding()
            if let error = explorer.error { Label(error, systemImage: "exclamationmark.triangle").padding(.horizontal) }
            if let r = explorer.report {
                VStack(alignment: .leading, spacing: 5) {
                    Text(r.path).font(.headline).lineLimit(2).textSelection(.enabled)
                    Text("\(fmt(r.bytes)) measured · \(plural(r.files, "file")) · \(fmt(r.available)) available on volume")
                    if let old = explorer.previousBytes {
                        Text("Change since the previous measurement: " + signed(r.bytes - old)).foregroundStyle(.secondary)
                    }
                    if !r.denied.isEmpty || r.onlineOnlyItems > 0 {
                        Text("Partial measurement · \(plural(r.denied.count, "unreadable folder")) · \(plural(r.onlineOnlyItems, "online-only item"))")
                            .foregroundStyle(.secondary).help(r.denied.prefix(10).joined(separator: "\n"))
                    }
                }.padding(.horizontal)
                Picker("Results", selection: $explorer.largest) {
                    Text("Folder contents").tag(false)
                    Text("Largest files").tag(true)
                }.pickerStyle(.segmented).labelsHidden().fixedSize().padding()
                let source = explorer.largest ? r.largest : r.entries
                let items = source.filter { model.search.isEmpty || $0.path.localizedCaseInsensitiveContains(model.search) }
                if explorer.largest { Text("Up to 100 files of 1 MB or more across this location.").font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
                if items.isEmpty {
                    ContentUnavailableView("No matching items", systemImage: "folder", description: Text(explorer.largest ? "Try Folder contents to see smaller files." : "This folder is empty or no names match the filter."))
                } else {
                    List(items) { item in
                        HStack {
                            Image(systemName: item.directory ? "folder.fill" : "doc").foregroundStyle(.tint)
                            VStack(alignment: .leading) {
                                Button(item.name) {
                                    if item.directory { explorer.open(item.path, drill: true) } else { model.preview(item.path) }
                                }.buttonStyle(.link).disabled(item.onlineOnly)
                                if let note = item.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                                if explorer.largest { Text(parentPath(item.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                            }
                            Spacer()
                            Text(fmt(item.bytes)).monospacedDigit()
                            Button { model.reveal([item.path]) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.borderless).accessibilityLabel("Reveal " + item.name + " in Finder")
                        }.padding(.vertical, 3)
                    }
                }
            } else {
                ContentUnavailableView("Explore a folder or drive", systemImage: "externaldrive",
                    description: Text("Measure its contents, open folders, and preview large files. Use ⌘O to choose a location."))
            }
        }
    }
}
