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

/// Holds a keychain-sourced credential for the lifetime of the scanner so that
/// approving the macOS dialog once is enough. Re-reading on every refresh is what
/// produced a stream of identical consent prompts.
actor ClaudeCredentialCache {
    private var cached: ClaudeUsageCredential?

    func credential(
        home: URL,
        access: ClaudeKeychainAccess,
        readKeychain: () -> ClaudeCredentialLookup
    ) -> ClaudeCredentialLookup {
        if let cached {
            return .found(cached)
        }
        let lookup = ClaudeUsageCredential.load(
            from: home,
            access: access,
            readKeychain: readKeychain
        )
        if case let .found(credential) = lookup {
            cached = credential
        }
        return lookup
    }

    /// Called only when the provider rejects the token, so a rotated credential
    /// is picked up without reintroducing routine prompting.
    func invalidate() {
        cached = nil
    }
}

public struct UsageScanner: Sendable {
    private let homeDirectory: URL
    private let environment: [String: String]
    private let http: any UsageHTTPClient
    private let claudeKeychainAccess: ClaudeKeychainAccess
    private let claudeCredentials: ClaudeCredentialCache
    private let readClaudeKeychain: @Sendable () -> ClaudeCredentialLookup

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        http: any UsageHTTPClient = SystemUsageHTTPClient(),
        claudeKeychainAccess: ClaudeKeychainAccess = .unasked
    ) {
        self.init(
            homeDirectory: homeDirectory,
            environment: environment,
            http: http,
            claudeKeychainAccess: claudeKeychainAccess,
            readClaudeKeychain: { ClaudeUsageCredential.loadKeychain() }
        )
    }

    /// The keychain read is injectable so tests can cover consent behaviour
    /// without touching the real keychain, which would block on a dialog nobody
    /// can answer on a build machine.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        http: any UsageHTTPClient = SystemUsageHTTPClient(),
        claudeKeychainAccess: ClaudeKeychainAccess = .unasked,
        readClaudeKeychain: @escaping @Sendable () -> ClaudeCredentialLookup
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.http = http
        self.claudeKeychainAccess = claudeKeychainAccess
        self.readClaudeKeychain = readClaudeKeychain
        claudeCredentials = ClaudeCredentialCache()
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

        let credential: ClaudeUsageCredential
        switch await claudeCredentials.credential(
            home: home,
            access: claudeKeychainAccess,
            readKeychain: readClaudeKeychain
        ) {
        case let .found(found):
            credential = found
        case .needsConsent:
            return snapshot(
                provider: .claude,
                local: local,
                now: now,
                state: local.lastThirtyDays.hasData
                    ? .needsConsent(Self.claudeConsentExplanation)
                    : .notConfigured("Run `claude` and sign in to begin tracking.")
            )
        case .declined:
            return snapshot(
                provider: .claude,
                local: local,
                now: now,
                state: .consentDeclined(
                    "Live limits are off. Local token counts still work."
                )
            )
        case .missing:
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
            if case UsageScanError.notAuthenticated = error {
                // The stored token no longer works, so drop it and let the next
                // refresh read a rotated one.
                await claudeCredentials.invalidate()
            }
            return snapshot(
                provider: .claude,
                local: local,
                now: now,
                state: .unavailable(error.localizedDescription)
            )
        }
    }

    private static let claudeConsentExplanation = """
        Claude Code keeps your login token in the macOS keychain. Unhog needs \
        your permission to read it, so macOS will show one keychain prompt.
        """

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
        return ISO8601Timestamp.date(from: value)
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

enum ClaudeCredentialLookup: Sendable {
    case found(ClaudeUsageCredential)
    /// A keychain read was never attempted because the user has not been asked.
    case needsConsent
    /// A keychain read was attempted and the user refused it.
    case declined
    case missing
}

struct ClaudeUsageCredential: Sendable {
    let accessToken: String
    let subscriptionType: String?

    static func load(
        from home: URL,
        access: ClaudeKeychainAccess,
        readKeychain: () -> ClaudeCredentialLookup
    ) -> ClaudeCredentialLookup {
        if access == .allowed {
            switch readKeychain() {
            case let .found(credential):
                return .found(credential)
            case .declined:
                return .declined
            case .missing, .needsConsent:
                break
            }
        }

        // The plain file is only used by Claude Code on systems without a
        // keychain, but reading it costs nothing and never prompts.
        let url = home.appending(path: ".credentials.json")
        if let data = try? Data(contentsOf: url), let parsed = parse(data) {
            return .found(parsed)
        }

        switch access {
        case .unasked:
            return .needsConsent
        case .declined:
            return .declined
        case .allowed:
            return .missing
        }
    }

    static func loadKeychain() -> ClaudeCredentialLookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        // Refusing the dialog is reported as a cancelled or failed
        // authorization. Anything else means the item simply is not readable,
        // which is not a decision worth remembering.
        if status == errSecUserCanceled || status == errSecAuthFailed {
            return .declined
        }
        guard status == errSecSuccess,
            let data = result as? Data,
            let parsed = parse(data)
        else {
            return .missing
        }
        return .found(parsed)
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
            enumerateJSONL(
                in: directory,
                since: cutoff(now),
                matching: Array("token_count".utf8)
            ) { object in
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
            since: cutoff(now),
            // Every line this scan wants carries a "usage" object; the marker is
            // the same key the guard below reads, so nothing is filtered out that
            // would otherwise have counted.
            matching: Array("\"usage\"".utf8)
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

    /// `marker` is a byte sequence every line of interest must contain.
    ///
    /// Agent transcripts are mostly prose, tool output, and inlined images: this
    /// machine holds 3.2 GB of them describing 197,000 usage events, so fewer than
    /// one line in a hundred carries a number worth reading. Testing for the key
    /// before handing the line to JSONSerialization avoids building a dictionary
    /// tree for the rest, which is where nearly all of the memory went.
    private static func enumerateJSONL(
        in root: URL,
        since cutoff: Date,
        matching marker: [UInt8],
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
            enumerateLines(in: url, matching: marker, visit: visit)
        }
    }

    /// Reads with two buffers that live for the whole file and are reused.
    ///
    /// Reading through `FileHandle` hands back a freshly allocated `Data` per
    /// chunk, so sweeping three gigabytes allocated and released three gigabytes
    /// of them. Almost none of it stays live, but the allocator keeps the pages,
    /// and the process footprint is what the rest of the machine has to live
    /// with. Reusing one chunk buffer and one line buffer keeps the sweep's
    /// allocation roughly constant regardless of how much history there is.
    private static func enumerateLines(
        in url: URL,
        matching marker: [UInt8],
        visit: ([String: Any]) -> Void
    ) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return
        }
        defer { try? handle.close() }

        let descriptor = handle.fileDescriptor
        let chunkSize = 256 * 1_024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var line: [UInt8] = []
        line.reserveCapacity(64 * 1_024)

        while true {
            // The sweep runs for a while over a large history, so it has to be
            // interruptible between chunks rather than only between files.
            if Task.isCancelled { return }

            let count = chunk.withUnsafeMutableBytes {
                read(descriptor, $0.baseAddress, chunkSize)
            }
            guard count > 0 else { break }

            // Foundation's JSON reader hands back autoreleased objects, and a
            // sweep of thousands of files never reaches a drain point on its own.
            autoreleasepool {
                chunk.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    var start = 0
                    while start < count,
                        let hit = memchr(base + start, 0x0A, count - start)
                    {
                        let newline = UnsafeRawPointer(hit) - base
                        let region = UnsafeRawBufferPointer(
                            start: base + start,
                            count: newline - start
                        )
                        // Most lines arrive whole inside one read, and those are
                        // examined where they lie: only a line split across two
                        // reads has to be assembled in the carry-over buffer.
                        if line.isEmpty {
                            if contains(marker, in: region) {
                                parseLine(Data(region), visit: visit)
                            }
                        } else {
                            line.append(contentsOf: region)
                            consume(&line, matching: marker, visit: visit)
                        }
                        start = newline + 1
                    }
                    if start < count {
                        line.append(
                            contentsOf: UnsafeRawBufferPointer(
                                start: base + start,
                                count: count - start
                            )
                        )
                    }
                }
            }
        }

        if !line.isEmpty {
            autoreleasepool {
                consume(&line, matching: marker, visit: visit)
            }
        }
    }

    private static func contains(
        _ marker: [UInt8],
        in region: UnsafeRawBufferPointer
    ) -> Bool {
        guard let base = region.baseAddress, region.count >= marker.count else {
            return false
        }
        return marker.withUnsafeBytes { needle in
            guard let start = needle.baseAddress else { return false }
            return memmem(base, region.count, start, needle.count) != nil
        }
    }

    /// Empties `line` while keeping its capacity, so the next line reuses it.
    private static func consume(
        _ line: inout [UInt8],
        matching marker: [UInt8],
        visit: ([String: Any]) -> Void
    ) {
        defer { line.removeAll(keepingCapacity: true) }
        let matched = line.withUnsafeBytes { contains(marker, in: $0) }
        guard matched else { return }
        parseLine(Data(line), visit: visit)
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
        return ISO8601Timestamp.date(from: value)
    }
}

/// Reads the timestamps agents actually write.
///
/// Both Claude and Codex stamp to the millisecond, and `ISO8601DateFormatter`
/// ignores fractional seconds unless asked — but once asked, it then refuses
/// timestamps that lack them. Neither spelling alone reads every line, so both
/// are kept. They are also built once: the formatter is expensive to create and
/// this is called for every usage line in the history.
private enum ISO8601Timestamp {
    nonisolated(unsafe) private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let wholeSeconds = ISO8601DateFormatter()

    static func date(from value: String) -> Date? {
        withFractionalSeconds.date(from: value) ?? wholeSeconds.date(from: value)
    }
}

private struct UsageEvent {
    let date: Date
    let input: UInt64
    let output: UInt64
}
