import SwiftUI

@MainActor struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var records: [CleanupRecord] = []
    @State private var failuresOnly = false
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        let filtered = records.filter { record in
            (!failuresOnly || !record.ok) && (model.search.isEmpty || [record.title ?? "", record.idString, record.did, record.at]
                .contains { $0.localizedCaseInsensitiveContains(model.search) })
        }
        let groups = Dictionary(grouping: filtered) { $0.session ?? "entry-" + String($0.offset) }
            .sorted { ($0.value.first?.offset ?? 0) > ($1.value.first?.offset ?? 0) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Status", selection: $failuresOnly) {
                    Text("All actions").tag(false)
                    Text("Unfinished").tag(true)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Button("Show Log in Finder") { model.reveal([model.engine.actionLogPath]) }
                    .disabled(records.isEmpty)
            }.padding()
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error { ContentUnavailableView("Unable to read history", systemImage: "exclamationmark.triangle", description: Text(error)) }
            else if groups.isEmpty {
                ContentUnavailableView(records.isEmpty ? "No cleanup history yet" : "No matching actions", systemImage: "clock",
                    description: Text(records.isEmpty ? "Completed and unfinished actions appear here after a cleanup." : "Change the status or search term."))
            } else {
                List {
                    ForEach(groups, id: \.key) { group in
                        Section((group.value.first?.at ?? "") + " · " + plural(group.value.count, "action")) {
                            ForEach(group.value) { record in
                                HStack(alignment: .top, spacing: Space.m) {
                                    Image(systemName: record.ok ? "checkmark.circle" : "exclamationmark.triangle")
                                        .foregroundStyle(record.ok ? Color.secondary : Color.orange)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.title ?? record.idString).fontWeight(.medium).textSelection(.enabled)
                                        Text(record.did.isEmpty ? "No operation completed" : (record.ok ? record.did : "Planned · " + record.did)).foregroundStyle(.secondary)
                                        if !record.ok, let completed = record.completed {
                                            Text("\(plural(completed, "operation")) completed · \(record.trashed ?? 0) moved to Trash").font(.callout)
                                        }
                                        if !record.ok { Text((record.errors ?? []).joined(separator: " · ")).font(.callout).textSelection(.enabled) }
                                    }
                                }.padding(.vertical, 3)
                            }
                        }
                    }
                }
            }
        }
        .task(id: model.session?.stage == .done) {
            do {
                let loaded = try await model.engine.recentActivity()
                if !Task.isCancelled { records = loaded; error = nil }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { loading = false }
        }
    }
}
