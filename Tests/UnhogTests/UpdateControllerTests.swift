import CryptoKit
import Foundation
import Testing
import UnhogCore
@testable import Unhog

/// These tests exercise the half of the update path that has never run in
/// anger: a check that fails, and a download whose bytes have to be trusted.
/// The suite is serialized because the stubbed responses live in shared
/// protocol state.
@Suite("Update controller", .serialized)
struct UpdateControllerTests {
    @Test("A failed check does not spend the daily budget")
    @MainActor
    func failedCheckDoesNotConsumeTheInterval() async throws {
        let stub = StubNetwork()
        stub.route(latestReleaseURL, status: 500, body: Data("nope".utf8))
        defer { stub.reset() }

        let controller = makeController(stub: stub, defaults: try scratchDefaults())

        await controller.checkForUpdatesIfNeeded(automaticallyCheck: true)
        #expect(stub.requestCount(for: latestReleaseURL) == 1)

        // Before the fix the timestamp was written up front, so this second
        // call was suppressed and the user waited a day for another attempt.
        await controller.checkForUpdatesIfNeeded(automaticallyCheck: true)
        #expect(stub.requestCount(for: latestReleaseURL) == 2)
    }

    @Test("A successful check does spend the daily budget")
    @MainActor
    func successfulCheckConsumesTheInterval() async throws {
        let stub = StubNetwork()
        stub.route(
            latestReleaseURL,
            status: 200,
            body: releaseJSON(tag: "v0.1.3", withChecksum: false)
        )
        defer { stub.reset() }

        let controller = makeController(stub: stub, defaults: try scratchDefaults())

        await controller.checkForUpdatesIfNeeded(automaticallyCheck: true)
        #expect(controller.state == .upToDate)
        #expect(stub.requestCount(for: latestReleaseURL) == 1)

        await controller.checkForUpdatesIfNeeded(automaticallyCheck: true)
        #expect(stub.requestCount(for: latestReleaseURL) == 1)
    }

    @Test("A tampered download is refused and never lands on disk")
    @MainActor
    func rejectsChecksumMismatch() async throws {
        let stub = StubNetwork()
        let installer = Data("a disk image".utf8)
        stub.route(
            latestReleaseURL,
            status: 200,
            body: releaseJSON(tag: "v0.1.4", withChecksum: true)
        )
        stub.route(installerURL, status: 200, body: installer)
        stub.route(
            checksumURL,
            status: 200,
            body: Data("\(String(repeating: "0", count: 64))  Unhog-0.1.4.dmg\n".utf8)
        )
        defer { stub.reset() }

        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = makeController(
            stub: stub,
            defaults: try scratchDefaults(),
            downloads: folder
        )

        await controller.checkForUpdates(
            showUpToDateAlert: false,
            showUpdateAlert: false
        )
        guard case .updateAvailable = controller.state else {
            Issue.record("Expected an available update, got \(controller.state).")
            return
        }

        await controller.downloadUpdate()

        guard case let .downloadFailed(message) = controller.state else {
            Issue.record("Expected the download to fail, got \(controller.state).")
            return
        }
        #expect(message == ReleaseUpdateError.checksumMismatch.errorDescription)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test("A matching checksum lets the download through")
    @MainActor
    func acceptsMatchingChecksum() async throws {
        let stub = StubNetwork()
        let installer = Data("a disk image".utf8)
        let digest = SHA256.hash(data: installer)
            .map { String(format: "%02x", $0) }
            .joined()
        stub.route(
            latestReleaseURL,
            status: 200,
            body: releaseJSON(tag: "v0.1.4", withChecksum: true)
        )
        stub.route(installerURL, status: 200, body: installer)
        stub.route(
            checksumURL,
            status: 200,
            body: Data("\(digest)  Unhog-0.1.4.dmg\n".utf8)
        )
        defer { stub.reset() }

        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = makeController(
            stub: stub,
            defaults: try scratchDefaults(),
            downloads: folder
        )

        await controller.checkForUpdates(
            showUpToDateAlert: false,
            showUpdateAlert: false
        )
        await controller.downloadUpdate()

        guard case let .readyToInstall(url) = controller.state else {
            Issue.record("Expected a ready installer, got \(controller.state).")
            return
        }
        #expect(url.lastPathComponent == "Unhog-0.1.4.dmg")
        #expect(try Data(contentsOf: url) == installer)
    }

    @Test("Retrying a failed download does not ask GitHub again")
    @MainActor
    func retryReusesTheKnownUpdate() async throws {
        let stub = StubNetwork()
        let installer = Data("a disk image".utf8)
        let digest = SHA256.hash(data: installer)
            .map { String(format: "%02x", $0) }
            .joined()
        stub.route(
            latestReleaseURL,
            status: 200,
            body: releaseJSON(tag: "v0.1.4", withChecksum: true)
        )
        stub.route(installerURL, status: 200, body: installer)
        // A truncated transfer the first time round.
        stub.route(
            checksumURL,
            status: 200,
            body: Data("\(String(repeating: "0", count: 64))  Unhog-0.1.4.dmg\n".utf8)
        )
        defer { stub.reset() }

        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = makeController(
            stub: stub,
            defaults: try scratchDefaults(),
            downloads: folder
        )

        await controller.checkForUpdates(
            showUpToDateAlert: false,
            showUpdateAlert: false
        )
        await controller.downloadUpdate()
        guard case .downloadFailed = controller.state else {
            Issue.record("Expected a failed download, got \(controller.state).")
            return
        }

        stub.route(
            checksumURL,
            status: 200,
            body: Data("\(digest)  Unhog-0.1.4.dmg\n".utf8)
        )
        await controller.downloadUpdate()

        guard case .readyToInstall = controller.state else {
            Issue.record("Expected the retry to succeed, got \(controller.state).")
            return
        }
        // The retry button must work off what is already known, not send the
        // user back through a fresh check to get the button back.
        #expect(stub.requestCount(for: latestReleaseURL) == 1)
    }

    // MARK: - Fixtures

    private var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/flazouh/unhog/releases/latest")!
    }

    private var installerURL: URL {
        URL(string: "https://example.com/Unhog-0.1.4.dmg")!
    }

    private var checksumURL: URL {
        URL(string: "https://example.com/Unhog-0.1.4.dmg.sha256")!
    }

    @MainActor
    private func makeController(
        stub: StubNetwork,
        defaults: UserDefaults,
        downloads: URL? = nil
    ) -> UpdateController {
        UpdateController(
            session: stub.session,
            defaults: defaults,
            installedVersion: { "0.1.3" },
            downloadsDirectory: { downloads }
        )
    }

    private func releaseJSON(tag: String, withChecksum: Bool) -> Data {
        let checksumAsset =
            withChecksum
            ? """
            ,
                {
                  "name": "Unhog-0.1.4.dmg.sha256",
                  "browser_download_url": "https://example.com/Unhog-0.1.4.dmg.sha256"
                }
            """
            : ""
        return Data(
            """
            {
              "tag_name": "\(tag)",
              "name": "Unhog \(tag.dropFirst())",
              "body": "Release notes.",
              "html_url": "https://github.com/flazouh/unhog/releases/tag/\(tag)",
              "assets": [
                {
                  "name": "Unhog-0.1.4.dmg",
                  "browser_download_url": "https://example.com/Unhog-0.1.4.dmg"
                }\(checksumAsset)
              ]
            }
            """.utf8
        )
    }

    private func scratchDefaults() throws -> UserDefaults {
        let name = "UnhogUpdateTests-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(
                path: "unhog-update-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}

/// A URLProtocol-backed stand-in for GitHub, so no test reaches the network.
private final class StubNetwork {
    let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    func route(_ url: URL, status: Int, body: Data) {
        StubURLProtocol.store.set(url, status: status, body: body)
    }

    func requestCount(for url: URL) -> Int {
        StubURLProtocol.store.count(for: url)
    }

    func reset() {
        StubURLProtocol.store.reset()
    }
}

private final class StubStore: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [URL: (status: Int, body: Data)] = [:]
    private var counts: [URL: Int] = [:]

    func set(_ url: URL, status: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        routes[url] = (status, body)
    }

    func take(_ url: URL) -> (status: Int, body: Data)? {
        lock.lock()
        defer { lock.unlock() }
        counts[url, default: 0] += 1
        return routes[url]
    }

    func count(for url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[url] ?? 0
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        routes = [:]
        counts = [:]
    }
}

private final class StubURLProtocol: URLProtocol {
    static let store = StubStore()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let route = Self.store.take(url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: route.status,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
