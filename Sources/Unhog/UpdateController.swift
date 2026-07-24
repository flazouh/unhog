import AppKit
import Combine
import CryptoKit
import Foundation
import UnhogCore

@MainActor
final class UpdateController: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(ReleaseUpdate)
        case failed(String)
        case downloading
        case readyToInstall(URL)
    }

    @Published private(set) var state: State = .idle

    private let repository: String
    private let session: URLSession
    private let checker: ReleaseUpdateChecker
    private let defaults: UserDefaults
    private let installedVersion: () -> String?
    private let downloadsDirectory: () -> URL?
    private let lastAutomaticCheckKey = "unhog.lastAutomaticUpdateCheck"

    /// The installed version is read through a closure because tests run inside
    /// the test bundle, where `Bundle.main` describes the test runner rather
    /// than the app and every check would fail on a missing version. The
    /// download folder is injectable for the same reason: tests must never
    /// write into, or delete from, the real Downloads folder.
    init(
        repository: String = "flazouh/unhog",
        session: URLSession = .shared,
        checker: ReleaseUpdateChecker = ReleaseUpdateChecker(),
        defaults: UserDefaults = .standard,
        installedVersion: @escaping () -> String? = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        },
        downloadsDirectory: @escaping () -> URL? = {
            FileManager.default.urls(
                for: .downloadsDirectory,
                in: .userDomainMask
            ).first
        }
    ) {
        self.repository = repository
        self.session = session
        self.checker = checker
        self.defaults = defaults
        self.installedVersion = installedVersion
        self.downloadsDirectory = downloadsDirectory
    }

    var currentVersionLabel: String {
        currentVersion?.displayString ?? "Unknown"
    }

    func checkForUpdates(
        showUpToDateAlert: Bool = true,
        showUpdateAlert: Bool = true
    ) async {
        state = .checking
        do {
            let comparison = try await fetchComparison()
            apply(
                comparison,
                showUpToDateAlert: showUpToDateAlert,
                showUpdateAlert: showUpdateAlert
            )
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func checkForUpdatesIfNeeded(
        automaticallyCheck: Bool,
        minimumInterval: TimeInterval = 86_400
    ) async {
        guard automaticallyCheck else { return }
        guard shouldPerformAutomaticCheck(minimumInterval: minimumInterval) else {
            return
        }

        await checkForUpdates(
            showUpToDateAlert: false,
            showUpdateAlert: true
        )

        // Only a check that actually reached GitHub spends the daily budget.
        // Recording it up front turned one offline moment into a full day of
        // silence, because the retry was gated behind the same timestamp.
        if case .failed = state { return }
        defaults.set(Date(), forKey: lastAutomaticCheckKey)
    }

    func downloadUpdate() async {
        guard case let .updateAvailable(update) = state else { return }
        state = .downloading

        do {
            let destination = try await downloadAsset(
                from: update.downloadURL,
                checksumURL: update.checksumURL,
                suggestedName: "Unhog-\(update.version.displayString).dmg"
            )
            state = .readyToInstall(destination)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func openDownloadedUpdate() {
        guard case let .readyToInstall(url) = state else { return }
        NSWorkspace.shared.open(url)
    }

    func openReleasePage() {
        guard case let .updateAvailable(update) = state else { return }
        NSWorkspace.shared.open(update.pageURL)
    }

    private var currentVersion: AppVersion? {
        guard let rawVersion = installedVersion() else { return nil }
        return AppVersion(parsing: rawVersion)
    }

    private func shouldPerformAutomaticCheck(
        minimumInterval: TimeInterval
    ) -> Bool {
        guard
            let lastCheck = defaults.object(
                forKey: lastAutomaticCheckKey
            ) as? Date
        else {
            return true
        }
        return Date().timeIntervalSince(lastCheck) >= minimumInterval
    }

    private func fetchComparison() async throws -> ReleaseUpdateComparison {
        guard let currentVersion else {
            throw ReleaseUpdateError.invalidVersion
        }

        var request = URLRequest(
            url: URL(
                string: "https://api.github.com/repos/\(repository)/releases/latest"
            )!
        )
        request.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "Unhog/\(currentVersion.displayString)",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            throw ReleaseUpdateError.invalidResponse
        }

        let release = try GitHubReleaseParser.parse(data)
        return try checker.compare(
            currentVersion: currentVersion,
            release: release
        )
    }

    private func apply(
        _ comparison: ReleaseUpdateComparison,
        showUpToDateAlert: Bool,
        showUpdateAlert: Bool
    ) {
        switch comparison {
        case .upToDate:
            state = .upToDate
            if showUpToDateAlert {
                presentAlert(
                    title: "You're up to date",
                    message: "Unhog \(currentVersionLabel) is the latest release."
                )
            }
        case let .updateAvailable(update):
            state = .updateAvailable(update)
            if showUpdateAlert {
                presentUpdateAlert(update)
            }
        }
    }

    private func downloadAsset(
        from url: URL,
        checksumURL: URL?,
        suggestedName: String
    ) async throws -> URL {
        let (temporaryURL, response) = try await session.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            throw ReleaseUpdateError.invalidResponse
        }

        if let checksumURL {
            try await verify(fileAt: temporaryURL, against: checksumURL)
        }

        guard let downloads = downloadsDirectory() else {
            throw ReleaseUpdateError.downloadsDirectoryUnavailable
        }
        let destination = downloads.appending(path: suggestedName)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func verify(fileAt url: URL, against checksumURL: URL) async throws {
        let (data, response) = try await session.data(from: checksumURL)
        guard let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            let text = String(data: data, encoding: .utf8),
            let expected = ReleaseChecksum.parseSHA256(text)
        else {
            throw ReleaseUpdateError.invalidResponse
        }

        guard try sha256Hex(ofFileAt: url) == expected else {
            throw ReleaseUpdateError.checksumMismatch
        }
    }

    private func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        // Read in chunks so a large disk image never sits in memory whole.
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func presentUpdateAlert(_ update: ReleaseUpdate) {
        let alert = NSAlert()
        alert.messageText = "Update available"
        alert.informativeText =
            "Unhog \(update.version.displayString) is ready to download."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Release notes")
        alert.addButton(withTitle: "Not now")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await downloadUpdate() }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(update.pageURL)
        default:
            break
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
