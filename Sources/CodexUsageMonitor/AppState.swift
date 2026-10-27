import Combine
import Foundation
import UsageCore

@MainActor
final class AppState: ObservableObject {
    let usage: UsageModel
    let defaults: UserDefaults
    let history: HistoryModel
    let loginItem: LoginItemModel
    @Published private(set) var historyEnabled: Bool
    @Published private(set) var showAccountDetails: Bool
    @Published private(set) var animateCredits: Bool
    @Published private(set) var countdownFormat: CountdownFormat
    @Published private(set) var access: AppAccess
    @Published private(set) var accessError: String?
    var applyAccess: ((AppAccess) -> AccessTransitionResult)?
    @Published private(set) var presentation: PresentationState

    init(defaults: UserDefaults = .standard, usage: UsageModel? = nil, history: HistoryModel? = nil, loginItem: LoginItemModel? = nil) {
        self.defaults = defaults
        self.usage = usage ?? UsageModel()
        self.history = history ?? HistoryModel()
        self.loginItem = loginItem ?? LoginItemModel()
        historyEnabled = defaults.bool(forKey: "usageHistoryEnabled")
        showAccountDetails = defaults.object(forKey: "showAccountDetails") as? Bool ?? true
        animateCredits = defaults.object(forKey: "animateCredits") as? Bool ?? true
        countdownFormat = CountdownFormat.load(from: defaults)
        access = AppAccess.load(from: defaults)
        presentation = PresentationState(saved: UsagePresentation(rawValue: defaults.string(forKey: "presentationMode") ?? "") ?? .floating)
        if defaults.object(forKey: "showInMenuBar") as? Bool == false,
           defaults.object(forKey: "showInDock") as? Bool == false { access.save(to: defaults) }
    }

    func setHistoryEnabled(_ enabled: Bool) {
        historyEnabled = enabled
        defaults.set(enabled, forKey: "usageHistoryEnabled")
        history.setEnabled(enabled)
        usage.historyRecording = enabled
        if enabled { usage.refresh() }
    }
    func setAccountDetails(_ enabled: Bool) { showAccountDetails = enabled; defaults.set(enabled, forKey: "showAccountDetails") }
    func setAnimateCredits(_ enabled: Bool) { animateCredits = enabled; defaults.set(enabled, forKey: "animateCredits") }
    func setCountdownFormat(_ format: CountdownFormat) {
        guard countdownFormat != format else { return }
        countdownFormat = format
        defaults.set(format.rawValue, forKey: "countdownFormat")
    }

    @discardableResult
    func setAccess(menuBar: Bool, dock: Bool) -> Bool {
        let updated = AppAccess(menuBar: menuBar, dock: dock)
        guard updated.valid else { return false }
        if let applyAccess {
            let result = applyAccess(updated)
            accessError = result.error
            if access != result.actual {
                access = result.actual
                // Preserve the last valid saved mode if all native entry points fail.
                if access.valid { access.save(to: defaults) }
            }
            return result.actual == updated
        }
        guard updated != access else { return true }
        access = updated
        updated.save(to: defaults)
        return true
    }

    @discardableResult
    func statusItemRemoved() -> Bool {
        let needsRecovery = !access.dock
        setAccess(menuBar: false, dock: true)
        if needsRecovery { openMain() }
        return needsRecovery
    }

    private func syncCountdownVisibility() {
        usage.setCountdownVisible(presentation.mainVisible || presentation.cardVisible)
    }
    func launch(background: Bool) { presentation.launch(background: background); syncCountdownVisibility() }
    func showCard() { presentation.showCard(); syncCountdownVisibility() }
    func closeCard() { presentation.closeCard(); syncCountdownVisibility() }
    func openMain() {
        presentation.openMain()
        syncCountdownVisibility()
        defaults.set(presentation.saved.rawValue, forKey: "presentationMode")
    }
    func hideMain() {
        guard access.valid else { openMain(); return }
        presentation.hideMain()
        syncCountdownVisibility()
        defaults.set(presentation.saved.rawValue, forKey: "presentationMode")
    }
    func start() {
        loginItem.start()
        usage.onSample = { [weak self] response, date in self?.history.receive(response, at: date) }
        usage.onClock = { [weak self] date in self?.history.tick(date) }
        usage.onAccountUnavailable = { [weak self] in self?.history.invalidateAccount() }
        history.setEnabled(historyEnabled)
        usage.historyRecording = historyEnabled
        usage.start()
    }
    func stop() { loginItem.stop(); history.stop(); usage.stop() }
    func shutdown() async {
        loginItem.stop()
        usage.stop()
        await history.stopAndWait()
    }
}
