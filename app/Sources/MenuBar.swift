// The menu bar item (free space at a glance) and the Settings window.
import ServiceManagement
import SwiftUI

@MainActor struct MenuBarLabel: View {
    let model: AppModel
    @AppStorage("menuBarText") private var showText = true

    var body: some View {
        Image(systemName: model.freeFraction < 0.10 ? "exclamationmark.triangle.fill" : "internaldrive")
        if showText, model.total > 0 {
            Text(model.free >= 10 * GB ? "\(model.free / GB) GB" : fmt(model.free))
        }
    }
}

@MainActor struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(fmt(model.free)).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("free of \(fmt(model.total))").foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Spacer(minLength: Space.xs)
                PillView(pill: model.health)
            }
            MiniBar(fraction: 1 - model.freeFraction,
                    color: model.freeFraction < 0.03 ? Palette.crit.color : model.freeFraction < 0.10 ? Palette.review.color : .accentColor)
                .frame(height: 6)
            switch model.phase {
            case .scanning:
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: model.scanFraction)
                    Text(model.progress).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            case .ready:
                VStack(alignment: .leading, spacing: 2) {
                    Label("\(fmt(model.totals.safe)) safe to clear", systemImage: "sparkles")
                    if model.purgeable > GB {
                        Label("\(fmt(model.purgeable)) more that macOS frees when needed", systemImage: "clock.arrow.circlepath")
                    }
                    Text(model.scannedText).font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                }
                .font(.callout)
            default:
                EmptyView()
            }
            Divider()
            HStack(spacing: Space.s) {
                Button("Clean Safe Items…") {
                    open()
                    model.reviewSafe()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.phase != .ready || model.safeItems.isEmpty)
                Button("Scan Now") { model.rescan() }
                    .disabled(model.phase != .ready)
                Spacer()
            }
            HStack {
                Button("Open Headroom") { open() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { model.readVolume() }
    }

    private func open() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("menuBar") private var menuBar = true
    @AppStorage("menuBarText") private var menuBarText = true
    @AppStorage("keepRunning") private var keepRunning = true
    @AppStorage("warnBelowGB") private var warnBelow = 10
    @AppStorage("autoScan") private var autoScan = "never"
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError = ""

    var body: some View {
        TabView {
            Form {
                Section("Menu Bar") {
                    Toggle("Show Headroom in the menu bar", isOn: $menuBar)
                    Toggle("Show free space next to the icon", isOn: $menuBarText).disabled(!menuBar)
                    Toggle("Keep running when the window is closed", isOn: $keepRunning).disabled(!menuBar)
                    Toggle("Open Headroom at login", isOn: Binding(get: { atLogin }, set: setLogin))
                    if !loginError.isEmpty {
                        Text(loginError).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Section("Alerts and Scans") {
                    Picker("Warn me when free space falls below", selection: $warnBelow) {
                        Text("Never").tag(0)
                        ForEach([5, 10, 20, 50], id: \.self) { Text("\($0) GB").tag($0) }
                    }
                    Picker("Scan the disk automatically", selection: $autoScan) {
                        Text("Never").tag("never")
                        Text("Every Day").tag("daily")
                        Text("Every Week").tag("weekly")
                    }
                    Text("Automatic scans and alerts run only while Headroom is open or in the menu bar.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Access") {
                    LabeledContent("Full Disk Access") {
                        Label(model.fullDiskAccess ? "On" : "Off", systemImage: model.fullDiskAccess ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(.secondary)
                    }
                    Text("With Full Disk Access, scans also measure the Trash, Mail, Messages and Photos. Headroom works without it and never sends anything off this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open System Settings…") { openFullDiskAccess() }
                }
                Section("Records") {
                    LabeledContent("Action log") {
                        Button("Show in Finder") { model.reveal([model.engine.actionLogURL.path]) }
                    }
                    Text("Every cleanup is written to this file: what was asked, what was done, and how much came back.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 520)
        .onAppear { model.checkAccess() }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = ""
        } catch {
            loginError = "Unable to change this. Move Headroom to the Applications folder, then try again."
        }
        atLogin = SMAppService.mainApp.status == .enabled
    }
}
