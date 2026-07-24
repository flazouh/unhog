import Foundation
import Testing

@testable import UnhogCore

/// Claude Code's login token lives in a keychain item that belongs to Claude
/// Code, so macOS asks the user to approve every read by another app. These tests
/// pin the behaviour that keeps that dialog from reappearing: never read before
/// asking, read at most once after being allowed, and never read again after a
/// refusal.
@Suite("Claude keychain consent")
struct ClaudeKeychainConsentTests {
    @Test("Before being asked, nothing reads the keychain")
    func unaskedNeverReadsTheKeychain() async throws {
        let fixture = try ConsentFixture(access: .unasked, lookup: .missing)
        try fixture.writeClaudeTurn()

        let claude = try await fixture.scanClaude()

        #expect(await fixture.reads() == 0)
        if case let .needsConsent(message) = claude.connectionState {
            #expect(message.contains("keychain"))
            #expect(message.contains("permission"))
        } else {
            Issue.record("Expected needsConsent, got \(claude.connectionState)")
        }
    }

    @Test("Without any local history, consent is not requested")
    func noHistoryMeansNoRequest() async throws {
        let fixture = try ConsentFixture(access: .unasked, lookup: .missing)

        let claude = try await fixture.scanClaude()

        #expect(await fixture.reads() == 0)
        if case .notConfigured = claude.connectionState {
        } else {
            Issue.record("Expected notConfigured, got \(claude.connectionState)")
        }
    }

    @Test("A refusal is reported so it can be remembered")
    func refusalIsSurfaced() async throws {
        let fixture = try ConsentFixture(access: .allowed, lookup: .declined)
        try fixture.writeClaudeTurn()

        let claude = try await fixture.scanClaude()

        #expect(await fixture.reads() == 1)
        if case .consentDeclined = claude.connectionState {
        } else {
            Issue.record(
                "Expected consentDeclined, got \(claude.connectionState)"
            )
        }
    }

    @Test("After a refusal is recorded, the keychain is left alone")
    func declinedAccessNeverReads() async throws {
        let fixture = try ConsentFixture(access: .declined, lookup: .declined)
        try fixture.writeClaudeTurn()

        _ = try await fixture.scanClaude()

        #expect(await fixture.reads() == 0)
    }

    @Test("Repeated refreshes read the keychain only once")
    func grantedAccessReadsOnce() async throws {
        let fixture = try ConsentFixture(
            access: .allowed,
            lookup: .found(
                ClaudeUsageCredential(
                    accessToken: "token",
                    subscriptionType: "max"
                )
            )
        )
        try fixture.writeClaudeTurn()

        for _ in 0..<4 {
            _ = try await fixture.scanClaude()
        }

        // The whole point: four refreshes, one consent dialog.
        #expect(await fixture.reads() == 1)
    }

    @Test("A rejected token is re-read so a rotated one can replace it")
    func rejectedTokenIsReRead() async throws {
        let fixture = try ConsentFixture(
            access: .allowed,
            lookup: .found(
                ClaudeUsageCredential(
                    accessToken: "stale",
                    subscriptionType: nil
                )
            ),
            http: RejectingUsageHTTPClient()
        )
        try fixture.writeClaudeTurn()

        _ = try await fixture.scanClaude()
        _ = try await fixture.scanClaude()

        // Caching must not outlive a token the provider refuses.
        #expect(await fixture.reads() == 2)
    }

    @Test("Local token counts survive a refusal")
    func localTotalsStillReported() async throws {
        let fixture = try ConsentFixture(access: .declined, lookup: .declined)
        try fixture.writeClaudeTurn()

        let claude = try await fixture.scanClaude()

        #expect(claude.today.inputTokens == 120)
        #expect(claude.today.outputTokens == 50)
        #expect(claude.today.turnCount == 1)
    }
}

private actor ReadCounter {
    private var count = 0

    func record() {
        count += 1
    }

    func total() -> Int {
        count
    }
}

/// Fails in a way that says nothing about the token's validity, so a cached
/// credential should survive.
private struct UnreachableUsageHTTPClient: UsageHTTPClient {
    func get(
        _ url: URL,
        headers: [String: String]
    ) async throws -> UsageHTTPResponse {
        throw UsageScanError.invalidResponse
    }
}

/// Rejects the token outright, which is the signal that it needs re-reading.
private struct RejectingUsageHTTPClient: UsageHTTPClient {
    func get(
        _ url: URL,
        headers: [String: String]
    ) async throws -> UsageHTTPResponse {
        throw UsageScanError.notAuthenticated
    }
}

private struct ConsentFixture {
    let root: URL
    let scanner: UsageScanner
    private let counter = ReadCounter()

    init(
        access: ClaudeKeychainAccess,
        lookup: ClaudeCredentialLookup,
        http: any UsageHTTPClient = UnreachableUsageHTTPClient()
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "unhog-consent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let counter = counter
        scanner = UsageScanner(
            homeDirectory: root,
            environment: [:],
            http: http,
            claudeKeychainAccess: access,
            readClaudeKeychain: {
                // Counting the reads is how "asked once" becomes observable.
                Task { await counter.record() }
                return lookup
            }
        )
    }

    func reads() async -> Int {
        // Let the counting tasks settle before reading the tally.
        try? await Task.sleep(for: .milliseconds(40))
        return await counter.total()
    }

    /// Fixed so the written turn always falls inside the "today" window.
    static let now = Date(timeIntervalSince1970: 1_784_894_400)

    func scanClaude() async throws -> ProviderUsageSnapshot {
        let snapshots = await scanner.scan(now: Self.now)
        return try #require(snapshots.first { $0.provider == .claude })
    }

    func writeClaudeTurn() throws {
        let stamp = ISO8601DateFormatter().string(
            from: Self.now.addingTimeInterval(-3_600)
        )
        let line = """
            {"timestamp":"\(stamp)","type":"assistant","message":\
            {"id":"m1","usage":{"input_tokens":120,"output_tokens":50}}}
            """
        let url = root.appending(path: ".claude/projects/unhog/claude.jsonl")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(line.utf8).write(to: url)
    }
}
