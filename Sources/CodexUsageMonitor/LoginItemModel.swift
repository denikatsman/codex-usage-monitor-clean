import AppKit
import Combine
import ServiceManagement

enum LoginItemState: String {
    case enabled, off, requiresApproval, unavailable
}

@MainActor
protocol LoginItemServicing {
    var status: LoginItemState { get }
    func register() throws
    func unregister() async throws
    func openSettings()
}

@MainActor
struct SystemLoginItemService: LoginItemServicing {
    var status: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .off
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    private func validateInstalledBundle() throws {
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        let applications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").standardizedFileURL
        guard Bundle.main.bundleIdentifier == "local.codex-usage-monitor",
              bundle.pathExtension == "app", bundle.deletingLastPathComponent().path == applications.path else {
            throw NSError(domain: "LoginItem", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Enable Launch at login from the installed app in your Applications folder."])
        }
    }
    func register() throws {
        try validateInstalledBundle()
        try SMAppService.mainApp.register()
    }
    func unregister() async throws {
        try validateInstalledBundle()
        try await SMAppService.mainApp.unregister()
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
final class LoginItemModel: ObservableObject {
    @Published private(set) var status: LoginItemState
    @Published private(set) var isChanging = false
    @Published private(set) var errorMessage: String?
    private let service: any LoginItemServicing
    private var activationObserver: Any?

    init(service: (any LoginItemServicing)? = nil) {
        let service = service ?? SystemLoginItemService()
        self.service = service
        status = service.status
    }

    var isEnabled: Bool { status == .enabled }
    var explanation: String {
        switch status {
        case .enabled: return "Opens when you sign in. You can also turn this off in macOS Login Items."
        case .off: return "Start automatically when you sign in to your Mac."
        case .requiresApproval: return "Disabled in macOS. Enable Codex Usage Monitor in Login Items."
        case .unavailable: return "Login item status is unavailable. Check macOS Login Items."
        }
    }

    func refresh() {
        let current = service.status
        if current != status { errorMessage = nil; status = current }
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isChanging else { return }
        refresh()
        guard enabled != isEnabled || (!enabled && status == .requiresApproval) else { return }
        // An OS-level denial is a user choice, never a reason to auto-register again.
        if enabled && status == .requiresApproval { return }
        isChanging = true; errorMessage = nil
        defer { isChanging = false }
        do {
            if enabled { try service.register() }
            else { try await service.unregister() }
            refresh()
        } catch {
            refresh()
            errorMessage = error.localizedDescription
        }
    }

    func openSettings() { service.openSettings() }
    func start() {
        guard activationObserver == nil else { return }
        refresh()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    func stop() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }
}
