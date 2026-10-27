import SwiftUI
import UsageCore

struct AccountDetailsView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var state: AppState
    let compact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var credits: AccountCredits? { model.response?.credits }
    private var resets: ResetCredits? { model.response?.rateLimitResetCredits }
    private var available: [ResetCredit] { resets?.available(at: model.now) ?? [] }
    private var resetCount: Int? {
        guard let resets else { return nil }
        if let list = resets.credits, !list.isEmpty { return available.count }
        return resets.availableCount
    }
    private var balance: String {
        if credits?.unlimited == true { return "Unlimited" }
        return credits?.amount.map(AccountCredits.format) ?? "Unavailable"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Label("Credits", systemImage: "circle.hexagongrid").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                Text(balance).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.65)
                    .help(credits?.balance ?? balance)
                    .accessibilityLabel("Account credits").accessibilityValue(credits?.balance ?? balance)
            }
            HStack {
                Text(model.response?.isUsingCredits == true ? (model.creditDebit == nil ? "Allowance exhausted · 10s checks" : "Using credits · 10-second checks") : "Observed credit deduction")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                ZStack {
                    if let debit = model.creditDebit {
                        Text("−" + debitText(debit.amount))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(.orange)
                            .lineLimit(1).minimumScaleFactor(0.55)
                            .id(debit.id)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .move(edge: .bottom).combined(with: .opacity)))
                            .help("Observed decrease since the previous successful check: \(NSDecimalNumber(decimal: debit.amount).stringValue) credits")
                            .accessibilityLabel("Observed credit deduction").accessibilityValue(debitText(debit.amount))
                    } else { Text("—").foregroundStyle(.tertiary) }
                }
                .frame(width: 108, height: 23, alignment: .trailing).clipped()
                .animation(state.animateCredits && !reduceMotion ? .spring(response: 0.4, dampingFraction: 0.85) : nil, value: model.creditDebit?.id)
            }
            HStack {
                Image(systemName: "arrow.counterclockwise.circle").foregroundStyle(.secondary)
                Text(resetCount.map { "\($0) reset\($0 == 1 ? "" : "s") available" } ?? "Reset availability unknown")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(available) { credit in
                        Text("Expires \(credit.expiry.label)")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("\(credit.title ?? "Reset"): expires \(credit.expiry.label)")
                    }
                    if available.isEmpty {
                        Text(resets == nil ? "Expiry information unavailable" : (resetCount == 0 ? "No available reset credits" : "Reset expiry information unavailable"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: compact ? 48 : min(88, CGFloat(max(1, available.count)) * 19))
        }
        .opacity(model.isStale ? 0.65 : 1)
    }

    private func debitText(_ amount: Decimal) -> String {
        amount < Decimal(string: "0.01")! ? NSDecimalNumber(decimal: amount).stringValue : AccountCredits.format(amount)
    }
}
