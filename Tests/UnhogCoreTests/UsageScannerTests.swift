import Foundation
import Testing
@testable import UnhogCore

struct UsageScannerTests {
    @Test
    func codexPayloadReportsSessionWeeklyAndCredits() throws {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let response = UsageHTTPResponse(
            statusCode: 200,
            body: Data(
                """
                {
                  "plan_type": "pro",
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 31,
                      "limit_window_seconds": 18000,
                      "reset_after_seconds": 900
                    },
                    "secondary_window": {
                      "used_percent": 57,
                      "limit_window_seconds": 604800,
                      "reset_at": 1720100000
                    }
                  },
                  "credits": { "balance": 796 }
                }
                """.utf8
            )
        )

        let usage = try UsagePayloadParser.codex(response, now: now)

        #expect(usage.plan == "Pro 20x")
        #expect(usage.windows.map(\.label) == ["Session", "Weekly"])
        #expect(usage.windows.map(\.usedPercent) == [31, 57])
        #expect(
            usage.windows[0].resetsAt
                == now.addingTimeInterval(900)
        )
        #expect(usage.creditBalance == 796)
    }

    @Test
    func claudePayloadReportsSubscriptionWindows() throws {
        let response = UsageHTTPResponse(
            statusCode: 200,
            body: Data(
                """
                {
                  "five_hour": {
                    "utilization": 68,
                    "resets_at": "2026-07-24T20:00:00Z"
                  },
                  "seven_day": {
                    "utilization": 41,
                    "resets_at": "2026-07-28T20:00:00Z"
                  },
                  "seven_day_sonnet": null,
                  "extra_usage": {
                    "is_enabled": true,
                    "used_credits": 499
                  }
                }
                """.utf8
            )
        )

        let usage = try UsagePayloadParser.claude(
            response,
            subscriptionType: "max_5x",
            now: Date()
        )

        #expect(usage.plan == "Max 5x")
        #expect(usage.windows.map(\.label) == ["Session", "Weekly"])
        #expect(usage.windows.map(\.usedPercent) == [68, 41])
        #expect(usage.creditBalance == 4.99)
    }

    @Test
    func localLogsBecomeAggregateUsageInsteadOfSessionContent() async throws {
        let fixture = try UsageFixture()
        defer { fixture.remove() }
        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-07-24T12:00:00Z")
        )

        try fixture.writeCodex(
            """
            {"timestamp":"2026-07-24T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":300,"output_tokens":80}}}}
            {"timestamp":"2026-07-24T10:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":700,"output_tokens":40}}}}
            """
        )
        try fixture.writeClaude(
            """
            {"timestamp":"2026-07-24T09:00:00Z","type":"assistant","message":{"id":"msg-1","usage":{"input_tokens":900,"cache_read_input_tokens":100,"output_tokens":50}}}
            {"timestamp":"2026-07-24T09:00:01Z","type":"assistant","message":{"id":"msg-1","usage":{"input_tokens":900,"cache_read_input_tokens":100,"output_tokens":50}}}
            """
        )

        let snapshots = await fixture.scanner.scan(now: now)
        let codex = try #require(
            snapshots.first { $0.provider == .codex }
        )
        let claude = try #require(
            snapshots.first { $0.provider == .claude }
        )

        #expect(codex.today.inputTokens == 2_200)
        #expect(codex.today.outputTokens == 120)
        #expect(codex.today.turnCount == 2)
        #expect(
            codex.connectionState
                == .localOnly("Sign in with Codex to add live limits.")
        )

        #expect(claude.today.inputTokens == 1_000)
        #expect(claude.today.outputTokens == 50)
        #expect(claude.today.turnCount == 1)
        #expect(
            claude.connectionState
                == .localOnly("Sign in with Claude Code to add live limits.")
        )
    }
}

private struct UsageFixture {
    let root: URL
    let scanner: UsageScanner

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "unhog-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        // Permission is granted but the stubbed keychain holds nothing, which is
        // the "signed out" case without ever reading the real keychain.
        scanner = UsageScanner(
            homeDirectory: root,
            environment: [:],
            http: NoopUsageHTTPClient(),
            claudeKeychainAccess: .allowed,
            readClaudeKeychain: { .missing }
        )
    }

    func writeCodex(_ text: String) throws {
        try write(
            text,
            to: root.appending(
                path: ".codex/sessions/2026/07/24/codex.jsonl"
            )
        )
    }

    func writeClaude(_ text: String) throws {
        try write(
            text,
            to: root.appending(
                path: ".claude/projects/unhog/claude.jsonl"
            )
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }
}

private struct NoopUsageHTTPClient: UsageHTTPClient {
    func get(
        _ url: URL,
        headers: [String: String]
    ) async throws -> UsageHTTPResponse {
        throw UsageScanError.notAuthenticated
    }
}
