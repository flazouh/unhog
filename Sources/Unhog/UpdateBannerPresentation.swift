import Foundation

/// What, if anything, the popover should say about an update.
///
/// Kept apart from the view so the decision of when to stay silent is testable.
/// The important silence is a failed automatic check: that runs unprompted once
/// a day, so a network blip must not leave a warning sitting in the popover.
struct UpdateBannerPresentation: Equatable {
    /// The label and the effect travel together, because the same button reads
    /// "Update", "Open Installer" or "Try Again" depending on how far the
    /// update has got.
    struct PrimaryAction: Equatable {
        enum Kind: Equatable {
            case download
            case openInstaller
        }

        let label: String
        let kind: Kind
    }

    let title: String
    let detail: String?
    let primary: PrimaryAction?
    let showsProgress: Bool
    let showsReleaseNotes: Bool
    let isWarning: Bool

    @MainActor
    static func make(
        for state: UpdateController.State
    ) -> UpdateBannerPresentation? {
        switch state {
        case .idle, .checking, .upToDate:
            return nil

        case let .updateAvailable(update):
            return UpdateBannerPresentation(
                title: "Unhog \(update.version.displayString) is available",
                detail: nil,
                primary: PrimaryAction(label: "Update", kind: .download),
                showsProgress: false,
                showsReleaseNotes: true,
                isWarning: false
            )

        case .downloading:
            return UpdateBannerPresentation(
                title: "Downloading update…",
                detail: "Verifying the checksum published with the release.",
                primary: nil,
                showsProgress: true,
                showsReleaseNotes: false,
                isWarning: false
            )

        case let .readyToInstall(url):
            return UpdateBannerPresentation(
                title: "Update ready to install",
                detail: "Saved to \(url.lastPathComponent).",
                primary: PrimaryAction(
                    label: "Open Installer",
                    kind: .openInstaller
                ),
                showsProgress: false,
                showsReleaseNotes: false,
                isWarning: false
            )

        case .failed:
            // A check nobody asked for: reported in Settings, silent here.
            return nil

        case let .downloadFailed(message):
            return UpdateBannerPresentation(
                title: "Update could not be installed",
                detail: message,
                primary: PrimaryAction(label: "Try Again", kind: .download),
                showsProgress: false,
                showsReleaseNotes: false,
                isWarning: true
            )
        }
    }
}
