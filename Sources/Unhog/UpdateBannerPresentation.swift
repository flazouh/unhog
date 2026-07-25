import Foundation

struct UpdateBannerPresentation: Equatable {
    struct PrimaryAction: Equatable {
        enum Kind: Equatable {
            /// Answers whichever question the updater is waiting on: begin the
            /// install, or restart into an update already staged on disk.
            case install
            case retry
        }

        let label: String
        let kind: Kind
    }

    /// Work in flight, and whether its end is known.
    enum Progress: Equatable {
        /// The server did not say how large the download is, so a bar would be
        /// inventing a position it cannot know.
        case indeterminate
        case fraction(Double)
    }

    let title: String
    let detail: String?
    let primary: PrimaryAction?
    let progress: Progress?
    let showsReleaseNotes: Bool
    let isWarning: Bool

    @MainActor
    static func make(
        for state: UpdateController.State
    ) -> UpdateBannerPresentation? {
        switch state {
        case .idle, .checking, .upToDate, .unavailable:
            // Nothing to act on, and a menu bar app has no business reporting a
            // check that found the version the user already has.
            return nil

        case let .available(version):
            return UpdateBannerPresentation(
                title: "Unhog \(version) is available",
                detail: "Installs and restarts Unhog for you.",
                primary: PrimaryAction(label: "Update", kind: .install),
                progress: nil,
                showsReleaseNotes: true,
                isWarning: false
            )

        case let .downloading(fraction):
            return UpdateBannerPresentation(
                title: "Downloading update…",
                detail: nil,
                primary: nil,
                progress: fraction.map(Progress.fraction) ?? .indeterminate,
                showsReleaseNotes: false,
                isWarning: false
            )

        case .installing:
            return UpdateBannerPresentation(
                title: "Installing update…",
                detail: "Unhog will restart when it is done.",
                primary: nil,
                progress: .indeterminate,
                showsReleaseNotes: false,
                isWarning: false
            )

        case .readyToRelaunch:
            return UpdateBannerPresentation(
                title: "Update ready",
                detail: "Restart Unhog to finish installing it.",
                primary: PrimaryAction(label: "Restart", kind: .install),
                progress: nil,
                showsReleaseNotes: false,
                isWarning: false
            )

        case let .failed(message):
            return UpdateBannerPresentation(
                title: "Update failed",
                detail: message,
                primary: PrimaryAction(label: "Try Again", kind: .retry),
                progress: nil,
                showsReleaseNotes: false,
                isWarning: true
            )
        }
    }
}
