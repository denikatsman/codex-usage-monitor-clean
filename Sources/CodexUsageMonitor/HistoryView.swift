import SwiftUI
import UsageCore

struct HistoryView: View {
    @ObservedObject var state: AppState
    @ObservedObject var history: HistoryModel
    @State private var selection: String?
    @State private var page = 0
    @State private var meter = "all"

    init(state: AppState, initialPage: Int = 0) {
        self.state = state; history = state.history; _page = State(initialValue: initialPage)
    }
    private var intervals: [UsageInterval] {
        (history.analysis.openIntervals + history.analysis.intervals).filter { meter == "all" || $0.meterID == meter }
    }
    private var selected: UsageInterval? { intervals.first { $0.id == selection } ?? intervals.first }
    private var meters: [(id: String, title: String)] {
        var seen = Set<String>()
        return (history.analysis.openIntervals + history.analysis.intervals)
            .filter { seen.insert($0.meterID).inserted }.map { (id: $0.meterID, title: $0.title) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if page == 0 { timeline }
            else if page == 1 { calibration }
            else { legacy }
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                Text(history.status)
                if !history.analysis.issues.isEmpty { Text(history.analysis.issues.joined(separator: " · ")) }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .frame(minWidth: 760, minHeight: 500)
        .onChange(of: intervals.map(\.id), initial: true) { _, ids in
            if selection == nil || !ids.contains(selection!) { selection = ids.first }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Usage analysis").font(.title2.bold())
                    Text("Allowance observations and recorded activity on this Mac")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Recording", isOn: Binding(get: { state.historyEnabled }, set: state.setHistoryEnabled))
                    .toggleStyle(.switch).fixedSize()
            }
            HStack {
                Picker("View", selection: $page) {
                    Text("Intervals").tag(0)
                    Text("Calibration").tag(1)
                    if !history.drops.isEmpty { Text("Legacy history").tag(2) }
                }.pickerStyle(.segmented).frame(maxWidth: 420)
                Spacer(minLength: 12)
                if page != 2, !meters.isEmpty {
                    Picker("Meter", selection: $meter) {
                        Text("All meters").tag("all")
                        ForEach(meters, id: \.id) { item in Text(item.title).tag(item.id) }
                    }.labelsHidden().frame(maxWidth: 220)
                }
            }
        }.padding(20)
    }

    @ViewBuilder private var timeline: some View {
        if intervals.isEmpty {
            empty("Your next interval starts here", symbol: "waveform.path", explanation: state.historyEnabled
                  ? "Recording is active. The first account reading establishes a baseline; local activity appears as it is captured. A percentage drop closes an interval."
                  : "Enable Recording to collect allowance observations and local chat activity. Saved records stay on this Mac when recording is off.")
        } else {
            HSplitView {
                List(selection: $selection) {
                    let open = intervals.filter { $0.endAt == nil }
                    let closed = intervals.filter { $0.endAt != nil }
                    if !open.isEmpty {
                        Section(state.historyEnabled ? "In progress" : "Last recorded intervals") { ForEach(open) { interval in intervalRow(interval).tag(interval.id) } }
                    }
                    Section("Observed drops") { ForEach(closed) { interval in intervalRow(interval).tag(interval.id) } }
                }.frame(minWidth: 255, idealWidth: 290, maxWidth: 350)
                if let selected { intervalDetail(selected).frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
    }

    private func intervalRow(_ interval: UsageInterval) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(interval.title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if interval.endAt == nil { Image(systemName: state.historyEnabled ? "record.circle" : "pause.circle").foregroundStyle(.tint) }
            }
            Text(boundary(interval)).font(.headline).monospacedDigit()
            Text(Self.timestamp(interval.endAt ?? interval.startAt)).font(.caption).foregroundStyle(.secondary)
            Text("\(chatCount(interval)) · \(interval.totals.total.formatted()) tokens")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if interval.isBaseline { Text("Partial first interval").font(.caption2).foregroundStyle(.secondary) }
        }.padding(.vertical, 6)
    }

    private func intervalDetail(_ interval: UsageInterval) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(boundary(interval)).font(.title2.bold()).monospacedDigit()
                    Text("\(interval.title) · \(interval.plan)").foregroundStyle(.secondary)
                    Text(interval.endAt == nil ? (state.historyEnabled ? "Activity since the latest boundary" : "Saved activity since the last boundary · recording paused") : "\((interval.points ?? 0).formatted(.number.precision(.fractionLength(0...2)))) percentage \(interval.points == 1 ? "point" : "points") observed")
                        .font(.callout).foregroundStyle(.secondary)
                }
                GroupBox("Observation timeline") {
                    VStack(spacing: 8) {
                        field("Interval began", Self.timestamp(interval.startAt))
                        field("Previous account reading", Self.timestamp(interval.previousObservationAt))
                        field(interval.endAt == nil ? "Analysis generated" : "Drop first observed", Self.timestamp(interval.endAt ?? history.analysis.generatedAt))
                        field("Elapsed interval", Self.duration(interval.durationSeconds))
                        if let end = interval.endAt {
                            field("Drop observation window", Self.duration(end.timeIntervalSince(interval.previousObservationAt)))
                        }
                        if let reset = interval.resetAt { field("Allowance resets", Self.timestamp(reset)) }
                    }.padding(6)
                }
                Text("The change was observed between account readings; the server may have applied it earlier. Allowance values can be rounded and updates delayed. Activity is grouped by its local source timestamp; this associates records with the interval without assigning a charge to each chat.")
                    .font(.caption).foregroundStyle(.secondary)
                tokenGrid(interval.totals)
                HStack(spacing: 24) {
                    metric("Completed turns", interval.segments.reduce(0) { $0 + $1.completedTurns }.formatted())
                    metric("Tool calls", interval.segments.reduce(0) { $0 + $1.toolCalls }.formatted())
                }
                if interval.segments.contains(where: { $0.tokens.total > 0 && !UsageTier.isComparable($0.speed) }) {
                    Label("Service tier unresolved: calibration excludes this interval. Its recorded activity remains available.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if interval.isBaseline {
                    note("Recording began partway through this interval. It is excluded from calibration.", symbol: "circle.lefthalf.filled")
                }
                if !interval.issues.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(interval.issues, id: \.self) { note($0, symbol: "info.circle") }
                    }
                }
                Divider()
                Text("Recorded activity").font(.headline)
                if interval.segments.isEmpty {
                    Text("No matching local activity has been captured. Other devices, unavailable records, and reporting delays can leave an interval without matching activity.")
                        .foregroundStyle(.secondary)
                }
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(interval.segments) { segment in segmentCard(segment) }
                }
                Text("Cached input is a subset of input; reasoning is a subset of output. Token counts, completed turns, tool calls, and elapsed time describe recorded activity, not its quality. A reported turn duration can overlap other turns and includes waiting and tool time. Service tier describes observed or requested settings, not proof of the actual served tier or billing. Unknown, unset, mixed, and unsupported tiers are excluded from calibration.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func segmentCard(_ segment: ActivitySegment) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text(segment.title).font(.headline).textSelection(.enabled)
                    Spacer()
                    if let url = URL(string: "codex://threads/" + segment.threadID) { Link(destination: url) { Image(systemName: "arrow.up.right.square") }.help("Open chat in Codex") }
                }
                Text("\(segment.model) · \(segment.effort) reasoning")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                field("Logged/requested tier", UsageTier.label(segment.speed))
                field("Project", segment.project)
                if let agent = segment.agentPath { field("Agent", agent) }
                if let parent = segment.parentThreadID { field("Parent chat", parent) }
                if let turn = segment.turnID { field("Turn", turn) }
                Text("\(segment.tokens.total.formatted()) tokens · \(segment.completedTurns) completed turns · \(segment.toolCalls) tool calls")
                    .font(.callout).monospacedDigit()
                Text("Input \(segment.tokens.input.formatted()) · cached \(segment.tokens.cached.formatted()) · cache write \(segment.tokens.cacheWrite.formatted())\nOutput \(segment.tokens.output.formatted()) · reasoning \(segment.tokens.reasoning.formatted())")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                field("First activity", Self.timestamp(segment.firstAt))
                field("Last activity", Self.timestamp(segment.lastAt))
                if let duration = segment.turnDurationSeconds { field("Reported turn duration", Self.duration(duration)) }
                if !segment.provenance.isEmpty {
                    DisclosureGroup("Evidence (\(segment.provenance.count) references)") {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Logged or requested settings; these records do not establish the actual served tier or billing.").foregroundStyle(.secondary)
                            ForEach(segment.provenance, id: \.self) { reference in
                                Text(reference).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.font(.caption).padding(.top, 5)
                    }.font(.caption)
                }
                ForEach(segment.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var calibration: some View {
        let summaries = history.analysis.calibration.filter { meter == "all" || $0.meterID == meter }
        if summaries.isEmpty {
            empty("Calibration needs complete intervals", symbol: "chart.xyaxis.line", explanation: "After a full interval is recorded, eligible samples estimate how many local tokens accompanied one percentage point. Partial baselines, collection gaps, mixed model settings, ambiguous counters, and unresolved service tiers are excluded. Intervals remain available even when calibration cannot use them.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Text("An empirical comparison of local recorded activity and observed allowance changes. Each model, reasoning setting, logged/requested tier, plan, and meter is kept separate. These estimates can change as more samples arrive.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(summaries) { summary in calibrationCard(summary) }
                    Text("The median and 10th–90th percentile range summarize eligible intervals. Input and output components are pooled per percentage point. These are observations from this Mac, not a billing formula; hidden work, other devices, rounding, and delayed updates can affect the relationship. Calibration uses eligible loaded records from the latest 14 days, up to 100,000 meter and 100,000 activity records. The timeline shows the latest 200 closed intervals.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func calibrationCard(_ summary: CalibrationSummary) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text(summary.title).font(.headline)
                    Spacer()
                    Text(summary.isEarlyData ? "Early data" : "Observed estimate")
                        .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
                Text("\(summary.model) · \(summary.effort) reasoning · \(UsageTier.label(summary.speed)) tier · \(summary.plan)")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(summary.medianTokensPerPoint.formatted(.number.precision(.fractionLength(0))))
                        .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("recorded tokens / percentage point").font(.callout).foregroundStyle(.secondary)
                }
                field("10th–90th percentile", "\(Self.number(summary.lowerTokensPerPoint))–\(Self.number(summary.upperTokensPerPoint)) tokens / point")
                field("Samples", "\(summary.sampleCount) intervals · \(summary.totalPoints.formatted(.number.precision(.fractionLength(0...2)))) percentage points")
                field("Input / point", "\(Self.number(summary.inputPerPoint)) (cached \(Self.number(summary.cachedPerPoint)))")
                field("Cache write / point", Self.number(summary.cacheWritePerPoint))
                field("Output / point", "\(Self.number(summary.outputPerPoint)) (reasoning \(Self.number(summary.reasoningPerPoint)))")
                if summary.isEarlyData { Text("Fewer than five eligible intervals. Treat this as an initial observation.").font(.caption).foregroundStyle(.secondary) }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var legacy: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                note("Saved history from the previous collector. These records are preserved separately and are excluded from calibration.", symbol: "archivebox")
                ForEach(history.drops) { drop in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(UsageFormatting.percent(100 - drop.fromUsed)) → \(UsageFormatting.percent(100 - drop.toUsed)) remaining").font(.headline)
                            field("Meter", drop.bucket)
                            field("First observed", Self.timestamp(drop.observedAt))
                            field("Previous observation", Self.timestamp(drop.previousObservation))
                            field("Activity began", Self.timestamp(drop.intervalStart))
                            field("Source", drop.observationSource)
                            ForEach(drop.chats) { chat in
                                Divider()
                                Text(chat.title).font(.callout.bold()).textSelection(.enabled)
                                Text("\(chat.model) · \(chat.tokens.total.formatted()) tokens · \(chat.turns) completed turns · \(chat.tools) tool calls").font(.caption).foregroundStyle(.secondary)
                                Text("Input \(chat.tokens.input.formatted()) (cached \(chat.tokens.cached.formatted())) · Output \(chat.tokens.output.formatted()) (reasoning \(chat.tokens.reasoning.formatted()))").font(.caption).foregroundStyle(.secondary)
                                if let url = URL(string: "codex://threads/" + chat.thread) { Link("Open chat", destination: url).font(.caption) }
                            }
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.padding(24)
        }
    }

    private func empty(_ title: String, symbol: String, explanation: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(explanation)
        } actions: {
            if !state.historyEnabled { Button("Start recording") { state.setHistoryEnabled(true) }.buttonStyle(.borderedProminent) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tokenGrid(_ tokens: TokenMetrics) -> some View {
        GroupBox("Recorded tokens") {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 14) {
                metric("Total input + output", tokens.total.formatted())
                metric("Input", tokens.input.formatted())
                metric("Cached input", tokens.cached.formatted())
                metric("Cache write", tokens.cacheWrite.formatted())
                metric("Output", tokens.output.formatted())
                metric("Reasoning", tokens.reasoning.formatted())
            }.padding(8)
        }
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().textSelection(.enabled)
        }
    }
    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
    }
    private func note(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func chatCount(_ interval: UsageInterval) -> String {
        let count = Set(interval.segments.map(\.threadID)).count
        return "\(count) \(count == 1 ? "chat" : "chats")"
    }
    private func boundary(_ interval: UsageInterval) -> String {
        let start = UsageFormatting.percent(100 - interval.fromUsed)
        return interval.toUsed.map { "\(start) → \(UsageFormatting.percent(100 - $0)) remaining" } ?? "\(start) remaining · \(state.historyEnabled ? "open" : "paused")"
    }
    private static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) }
    private static func duration(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return "\(value / 3600)h \((value % 3600) / 60)m \(value % 60)s"
    }
    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.timeZone = .autoupdatingCurrent
        f.dateFormat = "d MMM yyyy · HH:mm:ss.SSS zzz"
        return f.string(from: date)
    }
}
