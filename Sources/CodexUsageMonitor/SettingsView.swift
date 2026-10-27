import SwiftUI
import UsageCore

struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var login: LoginItemModel

    init(state: AppState) { self.state = state; self.login = state.loginItem }

    var showDaysInCountdowns: Binding<Bool> {
        Binding(get: { state.countdownFormat == .days },
                set: { state.setCountdownFormat($0 ? .days : .hours) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Startup").font(.headline)
            Toggle("Launch at login", isOn: Binding(get: { login.isEnabled }, set: { enabled in
                Task { await login.setEnabled(enabled) }
            }))
            .disabled(login.isChanging)
            Text(login.explanation).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = login.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Button("Open macOS Login Items…", action: login.openSettings).font(.callout)
            Divider()
            Text("App access").font(.headline)
            if let error = state.accessError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Show in menu bar", isOn: Binding(
                get: { state.access.menuBar },
                set: { state.setAccess(menuBar: $0, dock: state.access.dock) }
            ))
            .disabled(state.access.menuBar && !state.access.dock)
            Toggle("Show in Dock", isOn: Binding(
                get: { state.access.dock },
                set: { state.setAccess(menuBar: state.access.menuBar, dock: $0) }
            ))
            .disabled(state.access.dock && !state.access.menuBar)
            Text("Keep at least one entry point on so you can always reopen the window. Changes apply immediately.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Hiding the floating window keeps monitoring. Reopen it from the menu bar or Dock. Quit stops the app.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Usage details").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Show days in countdowns", isOn: showDaysInCountdowns)
                .accessibilityHint("Off shows total hours, minutes and seconds. On shows days, hours, minutes and seconds. One day is 24 elapsed hours.")
                Text("Off: 78h 12m 34s · On: 3d 06h 12m 34s")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Show resets and credits", isOn: Binding(get: { state.showAccountDetails }, set: state.setAccountDetails))
            Toggle("Animate credit deductions", isOn: Binding(get: { state.animateCredits }, set: state.setAnimateCredits))
            Toggle("Record usage analysis", isOn: Binding(get: { state.historyEnabled }, set: state.setHistoryEnabled))
            Text("Analysis records allowance observations, token counters, and local chat metadata. It stays on this Mac. Turning it off retains saved records and starts a new baseline when enabled again.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Button("Quit Codex Usage Monitor") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .toggleStyle(.switch)
        .padding(20)
        .frame(width: 360)
        .onAppear { login.refresh() }
    }
}
