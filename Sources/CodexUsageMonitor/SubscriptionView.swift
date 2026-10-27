import SwiftUI
import UsageCore

struct SubscriptionView: View {
    let subscription: SubscriptionRenewal?
    let now: Date
    let compact: Bool
    var format: CountdownFormat = .hours

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            Divider()
            Label("Subscription renewal", systemImage: "calendar.badge.clock")
                .font(.system(size: 12, weight: .medium))
            if let subscription {
                Text(UsageFormatting.resetDate(subscription.date))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(provenance(subscription))
                let countdown = UsageFormatting.countdown(to: subscription.date, from: now, format: format)
                Text(countdown)
                    .font(.system(size: compact ? 21 : 23, design: .monospaced))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                    .accessibilityLabel("Time until subscription renewal")
                    .accessibilityValue(countdown)
                Text(subscription.isAwaitingUpdate(at: now)
                     ? "Awaiting an updated subscription date"
                     : "until renewal · time from local account data")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(provenance(subscription))
            } else {
                Text("Renewal date unavailable").font(.system(size: 13))
                Text("No subscription date in local account metadata.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: compact ? 106 : 112, alignment: .topLeading)
    }

    private func provenance(_ subscription: SubscriptionRenewal) -> String {
        let checked = subscription.lastChecked.map { " Last checked \(UsageFormatting.resetDate($0))." } ?? ""
        return "Cached subscription active-until date from Codex sign-in metadata. The exact renewal time is provisional.\(checked) This is separate from usage allowance resets."
    }
}
