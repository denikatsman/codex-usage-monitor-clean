import SwiftUI
import UsageCore

struct UsageView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var state: AppState
    let presentation: UsagePresentation
    let changePresentation: () -> Void
    let close: () -> Void
    let settings: () -> Void
    let history: () -> Void

    init(state: AppState, presentation: UsagePresentation,
         changePresentation: @escaping () -> Void, close: @escaping () -> Void,
         settings: @escaping () -> Void, history: @escaping () -> Void = {}) {
        self.state = state
        self.model = state.usage
        self.presentation = presentation
        self.changePresentation = changePresentation
        self.close = close
        self.settings = settings
        self.history = history
    }

    private var isCard: Bool { presentation == .menuBar }

    var body: some View {
        VStack(alignment: .leading, spacing: isCard ? 12 : 17) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis").foregroundStyle(.secondary)
                    Text(isCard ? "Codex Usage Monitor" : "Codex usage")
                        .font(.system(size: isCard ? 12 : 13, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .frame(height: 20)
                .overlay { if presentation == .floating { WindowDragArea() } }
                .help(presentation == .floating ? "Drag to move to any monitor" : "Codex usage")
                Button { model.refresh() } label: {
                    Group {
                        if model.isRefreshing {
                            ProgressView().progressViewStyle(.circular).controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .frame(width: 20, height: 20)
                }
                .disabled(model.isRefreshing)
                .help(model.isRefreshing ? "Refreshing usage" : "Refresh usage (⌘R)")
                .accessibilityLabel(model.isRefreshing ? "Refreshing usage" : "Refresh usage")
                .keyboardShortcut("r", modifiers: .command)
                Button(action: settings) { Image(systemName: "gearshape").frame(width: 20, height: 20) }
                    .help("Settings").accessibilityLabel("Settings")
                if !isCard && state.access.menuBar {
                    Button(action: changePresentation) {
                        Image(systemName: "menubar.arrow.up.rectangle").frame(width: 20, height: 20)
                    }
                    .help("Move to menu bar").accessibilityLabel("Move to menu bar")
                }
                Button(action: close) {
                    Image(systemName: "xmark").frame(width: 20, height: 20)
                }
                .help(isCard ? "Close popover" : "Hide window")
                .disabled(!isCard && !state.access.valid)
                .accessibilityLabel(isCard ? "Close popover" : "Hide window")
                .keyboardShortcut("w", modifiers: .command)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Group {
              if model.rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.isRefreshing ? "Checking usage…" : "Usage unavailable")
                        .font(.system(size: 22, weight: .medium))
                    Text(model.errorMessage ?? (model.isRefreshing ? "Reading your Codex account." : "Codex did not report any usage windows."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 14)
                .overlay { if presentation == .floating { WindowDragArea() } }
              } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(isCard ? Array(model.rows.prefix(4)) : model.rows) { row in
                            UsageRowView(row: row, now: model.now, stale: model.isStale, format: state.countdownFormat)
                                .overlay { if presentation == .floating { WindowDragArea() } }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: isCard ? 166 : min(CGFloat(model.rows.count) * 182 - 22, 500))
              }
            }
            .frame(height: isCard ? 166 : nil, alignment: .topLeading)

            SubscriptionView(subscription: model.subscription, now: model.now, compact: isCard, format: state.countdownFormat)
                .overlay { if presentation == .floating { WindowDragArea() } }

            if state.showAccountDetails {
                AccountDetailsView(model: model, state: state, compact: isCard)
            }

            if state.historyEnabled {
                Button(action: history) { Label("Usage analysis", systemImage: "clock.arrow.circlepath") }
                    .font(.system(size: 11)).buttonStyle(.borderless)
                    .keyboardShortcut("3", modifiers: .command)
            }

            HStack(alignment: .top, spacing: 6) {
                Circle().fill(model.isStale ? Color.orange : (model.lastUpdated == nil ? Color.secondary : Color.green))
                    .frame(width: 5, height: 5).padding(.top, 5)
                Text(footer)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(isCard ? 3 : nil)
                    .help(footer)
                Spacer(minLength: 0)
            }
            .frame(height: isCard ? 38 : nil, alignment: .topLeading)
            .overlay { if presentation == .floating { WindowDragArea() } }

            if isCard {
                Divider()
                Button("Open Codex Usage Monitor", action: changePresentation)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .accessibilityHint("Brings the existing floating window forward")
            }
        }
        .padding(isCard ? 16 : 20)
        .frame(width: isCard ? 360 : 340)
        .background {
            if presentation == .floating {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial)
            }
        }
        .overlay {
            if presentation == .floating { RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.1)) }
        }
    }

    private var footer: String {
        if let error = state.accessError { return error }
        if let error = model.errorMessage {
            let previous = model.lastUpdated.map { " Last updated \($0.formatted(date: .omitted, time: .standard))." } ?? ""
            return error + previous
        }
        if model.isRefreshing { return "Updating…" }
        guard let date = model.lastUpdated else { return "Connecting to Codex…" }
        let prefix = model.isStale ? "Last known usage" : "Updated"
        let interval = model.refreshInterval == 60 ? "checks every minute" : "\(Int(model.refreshInterval))-second checks"
        return "\(prefix) \(date.formatted(date: .omitted, time: .standard)) · \(interval)"
    }
}

private struct UsageRowView: View {
    let row: UsageRow
    let now: Date
    let stale: Bool
    let format: CountdownFormat

    private var awaitingReset: Bool { row.window.isAwaitingReset(at: now) }
    private var remaining: Double? { awaitingReset ? nil : row.window.remainingPercent }
    private var tint: Color { (remaining ?? 100) <= 15 ? .orange : .primary }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(remaining.map(UsageFormatting.percent) ?? "—")
                    .font(.system(size: 39, weight: .medium, design: .rounded))
                    .monospacedDigit().foregroundStyle(tint)
                    .fixedSize(horizontal: true, vertical: false)
                Text(stale ? "last known" : "remaining")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 4)
                Text(row.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(2).multilineTextAlignment(.trailing)
                    .help(row.title).accessibilityLabel(row.title)
            }
            .opacity(stale ? 0.65 : 1)
            ProgressView(value: remaining ?? 0, total: 100)
                .tint(remaining == nil || stale ? .gray : ((remaining ?? 100) <= 15 ? .orange : .accentColor))
                .accessibilityLabel("\(row.title) allowance remaining")
                .accessibilityValue(remaining.map(UsageFormatting.percent) ?? "Unavailable")
            if let date = row.window.resetDate {
                Text("Resets \(UsageFormatting.resetDate(date))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 5)
                    .help(TimeZone.autoupdatingCurrent.identifier)
                let countdown = UsageFormatting.countdown(to: date, from: now, format: format)
                Text(countdown)
                    .font(.system(size: 23, weight: .regular, design: .monospaced))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                    .accessibilityLabel("Time until reset")
                    .accessibilityValue(countdown)
                Text(awaitingReset ? "Waiting for Codex to confirm the reset…" : "until reset")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text("Reset time unavailable")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
    }
}
