// The cleanup list (trailing inspector) and the sheet that reviews, confirms and runs a cleanup.
// The sheet shows what the helper says it will do for each item before anything is touched.
import SwiftUI

@MainActor struct CleanupListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.planItems
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                ContentUnavailableView("No Items Yet", systemImage: "checklist",
                                       description: Text("Tick items on any page to collect them here, then clean them together."))
            } else {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("Cleanup List").font(.headline)
                    Text(fmt(model.planTotal)).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("comes back from \(plural(items.count, "item"))").foregroundStyle(.secondary)
                    HStack(spacing: Space.s) {
                        Button("Review and Clean…") { model.review(model.plan) }
                            .buttonStyle(.borderedProminent)
                            .help("See what cleaning each item does, then confirm (⌘↩)")
                        Button("Clear") { model.clearPlan() }
                            .help("Empty the cleanup list without cleaning anything")
                    }
                    .padding(.top, Space.xs)
                }
                .padding(Space.m)
                Divider()
                List {
                    ForEach(items) { it in
                        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(it.title).lineLimit(1).truncationMode(.middle).help(it.title)
                                Text(fmt(it.bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            Spacer(minLength: Space.xs)
                            Button {
                                model.setPlan([it.id], false)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove from the cleanup list")
                            .accessibilityLabel("Remove \(it.title) from the cleanup list")
                        }
                        .contextMenu {
                            Button("Remove from Cleanup List") { model.setPlan([it.id], false) }
                            if !it.paths.isEmpty { Button("Show in Finder") { model.reveal(it.paths) } }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

@MainActor struct CleanSheet: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: CleanSession
    @State private var confirmTrash = false

    private var total: Int64 { model.totalOf(session.items.filter { session.blocked[$0.id] == nil }) }
    private var runnable: Int { session.items.filter { session.blocked[$0.id] == nil }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).font(.title2).fontWeight(.semibold)
                Text(summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.l)

            Divider()
            List(session.items) { it in
                itemRow(it)
            }
            .listStyle(.inset)
            .frame(height: min(380, max(120, CGFloat(session.items.count) * 50 + 12)))
            Divider()

            footer.padding(Space.l)
        }
        .frame(width: 640)
        .interactiveDismissDisabled(session.stage == .running)
        .confirmationDialog("Empty Trash?", isPresented: $confirmTrash) {
            Button("Empty Trash", role: .destructive) { Task { await model.emptyTrash() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can't undo this action.")
        }
    }

    private var title: String {
        switch session.stage {
        case .review:
            return session.items.count == 1 ? "Clean “\(session.items[0].title)”?" : "Clean \(session.items.count) Items?"
        case .running:
            return "Cleaning \(min(session.current + 1, max(1, session.planned))) of \(session.planned)"
        case .done:
            return "\(session.done) of \(session.items.count) Cleaned"
        }
    }

    private var summary: String {
        switch session.stage {
        case .review:
            return "About \(fmt(total)) comes back. A folder inside another one is counted once. Each line says what cleaning does."
        case .running:
            return "Keep Headroom open until this finishes."
        case .done:
            var s = "Free space went from \(fmt(session.startFree)) to \(fmt(session.endFree))."
            if session.trashed > 0 {
                s += " \(plural(session.trashed, "item")) went to the Trash and still \(session.trashed == 1 ? "takes" : "take") up space until it is emptied."
            }
            if session.failed > 0 { s += " \(plural(session.failed, "item")) could not be finished; the reason is on each one." }
            if session.stopRequested, session.done + session.failed < session.items.count { s += " The rest were left alone." }
            return s
        }
    }

    private func itemRow(_ it: Candidate) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(it.title).lineLimit(1).truncationMode(.middle).help(it.title)
                    PillView(pill: Pill.safety(it.safety))
                }
                status(it)
            }
            Spacer(minLength: Space.s)
            Text(fmt(it.bytes)).monospacedDigit().foregroundStyle(.secondary)
            if session.stage == .review {
                Button {
                    model.removeFromSession(it.id)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Leave this one out")
                .accessibilityLabel("Leave \(it.title) out of this cleanup")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func status(_ it: Candidate) -> some View {
        if let mark = session.marks[it.id] {
            switch mark {
            case .working:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working").font(.callout).foregroundStyle(.secondary)
                }
            case .ok(let text):
                Label(text, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            case .failed(let why):
                Label("Not finished: \(why)", systemImage: "exclamationmark.triangle.fill").font(.callout)
                    .foregroundStyle(.secondary).symbolRenderingMode(.multicolor).fixedSize(horizontal: false, vertical: true)
            }
        } else if let why = session.blocked[it.id] {
            Label("Unable to clean this: \(why)", systemImage: "exclamationmark.triangle.fill").font(.callout)
                .foregroundStyle(.secondary).symbolRenderingMode(.multicolor).fixedSize(horizontal: false, vertical: true)
        } else if let dry = session.dry[it.id], !dry.isEmpty {
            Text(dry).font(.callout).foregroundStyle(.secondary).lineLimit(2).help(dry)
        } else if session.stage == .review {
            Text("Checking").font(.callout).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var footer: some View {
        switch session.stage {
        case .review:
            VStack(alignment: .leading, spacing: Space.m) {
                Toggle("Delete immediately, without the Trash", isOn: $session.hard)
                    .onChange(of: session.hard) { _, _ in model.refreshDry() }
                Text(session.hard ? "Everything is deleted at once and cannot be brought back."
                                  : "Caches and commands cannot be undone. Anything moved to the Trash can be put back until you empty it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.closeSession() }.keyboardShortcut(.cancelAction)
                    Button(runnable == session.items.count ? "Clean \(fmt(total))" : "Clean \(runnable) of \(session.items.count)") {
                        Task { await model.runClean() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(runnable == 0)
                }
            }
        case .running:
            HStack(spacing: Space.m) {
                ProgressView(value: Double(session.current), total: Double(max(1, session.planned)))
                Button(session.stopRequested ? "Stopping" : "Stop After This Item") { session.stopRequested = true }
                    .disabled(session.stopRequested)
                    .help("Finish the item in progress, then leave the rest alone")
            }
        case .done:
            HStack(spacing: Space.s) {
                if session.trashed > 0 || session.trash != .idle {
                    switch session.trash {
                    case .idle:
                        Button("Empty Trash…") { confirmTrash = true }
                    case .emptying:
                        ProgressView().controlSize(.small)
                        Text("Emptying the Trash").foregroundStyle(.secondary)
                    case .emptied(let free):
                        Label("Trash emptied, \(free) free", systemImage: "checkmark.circle.fill").symbolRenderingMode(.multicolor)
                    case .failed:
                        Label("Unable to empty the Trash. Try it in Finder.", systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    }
                }
                Spacer()
                Button("Scan Again") {
                    model.closeSession()
                    model.rescan()
                }
                .help("Measure the disk again so every figure is current")
                Button("Done") { model.closeSession() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }
}
