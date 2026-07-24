import Combine
import Foundation
import UnhogCore

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshots: [ProviderUsageSnapshot] = []
    @Published private(set) var isRefreshing = false

    private var scanner: UsageScanner
    private var refreshTask: Task<Void, Never>?
    private var observerCount = 0
    private var refreshGeneration = 0
    private var keychainAccess: ClaudeKeychainAccess
    private let makeScanner: (ClaudeKeychainAccess) -> UsageScanner

    /// Set by the composition root so a consent decision outlives the process.
    var persistKeychainAccess: ((ClaudeKeychainAccess) -> Void)?

    init(
        keychainAccess: ClaudeKeychainAccess = .unasked,
        makeScanner: @escaping (ClaudeKeychainAccess) -> UsageScanner = {
            UsageScanner(claudeKeychainAccess: $0)
        }
    ) {
        self.keychainAccess = keychainAccess
        self.makeScanner = makeScanner
        scanner = makeScanner(keychainAccess)
    }

    func allowClaudeKeychainAccess() {
        // Deliberately re-runs even when already allowed, so the "Ask again"
        // action after a refusal actually retries.
        keychainAccess = .allowed
        scanner = makeScanner(.allowed)
        persistKeychainAccess?(.allowed)
        scanOnce()
    }

    func startRefreshing() {
        observerCount += 1
        guard refreshTask == nil else { return }
        isRefreshing = snapshots.isEmpty
        refreshGeneration += 1
        let generation = refreshGeneration
        let scanner = scanner
        refreshTask = Task { [weak self] in
            // Whatever ends this loop, the flag has to clear. Otherwise the view
            // stays on its loading state and the refresh button stays disabled.
            defer {
                if let self, self.refreshGeneration == generation {
                    self.isRefreshing = false
                    self.refreshTask = nil
                }
            }
            while !Task.isCancelled {
                let snapshots = await scanner.scan()
                guard !Task.isCancelled else { return }
                self?.apply(snapshots)
                self?.isRefreshing = false
                // Poll only while something is actually observing.
                guard let self, self.observerCount > 0 else { return }
                try? await Task.sleep(for: .seconds(5 * 60))
            }
        }
    }

    // Deliberately does not cancel an in-flight scan. The sweep is expensive and
    // its result is cached for the next open, so tearing it down on every tab
    // switch meant it could never finish. The loop exits after the current pass.
    func stopRefreshing() {
        observerCount = max(0, observerCount - 1)
    }

    func refresh() {
        guard !isRefreshing else { return }
        scanOnce()
    }

    private func scanOnce() {
        isRefreshing = true
        refreshGeneration += 1
        let generation = refreshGeneration
        let scanner = scanner
        Task { [weak self] in
            defer {
                if let self, self.refreshGeneration == generation {
                    self.isRefreshing = false
                }
            }
            let snapshots = await scanner.scan()
            self?.apply(snapshots)
        }
    }

    private func apply(_ incoming: [ProviderUsageSnapshot]) {
        rememberRefusal(in: incoming)
        let previous = Dictionary(
            uniqueKeysWithValues: snapshots.map { ($0.provider, $0) }
        )
        snapshots = incoming.map { fresh in
            guard case .unavailable = fresh.connectionState,
                let lastGood = previous[fresh.provider],
                !lastGood.windows.isEmpty
            else {
                return fresh
            }
            return ProviderUsageSnapshot(
                provider: fresh.provider,
                plan: lastGood.plan,
                windows: lastGood.windows,
                creditBalance: lastGood.creditBalance,
                today: fresh.today,
                lastSevenDays: fresh.lastSevenDays,
                lastThirtyDays: fresh.lastThirtyDays,
                refreshedAt: fresh.refreshedAt,
                connectionState: fresh.connectionState
            )
        }
    }

    /// A refused keychain dialog is recorded so the next refresh reads no
    /// keychain at all. Without this the five-minute poll would keep asking.
    private func rememberRefusal(in incoming: [ProviderUsageSnapshot]) {
        guard keychainAccess == .allowed else { return }
        let refused = incoming.contains {
            if case .consentDeclined = $0.connectionState { return true }
            return false
        }
        guard refused else { return }
        keychainAccess = .declined
        scanner = makeScanner(.declined)
        persistKeychainAccess?(.declined)
    }

    func applyPreviewFixture() {
        let now = Date()
        snapshots = [
            ProviderUsageSnapshot(
                provider: .claude,
                plan: "Max 5x",
                windows: [
                    UsageWindow(
                        id: "session",
                        label: "Session",
                        usedPercent: 68,
                        resetsAt: now.addingTimeInterval(2_140)
                    ),
                    UsageWindow(
                        id: "weekly",
                        label: "Weekly",
                        usedPercent: 41,
                        resetsAt: now.addingTimeInterval(218_000)
                    ),
                ],
                today: LocalUsageTotals(
                    inputTokens: 1_820_000,
                    outputTokens: 84_000,
                    turnCount: 97
                ),
                lastSevenDays: LocalUsageTotals(
                    inputTokens: 8_420_000,
                    outputTokens: 422_000,
                    turnCount: 614
                ),
                lastThirtyDays: LocalUsageTotals(
                    inputTokens: 31_200_000,
                    outputTokens: 1_640_000,
                    turnCount: 2_480
                ),
                refreshedAt: now,
                connectionState: .connected
            ),
            ProviderUsageSnapshot(
                provider: .codex,
                plan: "Plus",
                windows: [
                    UsageWindow(
                        id: "session",
                        label: "Session",
                        usedPercent: 23,
                        resetsAt: now.addingTimeInterval(8_200)
                    ),
                    UsageWindow(
                        id: "weekly",
                        label: "Weekly",
                        usedPercent: 56,
                        resetsAt: now.addingTimeInterval(328_000)
                    ),
                ],
                creditBalance: 796,
                today: LocalUsageTotals(
                    inputTokens: 3_140_000,
                    outputTokens: 126_000,
                    turnCount: 142
                ),
                lastSevenDays: LocalUsageTotals(
                    inputTokens: 12_900_000,
                    outputTokens: 620_000,
                    turnCount: 840
                ),
                lastThirtyDays: LocalUsageTotals(
                    inputTokens: 49_800_000,
                    outputTokens: 2_120_000,
                    turnCount: 3_220
                ),
                refreshedAt: now,
                connectionState: .connected
            ),
        ]
        isRefreshing = false
    }

    deinit {
        refreshTask?.cancel()
    }
}
