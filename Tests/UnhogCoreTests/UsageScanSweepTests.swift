import Foundation
import Testing
@testable import UnhogCore

@Suite("Usage log sweep")
struct UsageScanSweepTests {
    /// The sweep used to run on a detached task, which does not inherit
    /// cancellation. Closing the tab left the scan running to completion, so
    /// every reopen stacked another full-CPU sweep on top of the last one.
    @Test("Cancelling a sweep stops the file walk")
    func cancellationStopsSweep() async throws {
        let fixture = try UsageLogFixture()
        defer { fixture.remove() }

        try fixture.writeClaudeSessions(fileCount: 60, linesPerFile: 3_000)

        let task = Task { await fixture.scanner.scan(now: Date()) }
        task.cancel()

        let started = ContinuousClock.now
        _ = await task.value
        let elapsed = ContinuousClock.now - started

        // An uncancelled sweep over this corpus takes roughly 15 seconds.
        #expect(elapsed < .seconds(5))
    }

    /// Totals are folded in as lines are parsed rather than collected and
    /// filtered afterwards, so the window boundaries need their own cover.
    @Test("Each event lands in every window it belongs to")
    func eventsFallIntoTheirWindows() async throws {
        let fixture = try UsageLogFixture()
        defer { fixture.remove() }

        let now = Date()
        try fixture.writeClaudeEvents(
            [
                ClaudeEvent(id: "today", daysAgo: 0, input: 100, output: 10),
                ClaudeEvent(id: "week", daysAgo: 3, input: 200, output: 20),
                ClaudeEvent(id: "month", daysAgo: 10, input: 400, output: 40),
                ClaudeEvent(id: "old", daysAgo: 40, input: 800, output: 80),
            ],
            now: now
        )

        let snapshots = await fixture.scanner.scan(now: now)
        let claude = try #require(snapshots.first { $0.provider == .claude })

        #expect(claude.today.turnCount == 1)
        #expect(claude.today.inputTokens == 100)
        #expect(claude.lastSevenDays.turnCount == 2)
        #expect(claude.lastSevenDays.inputTokens == 300)
        #expect(claude.lastThirtyDays.turnCount == 3)
        #expect(claude.lastThirtyDays.inputTokens == 700)
    }

    @Test("A message repeated across files counts once")
    func duplicateMessagesCountOnce() async throws {
        let fixture = try UsageLogFixture()
        defer { fixture.remove() }

        let now = Date()
        let event = ClaudeEvent(
            id: "shared",
            daysAgo: 0,
            input: 100,
            output: 10
        )
        try fixture.writeClaudeEvents([event], now: now, session: "a")
        try fixture.writeClaudeEvents([event], now: now, session: "b")

        let snapshots = await fixture.scanner.scan(now: now)
        let claude = try #require(snapshots.first { $0.provider == .claude })

        #expect(claude.today.turnCount == 1)
        #expect(claude.today.inputTokens == 100)
    }
}

struct ClaudeEvent {
    let id: String
    let daysAgo: Int
    let input: UInt64
    let output: UInt64
}

struct UsageLogFixture {
    let root: URL
    let scanner: UsageScanner

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "unhog-usage-logs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        scanner = UsageScanner(
            homeDirectory: root,
            environment: [:],
            http: OfflineUsageHTTPClient(),
            claudeKeychainAccess: .declined
        )
    }

    func writeClaudeEvents(
        _ events: [ClaudeEvent],
        now: Date,
        session: String = "main"
    ) throws {
        let calendar = Calendar.current
        let formatter = ISO8601DateFormatter()
        let body =
            try events
            .map { event in
                let date = try #require(
                    calendar.date(
                        byAdding: .day,
                        value: -event.daysAgo,
                        to: now
                    )
                )
                return """
                    {"timestamp":"\(formatter.string(from: date))",\
                    "type":"assistant","message":{"id":"\(event.id)",\
                    "usage":{"input_tokens":\(event.input),\
                    "output_tokens":\(event.output)}}}
                    """
            }
            .joined(separator: "\n")
        try write(
            body,
            to: root.appending(
                path: ".claude/projects/\(session)/session.jsonl"
            )
        )
    }

    /// Each line carries a unique message id so deduplication keeps every event.
    func writeClaudeSessions(fileCount: Int, linesPerFile: Int) throws {
        for index in 0..<fileCount {
            let body = (0..<linesPerFile)
                .map { line in
                    """
                    {"timestamp":"2026-07-24T09:00:00Z","type":"assistant",\
                    "message":{"id":"m\(index)-\(line)","usage":\
                    {"input_tokens":900,"cache_read_input_tokens":100,\
                    "output_tokens":50}}}
                    """
                }
                .joined(separator: "\n")
            try write(
                body,
                to: root.appending(
                    path: ".claude/projects/p\(index)/session.jsonl"
                )
            )
        }
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

private struct OfflineUsageHTTPClient: UsageHTTPClient {
    func get(
        _ url: URL,
        headers: [String: String]
    ) async throws -> UsageHTTPResponse {
        throw UsageScanError.notAuthenticated
    }
}
