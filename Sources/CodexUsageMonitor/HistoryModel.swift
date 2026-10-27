import Foundation
import Combine
import UsageCore

@MainActor
final class HistoryModel: ObservableObject {
    @Published private(set) var analysis: AnalysisSnapshot = .init()
    @Published private(set) var drops: [UsageDrop] = []
    @Published private(set) var status = "Enable usage analysis in Settings to start recording."
    @Published private(set) var enabled = false
    private var recorder: HistoryRecorder?
    private var task: Task<Void, Never>?
    private var sampleTask: Task<Void, Never>?
    private var displayTask: Task<Void, Never>?
    private(set) var analysisVisible = false
    private var lastSnapshot = Date.distantPast
    private var snapshotInterval: TimeInterval = 15
    private var scanning = false
    private var lastScan = Date.distantPast
    private var generation = UUID()
    private var activeAccount: String?
    private var loadedSavedAccount: String?
    private let storeURL: URL
    private let codexHome: URL

    init(storeURL: URL? = nil, codexHome: URL? = nil, initial: HistorySnapshot? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.storeURL = storeURL ?? home.appendingPathComponent("Library/Application Support/local.codex-usage-monitor/history.sqlite")
        self.codexHome = codexHome ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        if let initial { drops = initial.drops; analysis = initial.analysis; status = initial.note }
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        generation = UUID()
        loadedSavedAccount = nil
        lastSnapshot = .distantPast
        task?.cancel(); task = nil; scanning = false
        sampleTask?.cancel(); sampleTask = nil
        displayTask?.cancel(); displayTask = nil
        if value {
            recorder = HistoryRecorder(storeURL: storeURL, codexHome: codexHome)
            status = "Recording from the next observation. Local activity coverage starts with a baseline."
            lastScan = .distantPast
        } else {
            recorder = nil
            status = "Recording paused. Saved history is retained."
        }
    }

    func receive(_ response: UsageResponse, at date: Date) {
        let account = response.accountId
        if account != activeAccount {
            generation = UUID()
            task?.cancel(); task = nil; scanning = false
            sampleTask?.cancel(); sampleTask = nil
            displayTask?.cancel(); displayTask = nil
            drops = []; analysis = .init(); activeAccount = account; loadedSavedAccount = nil
            recorder = enabled ? HistoryRecorder(storeURL: storeURL, codexHome: codexHome) : nil
            lastScan = .distantPast
            lastSnapshot = .distantPast
        }
        if !enabled {
            requestSnapshot()
            return
        }
        guard let recorder else { return }
        let current = generation
        sampleTask?.cancel()
        sampleTask = Task {
            do {
                let result = try await recorder.record(response, at: date, includeAnalysis: false)
                guard current == generation, enabled, activeAccount == account else { return }
                status = result.note
                tick(Date())
            } catch { if current == generation { status = error.localizedDescription } }
        }
    }

    func tick(_ date: Date) {
        requestSnapshot()
        guard enabled, !scanning, date.timeIntervalSince(lastScan) >= 5, let recorder else { return }
        scanning = true; lastScan = date
        let current = generation
        task = Task {
            defer { if current == generation { scanning = false } }
            do {
                if let result = try await recorder.scan(at: date, includeAnalysis: false), current == generation, enabled {
                    status = result.note
                }
            } catch { if current == generation { status = error.localizedDescription } }
        }
    }
    func setAnalysisVisible(_ visible: Bool) {
        analysisVisible = visible
        if visible { lastSnapshot = .distantPast; requestSnapshot() }
        else { displayTask?.cancel() }
    }

    private func requestSnapshot() {
        guard analysisVisible, displayTask == nil, let account = activeAccount,
              Date().timeIntervalSince(lastSnapshot) >= snapshotInterval else { return }
        if !enabled {
            guard loadedSavedAccount != account, FileManager.default.fileExists(atPath: storeURL.path) else { return }
        }
        let collector = recorder
        let loader = HistoryRecorder(storeURL: storeURL, codexHome: codexHome, readOnly: true)
        let current = generation
        let recording = enabled
        let begun = Date()
        displayTask = Task {
            defer {
                if current == generation {
                    displayTask = nil
                    if analysisVisible { requestSnapshot() }
                }
            }
            do {
                let result: HistorySnapshot
                if recording, let collector { result = try await collector.snapshot() }
                else { result = try await loader.loadSaved(accountId: account) }
                guard !Task.isCancelled, current == generation, activeAccount == account, analysisVisible else { return }
                drops = result.drops; analysis = result.analysis
                if !recording { loadedSavedAccount = account }
                lastSnapshot = Date()
                // Large datasets refresh less often while visible; closed windows
                // never pay for a derived snapshot. Capture cadence is independent.
                snapshotInterval = min(60, max(15, Date().timeIntervalSince(begun) * 20))
            } catch {
                if !Task.isCancelled, current == generation { status = error.localizedDescription; lastSnapshot = Date() }
            }
        }
    }

    func invalidateAccount() {
        generation = UUID()
        activeAccount = nil; loadedSavedAccount = nil
        task?.cancel(); task = nil; scanning = false
        sampleTask?.cancel(); sampleTask = nil
        displayTask?.cancel(); displayTask = nil
        drops = []; analysis = .init()
        recorder = enabled ? HistoryRecorder(storeURL: storeURL, codexHome: codexHome) : nil
        status = "Account unavailable. History is paused until a signed-in observation succeeds."
    }
    func stop() {
        setEnabled(false)
        generation = UUID()
        task?.cancel(); task = nil
        sampleTask?.cancel(); sampleTask = nil
        displayTask?.cancel(); displayTask = nil
        scanning = false
    }
    func stopAndWait() async {
        let pending = [task, sampleTask, displayTask].compactMap { $0 }
        stop()
        for task in pending { await task.value }
        recorder = nil
    }
}
