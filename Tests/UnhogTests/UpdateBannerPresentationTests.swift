import Foundation
import Testing
import UnhogCore

@testable import Unhog

@Suite("Update banner")
@MainActor
struct UpdateBannerPresentationTests {
    private let update = ReleaseUpdate(
        version: AppVersion(major: 0, minor: 1, patch: 5),
        title: "Unhog 0.1.5",
        releaseNotes: "Reports whole-machine memory pressure.",
        pageURL: URL(string: "https://example.com/release")!,
        downloadURL: URL(string: "https://example.com/Unhog-0.1.5.dmg")!
    )

    @Test("States with nothing to offer show no banner")
    func quietStates() {
        #expect(UpdateBannerPresentation.make(for: .idle) == nil)
        #expect(UpdateBannerPresentation.make(for: .checking) == nil)
        #expect(UpdateBannerPresentation.make(for: .upToDate) == nil)
    }

    @Test("An available update names the version and offers the notes")
    func availableUpdate() throws {
        let banner = try #require(
            UpdateBannerPresentation.make(for: .updateAvailable(update))
        )

        #expect(banner.title.contains("0.1.5"))
        #expect(banner.primary == .init(label: "Update", kind: .download))
        #expect(banner.showsReleaseNotes)
        #expect(!banner.showsProgress)
        #expect(!banner.isWarning)
    }

    @Test("A download in progress replaces the button with progress")
    func downloading() throws {
        let banner = try #require(
            UpdateBannerPresentation.make(for: .downloading)
        )

        #expect(banner.showsProgress)
        // Nothing to press: pressing again would start a second download.
        #expect(banner.primary == nil)
    }

    @Test("A verified download offers to open the installer")
    func readyToInstall() throws {
        let banner = try #require(
            UpdateBannerPresentation.make(
                for: .readyToInstall(
                    URL(fileURLWithPath: "/tmp/Unhog-0.1.5.dmg")
                )
            )
        )

        #expect(banner.primary?.kind == .openInstaller)
        #expect(banner.primary?.label == "Open Installer")
        #expect(banner.detail?.contains("Unhog-0.1.5.dmg") == true)
        #expect(!banner.showsProgress)
    }

    @Test("A failed background check stays out of the way")
    func failedCheckIsQuiet() {
        // The daily check runs unprompted, so a network blip must not leave a
        // banner sitting in the popover until the next launch.
        #expect(UpdateBannerPresentation.make(for: .failed("offline")) == nil)
    }

    @Test("A failed download is surfaced with a retry")
    func failedDownloadIsShown() throws {
        let banner = try #require(
            UpdateBannerPresentation.make(
                for: .downloadFailed("The download did not match the checksum.")
            )
        )

        // This one followed a button press, and a checksum failure is worth
        // saying out loud.
        #expect(banner.isWarning)
        #expect(banner.primary == .init(label: "Try Again", kind: .download))
        #expect(banner.detail == "The download did not match the checksum.")
    }
}
