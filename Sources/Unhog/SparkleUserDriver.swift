import Foundation
import Sparkle

/// What the popover needs to know about an update in flight.
///
/// Sparkle's own window is a poor fit for a menu bar utility: it steals focus from
/// whatever the user was doing to announce news they did not ask for. Driving the
/// banner instead keeps the update where the rest of Unhog's reporting lives.
@MainActor
protocol SparkleUpdatePresenter: AnyObject {
    func updateCheckBegan()
    func updateFound(version: String, choice: @escaping (SPUUserUpdateChoice) -> Void)
    func updateNotFound()
    func updateFailed(_ message: String)
    func downloadBegan()
    func downloadProgressed(fraction: Double?)
    func installationBegan()
    func readyToRelaunch(choice: @escaping (SPUUserUpdateChoice) -> Void)
    func installationFinished()
    func sessionEnded()
    func automaticChecksAllowed() -> Bool
}

/// Bridges Sparkle's callback protocol to the banner.
///
/// Sparkle documents that every method here arrives on the main thread, which is
/// what makes `assumeIsolated` honest rather than a wish: the protocol itself
/// carries no isolation, so the alternative would be hopping queues and letting
/// the banner lag a step behind the download it describes.
final class SparkleUserDriver: NSObject, SPUUserDriver {
    private weak var presenter: (any SparkleUpdatePresenter)?

    /// Sparkle reports bytes, not a fraction, and only sometimes knows the total.
    private var expectedContentLength: UInt64 = 0
    private var receivedContentLength: UInt64 = 0

    init(presenter: any SparkleUpdatePresenter) {
        self.presenter = presenter
        super.init()
    }

    private func onMain(_ body: @MainActor @escaping (any SparkleUpdatePresenter) -> Void) {
        MainActor.assumeIsolated {
            guard let presenter else { return }
            body(presenter)
        }
    }

    // MARK: - Permission

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        // Unhog already asks this in its own settings, so Sparkle's first-launch
        // dialog would be a second prompt for a question already answered.
        MainActor.assumeIsolated {
            let allowed = presenter?.automaticChecksAllowed() ?? false
            reply(
                SUUpdatePermissionResponse(
                    automaticUpdateChecks: allowed,
                    sendSystemProfile: false
                )
            )
        }
    }

    // MARK: - Checking

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        onMain { $0.updateCheckBegan() }
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        // An informational-only item has nothing to install, so offering "Update"
        // would produce a button that cannot do what it says.
        guard !appcastItem.isInformationOnlyUpdate else {
            reply(.dismiss)
            return
        }

        let version =
            appcastItem.displayVersionString.isEmpty
            ? appcastItem.versionString
            : appcastItem.displayVersionString

        switch state.stage {
        case .downloaded, .installing:
            // Resuming an update that is already on disk: the only useful
            // question left is whether to restart now.
            onMain { $0.readyToRelaunch(choice: reply) }
        case .notDownloaded:
            onMain { $0.updateFound(version: version, choice: reply) }
        @unknown default:
            onMain { $0.updateFound(version: version, choice: reply) }
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // The banner links to the GitHub release rather than rendering HTML in a
        // popover that is 380 points wide.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        // Release notes are decoration here; failing to fetch them must not
        // interrupt an update that is otherwise fine.
    }

    func showUpdateNotFoundWithError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        onMain { $0.updateNotFound() }
        acknowledgement()
    }

    func showUpdaterError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        let message = error.localizedDescription
        onMain { $0.updateFailed(message) }
        acknowledgement()
    }

    // MARK: - Download and install

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedContentLength = 0
        receivedContentLength = 0
        onMain { $0.downloadBegan() }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        self.expectedContentLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedContentLength += length
        // A server that omits Content-Length leaves the fraction unknowable, and
        // an invented denominator would show a bar that lies about its position.
        guard expectedContentLength > 0 else {
            onMain { $0.downloadProgressed(fraction: nil) }
            return
        }
        let fraction = min(
            1,
            Double(receivedContentLength) / Double(expectedContentLength)
        )
        onMain { $0.downloadProgressed(fraction: fraction) }
    }

    func showDownloadDidStartExtractingUpdate() {
        onMain { $0.installationBegan() }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        onMain { $0.downloadProgressed(fraction: progress) }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        onMain { $0.readyToRelaunch(choice: reply) }
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        onMain { $0.installationBegan() }
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        onMain { $0.installationFinished() }
        acknowledgement()
    }

    func showUpdateInFocus() {
        // The banner is already visible whenever the popover is open; there is no
        // separate window to bring forward.
    }

    func dismissUpdateInstallation() {
        onMain { $0.sessionEnded() }
    }
}
