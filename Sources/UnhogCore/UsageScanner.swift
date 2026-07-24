import Foundation
import Security

public struct UsageHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    func header(_ name: String) -> String? {
        headers.first {
            $0.key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }
}

public protocol UsageHTTPClient: Sendable {
    func get(
        _ url: URL,
        headers: [String: String]
    ) async throws -> UsageHTTPResponse
}

public struct SystemUsageHTTPClient: UsageHTTPClient {
    public init() {}

    public func get(
        _ url: URL,
        headers: [String: String]
    ) async throws -> UsageHTTPResponse {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageScanError.invalidResponse
        }
        let responseHeaders = http.allHeaderFields.reduce(into: [String: String]()) {
            guard let key = $1.key as? String else { return }
            $0[key] = String(describing: $1.value)
        }
        return UsageHTTPResponse(
            statusCode: http.statusCode,
            headers: responseHeaders,
            body: data
        )
    }
}

public enum UsageScanError: Error, LocalizedError, Equatable {
    case invalidResponse
    case notAuthenticated
    case requestFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The provider returned an unreadable usage response."
        case .notAuthenticated:
            "Sign in with the provider's CLI to see live limits."
        case let .requestFailed(status):
            "The usage service returned HTTP \(status)."
        }
    }
}

public struct UsageScanner: Sendable {
    private let homeDirectory: URL
    private let environment: [String: String]
    private let http: any UsageHTTPClient
    private let readsKeychain: Bool

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        http: any UsageHTTPClient = SystemUsageHTTPClient(),
        readsKeychain: Bool = true
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.http = http
        self.readsKeychain = readsKeychain
    }

    public func scan(now: Date = Date()) async -> [ProviderUsageSnapshot] {
        async let claude = scanClaude(now: now)
        async let codex = scanCodex(now: now)
        return await [claude, codex]
    }

    private func scanCodex(now: Date) async -> ProviderUsageSnapshot {
        let home = codexHome
        // Runs on the cooperative pool via the `async let` child task, which
        // (unlike a detached task) inherits cancellation.
        let local = LocalUsageLogScanner.scanCodex(home: home, now: now)

        guard
            let auth = CodexUsageCredential.load(
                from: home,
                fallback: homeDirectory.appending(path: ".config/codex")
            )
        else {
            return snapshot(
                provider: .codex,
                local: local,
                now: now,
                state: local.lastThirtyDays.hasData
                    ? .localOnly("Sign in with Codex to add live limits.")
                    : .notConfigured("Run `codex` and sign in to begin tracking.")
            )
        }

        do {
            let response = try await http.get(
                URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                headers: [
                    "Authorization": "Bearer \(auth.accessToken)",
                    "Accept": "application/json",
                    "User-Agent": "Unhog",
                    "ChatGPT-Account-Id": auth.accountID ?? "",
                ].filter { !$0.value.isEmpty }
            )
            let live = try UsagePayloadParser.codex(response, now: now)
            return snapshot(
                provider: .codex,
                live: live,
                local: local,
                now: now,
                state: .connected
            )
        } catch {
            return snapshot(
                provider: .codex,
                local: local,
                now: now,
                state: .unavailable(error.localizedDescription)
            )
        }
    }

    private func scanClaude(now: Date) async -> ProviderUsageSnapshot {
        let home = claudeHome
        let local = LocalUsageLogScanner.scanClaude(home: home, now: now)

        let credential = ClaudeUsageCredential.load(
            from: home,
            allowKeychain: readsKeychain
        )
        guard let credential else {
            return snapshot(
                provider: .claude,
                local: local,
                now: now,
                state: local.lastThirtyDays.hasData
                    ? .localOnly("Sign in with Claude Code to add live limits.")
                    : .notConfigured("Run `claude` and sign in to begin tracking.")
            )
        }

        do {
            let response = try await http.get(
                URL(string: "https://api.anthropic.com/api/oauth/usage")!,
                headers: [
                    "Authorization": "Bearer \(credential.accessToken)",
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "anthropic-beta": "oauth-2025-04-20",
                    "User-Agent": "claude-code/2.1.69",
                ]
            )
            let live = try UsagePayloadParser.claude(
                response,
                subscriptionType: credential.subscriptionType,
                now: now
            )
            return snapshot(
                provider: .claude,
                live: live,
                local: local,
                now: now,
                state: .connected
            )
        } catch {
            return snapshot(
                provider: .claude,
                local: local,
                now: now,
                state: .unavailable(error.localizedDescription)
            )
        }
    }

    private var codexHome: URL {
        if let path = environment["CODEX_HOME"], !path.isEmpty {
            return expanded(path)
        }
        return homeDirectory.appending(path: ".codex")
    }

    private var claudeHome: URL {
        if let path = environment["CLAUDE_CONFIG_DIR"], !path.isEmpty {
            return expanded(path)
        }
        return homeDirectory.appending(path: ".claude")
    }

    private func expanded(_ path: String) -> URL {
        if path == "~" {
            return homeDirectory
        }
        if path.hasPrefix("~/") {
            return homeDirectory.appending(path: String(path.dropFirst(2)))
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    private func snapshot(
        provider: UsageProvider,
        live: LiveUsage = LiveUsage(),
        local: LocalUsagePeriods,
        now: Date,
        state: UsageConnectionState
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            provider: provider,
            plan: live.plan,
            windows: live.windows,
            creditBalance: live.creditBalance,
            today: local.today,
            lastSevenDays: local.lastSevenDays,
            lastThirtyDays: local.lastThirtyDays,
            refreshedAt: now,
            connectionState: state
        )
    }
}

struct LiveUsage: Equatable, Sendable {
    var plan: String?
    var windows: [UsageWindow] = []
    var creditBalance: Double?
}

enum UsagePayloadParser {
    static func codex(
        _ response: UsageHTTPResponse,
        now: Date
    ) throws -> LiveUsage {
        try requireSuccess(response)
        guard let body = json(response.body),
            let rateLimit = body["rate_limit"] as? [String: Any]
        else {
            throw UsageScanError.invalidResponse
        }

        let primary = rateLimit["primary_window"] as? [String: Any]
        let secondary = rateLimit["secondary_window"] as? [String: Any]
        let candidates = [
            codexWindow(
                primary,
                fallbackID: "session",
                fallbackHeader: "x-codex-primary-used-percent",
                response: response,
                now: now
            ),
            codexWindow(
                secondary,
                fallbackID: "weekly",
                fallbackHeader: "x-codex-secondary-used-percent",
                response: response,
                now: now
            ),
        ].compactMap { $0 }

        let windows = ["session", "weekly"].compactMap { id in
            candidates.first { $0.id == id }
        }
        let credits = body["credits"] as? [String: Any]
        let balance =
            number(credits?["balance"])
            ?? number(response.header("x-codex-credits-balance"))
        return LiveUsage(
            plan: planName(body["plan_type"] as? String),
            windows: windows,
            creditBalance: balance
        )
    }

    static func claude(
        _ response: UsageHTTPResponse,
        subscriptionType: String?,
        now: Date
    ) throws -> LiveUsage {
        try requireSuccess(response)
        guard let body = json(response.body) else {
            throw UsageScanError.invalidResponse
        }

        var windows: [UsageWindow] = []
        appendClaudeWindow(
            body["five_hour"],
            id: "session",
            label: "Session",
            now: now,
            to: &windows
        )
        appendClaudeWindow(
            body["seven_day"],
            id: "weekly",
            label: "Weekly",
            now: now,
            to: &windows
        )
        appendClaudeWindow(
            body["seven_day_sonnet"],
            id: "sonnet",
            label: "Sonnet",
            now: now,
            to: &windows
        )

        let extra = body["extra_usage"] as? [String: Any]
        let extraSpent = (number(extra?["used_credits"]) ?? 0) / 100
        return LiveUsage(
            plan: planName(subscriptionType),
            windows: windows,
            creditBalance: extraSpent > 0 ? extraSpent : nil
        )
    }

    private static func codexWindow(
        _ value: [String: Any]?,
        fallbackID: String,
        fallbackHeader: String,
        response: UsageHTTPResponse,
        now: Date
    ) -> UsageWindow? {
        guard let value else { return nil }
        let duration = Int(number(value["limit_window_seconds"]) ?? 0)
        let id: String
        if duration == 18_000 {
            id = "session"
        } else if duration == 604_800 {
            id = "weekly"
        } else {
            id = fallbackID
        }
        guard
            let used = number(value["used_percent"])
                ?? number(response.header(fallbackHeader))
        else {
            return nil
        }
        return UsageWindow(
            id: id,
            label: id == "session" ? "Session" : "Weekly",
            usedPercent: used,
            resetsAt: resetDate(value, now: now)
        )
    }

    private static func appendClaudeWindow(
        _ value: Any?,
        id: String,
        label: String,
        now: Date,
        to windows: inout [UsageWindow]
    ) {
        guard let object = value as? [String: Any],
            let used = number(object["utilization"])
        else {
            return
        }
        windows.append(
            UsageWindow(
                id: id,
                label: label,
                usedPercent: used,
                resetsAt: date(object["resets_at"], now: now)
            )
        )
    }

    private static func requireSuccess(
        _ response: UsageHTTPResponse
    ) throws {
        if response.statusCode == 401 || response.statusCode == 403 {
            throw UsageScanError.notAuthenticated
        }
        guard (200..<300).contains(response.statusCode) else {
            throw UsageScanError.requestFailed(response.statusCode)
        }
    }

    private static func json(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            number.doubleValue
        case let string as String:
            Double(string)
        default:
            nil
        }
    }

    private static func resetDate(
        _ window: [String: Any],
        now: Date
    ) -> Date? {
        if let seconds = number(window["reset_at"]) {
            return Date(timeIntervalSince1970: seconds)
        }
        if let delay = number(window["reset_after_seconds"]) {
            return now.addingTimeInterval(delay)
        }
        return nil
    }

    private static func date(_ value: Any?, now: Date) -> Date? {
        if let seconds = number(value) {
            let normalized =
                abs(seconds) < 10_000_000_000
                ? seconds
                : seconds / 1_000
            return Date(timeIntervalSince1970: normalized)
        }
        guard let value = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func planName(_ value: String?) -> String? {
        guard
            let value = value?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !value.isEmpty
        else {
            return nil
        }
        switch value.lowercased() {
        case "prolite":
            return "Pro 5x"
        case "pro":
            return "Pro 20x"
        default:
            return
                value
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }
}

private struct CodexUsageCredential: Decodable {
    let accessToken: String
    let accountID: String?

    static func load(from home: URL, fallback: URL) -> Self? {
        let candidates = [
            home.appending(path: "auth.json"),
            fallback.appending(path: "auth.json"),
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                let root = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                let tokens = root["tokens"] as? [String: Any],
                let accessToken = tokens["access_token"] as? String,
                !accessToken.isEmpty
            else {
                continue
            }
            return Self(
                accessToken: accessToken,
                accountID: tokens["account_id"] as? String
            )
        }
        return nil
    }
}

private struct ClaudeUsageCredential: Sendable {
    let accessToken: String
    let subscriptionType: String?

    static func load(from home: URL, allowKeychain: Bool) -> Self? {
        if allowKeychain, let keychain = loadKeychain() {
            return keychain
        }
        let url = home.appending(path: ".credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    private static func loadKeychain() -> Self? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else {
            return nil
        }
        return parse(data)
    }

    private static func parse(_ data: Data) -> Self? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String,
            !accessToken.isEmpty
        else {
            return nil
        }
        return Self(
            accessToken: accessToken,
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }
}

private struct LocalUsagePeriods: Sendable {
    var today = LocalUsageTotals()
    var lastSevenDays = LocalUsageTotals()
    var lastThirtyDays = LocalUsageTotals()
}

/// Folds events into period totals as they are parsed. Retaining every parsed
/// event and then filtering it three times made peak memory scale with the size
/// of the log corpus, which is what exhausted RAM on a large history.
private struct LocalUsageAccumulator {
    private let todayStart: Date
    private let weekStart: Date
    private let monthStart: Date
    private var today = RunningTotals()
    private var week = RunningTotals()
    private var month = RunningTotals()
    private var seen: Set<UInt64> = []

    init(now: Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        todayStart = start
        weekStart =
            calendar.date(byAdding: .day, value: -6, to: start) ?? start
        monthStart =
            calendar.date(byAdding: .day, value: -29, to: start) ?? start
    }

    var periods: LocalUsagePeriods {
        LocalUsagePeriods(
            today: today.totals,
            lastSevenDays: week.totals,
            lastThirtyDays: month.totals
        )
    }

    /// `identity` runs only for events inside a reported window, so older lines
    /// cost no hashing and never enlarge the dedup set. The set stores digests
    /// rather than key strings to keep the per-event cost at eight bytes.
    mutating func add(
        _ event: UsageEvent,
        identity: (inout Hasher) -> Void
    ) {
        guard event.date >= monthStart else { return }

        var hasher = Hasher()
        identity(&hasher)
        let digest = UInt64(bitPattern: Int64(hasher.finalize()))
        guard seen.insert(digest).inserted else { return }

        month.add(event)
        if event.date >= weekStart { week.add(event) }
        if event.date >= todayStart { today.add(event) }
    }

    private struct RunningTotals {
        private var inputTokens: UInt64 = 0
        private var outputTokens: UInt64 = 0
        private var turnCount = 0

        var totals: LocalUsageTotals {
            LocalUsageTotals(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                turnCount: turnCount
            )
        }

        mutating func add(_ event: UsageEvent) {
            inputTokens &+= event.input
            outputTokens &+= event.output
            turnCount += 1
        }
    }
}

private enum LocalUsageLogScanner {
    static func scanCodex(home: URL, now: Date) -> LocalUsagePeriods {
        var accumulator = LocalUsageAccumulator(now: now)
        for directory in [
            home.appending(path: "sessions"),
            home.appending(path: "archived_sessions"),
        ] {
            enumerateJSONL(in: directory, since: cutoff(now)) { object in
                guard object["type"] as? String == "event_msg",
                    let payload = object["payload"] as? [String: Any],
                    payload["type"] as? String == "token_count",
                    let info = payload["info"] as? [String: Any],
                    let usage = info["last_token_usage"] as? [String: Any],
                    let event = usageEvent(
                        usage,
                        timestamp: object["timestamp"]
                    )
                else {
                    return
                }
                accumulator.add(event) { hasher in
                    hasher.combine(event.date)
                    hasher.combine(event.input)
                    hasher.combine(event.output)
                }
            }
        }
        return accumulator.periods
    }

    static func scanClaude(home: URL, now: Date) -> LocalUsagePeriods {
        var accumulator = LocalUsageAccumulator(now: now)
        enumerateJSONL(
            in: home.appending(path: "projects"),
            since: cutoff(now)
        ) { object in
            guard object["type"] as? String == "assistant",
                let message = object["message"] as? [String: Any],
                let usage = message["usage"] as? [String: Any],
                let event = usageEvent(
                    usage,
                    timestamp: object["timestamp"]
                )
            else {
                return
            }
            accumulator.add(event) { hasher in
                if let id = message["id"] as? String {
                    hasher.combine(id)
                } else {
                    hasher.combine(event.date)
                    hasher.combine(event.input)
                    hasher.combine(event.output)
                }
            }
        }
        return accumulator.periods
    }

    private static func usageEvent(
        _ usage: [String: Any],
        timestamp: Any?
    ) -> UsageEvent? {
        let input =
            uint(usage["input_tokens"])
            + uint(usage["cache_creation_input_tokens"])
            + uint(usage["cache_read_input_tokens"])
            + uint(usage["cached_input_tokens"])
        let output = uint(usage["output_tokens"])
        guard input > 0 || output > 0,
            let date = date(timestamp)
        else {
            return nil
        }
        return UsageEvent(date: date, input: input, output: output)
    }

    private static func enumerateJSONL(
        in root: URL,
        since cutoff: Date,
        visit: @escaping ([String: Any]) -> Void
    ) {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .contentModificationDateKey,
        ]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { return }
            guard url.pathExtension == "jsonl",
                let values = try? url.resourceValues(forKeys: keys),
                values.isRegularFile == true,
                values.contentModificationDate.map({ $0 >= cutoff }) == true
            else {
                continue
            }
            enumerateLines(in: url, visit: visit)
        }
    }

    private static func enumerateLines(
        in url: URL,
        visit: ([String: Any]) -> Void
    ) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return
        }
        defer { try? handle.close() }

        var buffer = Data()
        while let chunk = try? handle.read(upToCount: 256 * 1_024),
            !chunk.isEmpty
        {
            // The sweep runs for minutes over a large history, so it has to be
            // interruptible between chunks rather than only between files.
            if Task.isCancelled { return }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                parseLine(Data(buffer[..<newline]), visit: visit)
                buffer.removeSubrange(...newline)
            }
        }
        if !buffer.isEmpty {
            parseLine(buffer, visit: visit)
        }
    }

    private static func parseLine(
        _ data: Data,
        visit: ([String: Any]) -> Void
    ) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            return
        }
        visit(object)
    }

    private static func cutoff(_ now: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: -30, to: now)
            ?? now.addingTimeInterval(-30 * 86_400)
    }

    private static func uint(_ value: Any?) -> UInt64 {
        switch value {
        case let number as NSNumber:
            max(0, number.int64Value).magnitude
        case let string as String:
            UInt64(string) ?? 0
        default:
            0
        }
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        guard let value = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}

private struct UsageEvent {
    let date: Date
    let input: UInt64
    let output: UInt64
}
