import AppKit
import Combine
import Foundation
import OSLog
import Sparkle

/// Owns the updater and translates it into something the popover can show.
///
/// Unhog used to fetch the GitHub release list itself, download the disk image,
/// and then leave the user to mount it and drag the app over the copy that was
/// running. That last step is the one an app cannot do for itself by hand, which
/// is why it never got done and why the version never changed. Sparkle exists to
/// perform exactly that swap, with a signature check and a relaunch, so the
/// hand-rolled checker is gone rather than kept alongside it.
@MainActor
final class UpdateController: ObservableObject, SparkleUpdatePresenter {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        /// `nil` when the server did not say how large the download is.
        case downloading(fraction: Double?)
        case installing
        case readyToRelaunch
        case failed(String)
        /// Set when Sparkle could not start at all, which in practice means the
        /// app is running from a build directory rather than a signed bundle.
        case unavailable
    }

    @Published private(set) var state: State = .idle

    private let repository: String
    private let logger = Logger(subsystem: "com.unhog.app", category: "updates")
    private var updater: SPUUpdater?
    private var driver: SparkleUserDriver?

    /// Sparkle hands over a callback and waits for it, so the button in the
    /// banner has to be able to reach the reply that is currently outstanding.
    private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?
    private var pendingVersion: String?
    private var automaticChecks = true
    /// A background check that finds nothing must leave no trace, but a check the
    /// user asked for has to say something or the button looks broken.
    private var announcesResult = false
    private var launchCheckTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    init(repository: String = "flazouh/unhog") {
        self.repository = repository
    }

    var currentVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String
        guard let build else { return "Unhog \(short)" }
        return "Unhog \(short) (\(build))"
    }

    var canCheckForUpdates: Bool {
        guard let updater else { return false }
        return !updater.sessionInProgress
    }

    // MARK: - Lifecycle

    /// Called once from the composition root, after preferences are known.
    func start(automaticallyCheckForUpdates: Bool) {
        automaticChecks = automaticallyCheckForUpdates
        let driver = SparkleUserDriver(presenter: self)
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: nil
        )
        updater.automaticallyChecksForUpdates = automaticallyCheckForUpdates
        // Sparkle's own scheduler replaces the hourly task that used to live in
        // the app delegate, including the "not more than once a day" budget.
        updater.updateCheckInterval = 86_400

        do {
            try updater.start()
            self.driver = driver
            self.updater = updater
            scheduleLaunchCheck()
        } catch {
            // An unsigned build from .build/debug cannot verify anything, so
            // reporting that plainly beats an error the user cannot act on.
            logger.notice(
                "Updater unavailable: \(error.localizedDescription, privacy: .public)"
            )
            state = .unavailable
        }
    }

    func setAutomaticChecks(_ enabled: Bool) {
        automaticChecks = enabled
        updater?.automaticallyChecksForUpdates = enabled
    }

    /// Sparkle's scheduler waits out the whole interval before its first look, so
    /// an app installed today would not hear about anything until tomorrow. This
    /// asks once, quietly, shortly after launch: if there is nothing new the
    /// popover stays exactly as it was.
    private func scheduleLaunchCheck() {
        guard automaticChecks else { return }
        launchCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, let updater = self.updater else {
                return
            }
            guard !updater.sessionInProgress else { return }
            self.announcesResult = false
            updater.checkForUpdatesInBackground()
        }
    }

    // MARK: - Actions

    func checkForUpdates() {
        guard let updater else {
            state = .unavailable
            return
        }
        announcesResult = true
        dismissTask?.cancel()
        guard !updater.sessionInProgress else {
            updater.checkForUpdates()
            return
        }
        state = .checking
        updater.checkForUpdates()
    }

    /// Answers whatever question Sparkle is currently waiting on: install the
    /// update it found, or restart into the one it has already staged.
    func installUpdate() {
        guard let choice = pendingChoice else { return }
        pendingChoice = nil
        choice(.install)
    }

    func dismissUpdate() {
        guard let choice = pendingChoice else {
            state = .idle
            return
        }
        pendingChoice = nil
        choice(.dismiss)
    }

    func openReleasePage() {
        let url: URL
        if let pendingVersion,
            let tagged = URL(
                string:
                    "https://github.com/\(repository)/releases/tag/v\(pendingVersion)"
            )
        {
            url = tagged
        } else if let latest = URL(
            string: "https://github.com/\(repository)/releases/latest"
        ) {
            url = latest
        } else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - SparkleUpdatePresenter

    func updateCheckBegan() {
        state = .checking
    }

    func updateFound(
        version: String,
        choice: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        pendingChoice = choice
        pendingVersion = version
        state = .available(version: version)
    }

    func updateNotFound() {
        pendingChoice = nil
        pendingVersion = nil
        guard announcesResult else {
            state = .idle
            return
        }
        announcesResult = false
        state = .upToDate
        // Said once and then gone: a permanent "you are up to date" is clutter in
        // a popover the user opened to look at something else.
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.state == .upToDate else {
                return
            }
            self.state = .idle
        }
    }

    func updateFailed(_ message: String) {
        pendingChoice = nil
        state = .failed(message)
    }

    func downloadBegan() {
        state = .downloading(fraction: nil)
    }

    func downloadProgressed(fraction: Double?) {
        state = .downloading(fraction: fraction)
    }

    func installationBegan() {
        state = .installing
    }

    func readyToRelaunch(choice: @escaping (SPUUserUpdateChoice) -> Void) {
        pendingChoice = choice
        state = .readyToRelaunch
    }

    func installationFinished() {
        pendingChoice = nil
        state = .idle
    }

    func sessionEnded() {
        pendingChoice = nil
        // A dismissed session should leave no trace in the popover; anything
        // still on screen would describe an update nobody is working on.
        if case .failed = state { return }
        state = .idle
    }

    func automaticChecksAllowed() -> Bool {
        automaticChecks
    }

    // MARK: - Previews

    func applyPreviewState(_ state: State) {
        if case let .available(version) = state {
            pendingVersion = version
        }
        self.state = state
    }
}
