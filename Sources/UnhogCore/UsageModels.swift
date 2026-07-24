import Foundation

public enum UsageProvider: String, CaseIterable, Hashable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude:
            "Claude"
        case .codex:
            "Codex"
        }
    }
}

public struct UsageWindow: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(
        id: String,
        label: String,
        usedPercent: Double,
        resetsAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.usedPercent = min(100, max(0, usedPercent))
        self.resetsAt = resetsAt
    }
}

public struct LocalUsageTotals: Equatable, Sendable {
    public let inputTokens: UInt64
    public let outputTokens: UInt64
    public let turnCount: Int

    public init(
        inputTokens: UInt64 = 0,
        outputTokens: UInt64 = 0,
        turnCount: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.turnCount = turnCount
    }

    public var totalTokens: UInt64 {
        inputTokens + outputTokens
    }

    public var hasData: Bool {
        totalTokens > 0 || turnCount > 0
    }
}

public enum UsageConnectionState: Equatable, Sendable {
    case connected
    case localOnly(String)
    case notConfigured(String)
    case unavailable(String)
    /// Live limits are available but need the user's permission first, because
    /// the token lives in a keychain item owned by another app.
    case needsConsent(String)
    /// The user refused that permission. Recorded so nothing asks again.
    case consentDeclined(String)
}

public struct ProviderUsageSnapshot: Identifiable, Equatable, Sendable {
    public var id: UsageProvider { provider }

    public let provider: UsageProvider
    public let plan: String?
    public let windows: [UsageWindow]
    public let creditBalance: Double?
    public let today: LocalUsageTotals
    public let lastSevenDays: LocalUsageTotals
    public let lastThirtyDays: LocalUsageTotals
    public let refreshedAt: Date
    public let connectionState: UsageConnectionState

    public init(
        provider: UsageProvider,
        plan: String? = nil,
        windows: [UsageWindow] = [],
        creditBalance: Double? = nil,
        today: LocalUsageTotals = LocalUsageTotals(),
        lastSevenDays: LocalUsageTotals = LocalUsageTotals(),
        lastThirtyDays: LocalUsageTotals = LocalUsageTotals(),
        refreshedAt: Date = Date(),
        connectionState: UsageConnectionState
    ) {
        self.provider = provider
        self.plan = plan
        self.windows = windows
        self.creditBalance = creditBalance
        self.today = today
        self.lastSevenDays = lastSevenDays
        self.lastThirtyDays = lastThirtyDays
        self.refreshedAt = refreshedAt
        self.connectionState = connectionState
    }

    public var hasUsage: Bool {
        !windows.isEmpty
            || creditBalance != nil
            || today.hasData
            || lastSevenDays.hasData
            || lastThirtyDays.hasData
    }
}
