import AppKit
import Combine
import UsageCore

@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var rows: [UsageRow] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var now = Date()
    @Published private(set) var response: UsageResponse?
    @Published private(set) var creditDebit: CreditDebit?
    @Published private(set) var subscription: SubscriptionRenewal?
    var onSample: ((UsageResponse, Date) -> Void)?
    var onClock: ((Date) -> Void)?
    var onAccountUnavailable: (() -> Void)?
    private var debitTracker = CreditDebitTracker()
    var historyRecording = false
    var refreshInterval: TimeInterval { response?.isUsingCredits == true ? 10 : (historyRecording ? 15 : 60) }
    private let reader = CodexReader()
    private var tick: AnyCancellable?
    private var wakeObserver: Any?
    private var lastAttempt = Date.distantPast
    private var handledReset: Date?
    private let readUsage: (@Sendable () async throws -> UsageResponse)?
    private let readSubscription: @Sendable (String?) -> SubscriptionRenewal?
    private var request: Task<Void, Never>?
    private var requestGeneration = UUID()
    private(set) var countdownVisible = true
    private(set) var isStarted = false
    private(set) var scheduleStarts = 0

    init(initial: UsageResponse? = nil, lastUpdated: Date? = nil, error: String? = nil, refreshing: Bool = false,
         now: Date = Date(), readUsage: (@Sendable () async throws -> UsageResponse)? = nil,
         subscription: SubscriptionRenewal? = nil,
         readSubscription: @escaping @Sendable (String?) -> SubscriptionRenewal? = { SubscriptionMetadata.read(accountID: $0) }) {
        self.readUsage = readUsage
        self.readSubscription = readSubscription
        self.subscription = subscription
        self.response = initial
        self.rows = initial?.rows ?? []
        self.lastUpdated = lastUpdated
        self.errorMessage = error
        self.isRefreshing = refreshing
        self.now = now
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        scheduleStarts += 1
        tick = Timer.publish(every: 1, tolerance: 0.1, on: .main, in: .common).autoconnect().sink { [weak self] date in
            self?.onTick(date)
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resumeAfterWake() }
        }
        refresh()
    }

    var isStale: Bool {
        errorMessage != nil || lastUpdated.map { now.timeIntervalSince($0) > 90 } == true
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastAttempt = Date()
        let reader = reader
        let readUsage = readUsage
        let readSubscription = readSubscription
        let generation = UUID()
        requestGeneration = generation
        request = Task {
            do {
                try Task.checkCancellation()
                let response: UsageResponse
                if let readUsage { response = try await readUsage() }
                else {
                    let worker = Task.detached(priority: .utility) { try reader.read() }
                    response = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: {
                        worker.cancel()
                    })
                }
                guard !Task.isCancelled, generation == requestGeneration else { return }
                let subscription = await Task.detached(priority: .utility) { readSubscription(response.accountId) }.value
                guard !Task.isCancelled, generation == requestGeneration else { return }
                let observed = Date()
                if self.response?.accountId != response.accountId { creditDebit = nil }
                if let debit = debitTracker.observe(response, at: observed) { creditDebit = debit }
                self.response = response
                self.subscription = subscription
                rows = response.rows
                lastUpdated = observed
                errorMessage = nil
                onSample?(response, observed)
            } catch {
                guard !Task.isCancelled, generation == requestGeneration else { return }
                errorMessage = error.localizedDescription
                // Authentication failures must not keep showing another account's old quota.
                if let failure = error as? UsageReadError, case .signInRequired = failure {
                    rows = []
                    lastUpdated = nil
                    response = nil
                    subscription = nil
                    creditDebit = nil
                    debitTracker = CreditDebitTracker()
                    onAccountUnavailable?()
                }
            }
            now = Date()
            isRefreshing = false
        }
    }

    func setCountdownVisible(_ visible: Bool) {
        countdownVisible = visible
        if visible { now = Date() }
    }

    func resumeAfterWake() {
        guard isStarted else { return }
        if countdownVisible { now = Date() }
        refresh()
    }

    func onTick(_ date: Date) {
        guard isStarted else { return }
        if countdownVisible { now = date }
        onClock?(date)
        let expiryDates = response?.rateLimitResetCredits?.credits?.compactMap { $0.status == "available" ? $0.expiry.date : nil } ?? []
        let due = (rows.compactMap(\.window.resetDate) + expiryDates + [subscription?.date].compactMap { $0 })
            .filter { $0 <= date }.max()
        if let due, due != handledReset {
            handledReset = due
            refresh()
        } else if date.timeIntervalSince(lastAttempt) >= (due != nil ? min(15, refreshInterval) : refreshInterval) {
            refresh()
        }
    }

    func stop() {
        isStarted = false
        requestGeneration = UUID()
        tick?.cancel()
        tick = nil
        request?.cancel()
        request = nil
        isRefreshing = false
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        reader.cancel()
    }
}
