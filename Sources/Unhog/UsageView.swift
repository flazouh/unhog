import SwiftUI
import UnhogCore

struct UsageView: View {
    @ObservedObject var store: UsageStore

    @Environment(\.unhogReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if store.isRefreshing, store.snapshots.isEmpty {
                loading
            } else {
                ForEach(store.snapshots) { snapshot in
                    UsageProviderCard(
                        snapshot: snapshot,
                        onAllowKeychain: store.allowClaudeKeychainAccess
                    )
                }
            }
        }
        .onAppear { store.startRefreshing() }
        .onDisappear { store.stopRefreshing() }
        .animation(
            reduceMotion ? nil : UnhogTheme.motionFade,
            value: store.snapshots
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Usage")
                    .font(.system(size: 12, weight: .semibold))
                Text("Live limits and measured local token volume")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                store.refresh()
            } label: {
                if store.isRefreshing {
                    LoadingIndicator(size: 10)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
            }
            .buttonStyle(InlineActionStyle(compact: true))
            .disabled(store.isRefreshing)
            .accessibilityLabel("Refresh usage")
        }
    }

    private var loading: some View {
        HStack(spacing: 9) {
            LoadingIndicator(size: 11)
            Text("Reading provider limits and local usage…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 112)
        .background(UnhogTheme.surface)
        .clipShape(
            RoundedRectangle(
                cornerRadius: UnhogTheme.cornerRadius,
                style: .continuous
            )
        )
    }
}

private struct UsageProviderCard: View {
    let snapshot: ProviderUsageSnapshot
    let onAllowKeychain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            providerHeader

            if snapshot.windows.isEmpty {
                if needsKeychainDecision {
                    consentPanel
                } else {
                    connectionNotice
                }
            } else {
                VStack(spacing: 9) {
                    ForEach(snapshot.windows) { window in
                        UsageWindowRow(
                            window: window,
                            color: providerColor
                        )
                    }
                }
                if case .unavailable = snapshot.connectionState {
                    connectionNotice
                }
            }

            Divider()
                .opacity(0.45)

            localUsage
        }
        .padding(12)
        .background(UnhogTheme.surface.opacity(0.76))
        .clipShape(
            RoundedRectangle(
                cornerRadius: UnhogTheme.cornerRadius,
                style: .continuous
            )
        )
    }

    private var providerHeader: some View {
        HStack(spacing: 9) {
            UsageProviderMark(provider: snapshot.provider, size: 21)
                .frame(width: 30, height: 30)
                .background(UnhogTheme.surfaceHover)
                .clipShape(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(snapshot.provider.displayName)
                        .font(.system(size: 11, weight: .semibold))
                    if let plan = snapshot.plan {
                        Text(plan)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(connectionLabel)
                    .font(.system(size: 8))
                    .foregroundStyle(connectionColor)
            }

            Spacer()

            if let credit = snapshot.creditBalance {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(formatCredit(credit))
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                    Text(snapshot.provider == .claude ? "extra spent" : "credits")
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var needsKeychainDecision: Bool {
        switch snapshot.connectionState {
        case .needsConsent, .consentDeclined:
            true
        default:
            false
        }
    }

    /// Explains the keychain prompt before it appears, rather than letting macOS
    /// ask on Unhog's behalf with no context.
    private var consentPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(connectionColor)
                Text(connectionDetail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            Button(action: onAllowKeychain) {
                Text(consentActionLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 9)
                    .frame(height: 22)
            }
            .buttonStyle(InlineActionStyle(compact: true))
            .accessibilityLabel(consentActionLabel)
        }
        .padding(.vertical, 3)
    }

    private var consentActionLabel: String {
        if case .consentDeclined = snapshot.connectionState {
            return "Ask again"
        }
        return "Turn on live limits"
    }

    private var connectionNotice: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(connectionColor)
            Text(connectionDetail)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private var localUsage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LOCAL TOKENS")
                    .font(.system(size: 7, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(snapshot.today.turnCount) turns today")
                    .font(.system(size: 7))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                UsageTotalCell(
                    label: "Today",
                    totals: snapshot.today,
                    color: providerColor
                )
                UsageTotalCell(
                    label: "7 days",
                    totals: snapshot.lastSevenDays,
                    color: providerColor
                )
                UsageTotalCell(
                    label: "30 days",
                    totals: snapshot.lastThirtyDays,
                    color: providerColor
                )
            }
        }
    }

    private var providerColor: Color {
        snapshot.provider == .claude
            ? UnhogTheme.energy
            : UnhogTheme.ram
    }

    private var connectionLabel: String {
        switch snapshot.connectionState {
        case .connected:
            "Live limits connected"
        case .localOnly:
            "Local usage only"
        case .notConfigured:
            "Not connected"
        case .unavailable:
            "Temporarily unavailable"
        case .needsConsent:
            "Live limits need permission"
        case .consentDeclined:
            "Live limits declined"
        }
    }

    private var connectionDetail: String {
        switch snapshot.connectionState {
        case .connected:
            ""
        case let .localOnly(message),
            let .notConfigured(message),
            let .unavailable(message),
            let .needsConsent(message),
            let .consentDeclined(message):
            message
        }
    }

    private var connectionColor: Color {
        switch snapshot.connectionState {
        case .connected:
            UnhogTheme.healthy
        case .localOnly, .needsConsent:
            UnhogTheme.warning
        case .notConfigured, .unavailable, .consentDeclined:
            .secondary
        }
    }

    private func formatCredit(_ value: Double) -> String {
        if snapshot.provider == .claude {
            return value.formatted(.currency(code: "USD"))
        }
        return value.formatted(.number.precision(.fractionLength(0)))
    }
}

private struct UsageWindowRow: View {
    let window: UsageWindow
    let color: Color

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(window.label)
                    .font(.system(size: 9, weight: .medium))
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))% used")
                    .font(.system(size: 8, weight: .semibold))
                    .monospacedDigit()
                if let resetsAt = window.resetsAt {
                    Text("· \(resetLabel(resetsAt))")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(color.opacity(0.78))
                        .frame(
                            width: proxy.size.width
                                * window.usedPercent / 100
                        )
                }
            }
            .frame(height: 6)
            .accessibilityLabel(
                "\(window.label), \(Int(window.usedPercent.rounded())) percent used"
            )
        }
    }

    private func resetLabel(_ date: Date) -> String {
        let seconds = max(0, date.timeIntervalSinceNow)
        if seconds < 3_600 {
            return "resets in \(max(1, Int(ceil(seconds / 60))))m"
        }
        if seconds < 86_400 {
            return "resets in \(Int(ceil(seconds / 3_600)))h"
        }
        return "resets in \(Int(ceil(seconds / 86_400)))d"
    }
}

private struct UsageTotalCell: View {
    let label: String
    let totals: LocalUsageTotals
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 7, weight: .medium))
                .foregroundStyle(.secondary)
            Text(tokenLabel)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
            HStack(spacing: 3) {
                Circle()
                    .fill(color.opacity(0.75))
                    .frame(width: 4, height: 4)
                Text("\(totals.turnCount) turns")
                    .font(.system(size: 7))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .clipShape(
            RoundedRectangle(
                cornerRadius: UnhogTheme.compactRadius,
                style: .continuous
            )
        )
    }

    private var tokenLabel: String {
        guard totals.hasData else { return "No data" }
        return totals.totalTokens.formatted(
            .number.notation(.compactName)
        )
    }
}
