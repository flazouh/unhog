import Testing

@testable import Unhog

@Suite("Update banner")
@MainActor
struct UpdateBannerPresentationTests {
    @Test("States with nothing to act on show no banner")
    func quietStates() {
        // A daily background check that finds nothing must leave the popover
        // exactly as the user left it.
        #expect(UpdateBannerPresentation.make(for: .idle) == nil)
        #expect(UpdateBannerPresentation.make(for: .checking) == nil)
        #expect(UpdateBannerPresentation.make(for: .upToDate) == nil)
        #expect(UpdateBannerPresentation.make(for: .unavailable) == nil)
    }

    @Test("An available update names the version and offers the notes")
    func availableUpdate() throws {
        let banner = try #require(
            UpdateBannerPresentation.make(for: .available(version: "0.1.7"))
        )

        #expect(banner.title.contains("0.1.7"))
        #expect(banner.primary?.label == "Update")
        #expect(banner.primary?.kind == .install)
        #expect(banner.showsReleaseNotes)
        #expect(banner.progress == nil)
        #expect(!banner.isWarning)
    }

    @Test("A download with a known size shows how far along it is")
    func measuredDownload() throws {
        let banner = try #require(
            UpdateBannerPresentation.make(for: .downloading(fraction: 0.25))
        )

        #expect(banner.progress == .fraction(0.25))
        // Nothing to press while bytes are arriving.
        #expect(banner.primary == nil)
    }

    @Test("A download of unknown size spins rather than guessing")
    func unmeasuredDownload() throws {
        let banner = try #require(
            UpdateBannerPresentation.make(for: .downloading(fraction: nil))
        )

        #expect(banner.progress == .indeterminate)
    }

    @Test("Installing says the restart is coming")
    func installing() throws {
        let banner = try #require(UpdateBannerPresentation.make(for: .installing))

        #expect(banner.progress == .indeterminate)
        #expect(banner.primary == nil)
        #expect(banner.detail?.contains("restart") == true)
    }

    @Test("A staged update offers the restart that finishes it")
    func readyToRelaunch() throws {
        let banner = try #require(
            UpdateBannerPresentation.make(for: .readyToRelaunch)
        )

        #expect(banner.primary?.label == "Restart")
        // The same reply channel as "Update": Sparkle is waiting on one answer.
        #expect(banner.primary?.kind == .install)
        #expect(banner.progress == nil)
    }

    @Test("A failure is surfaced with its reason and a retry")
    func failure() throws {
        let banner = try #require(
            UpdateBannerPresentation.make(for: .failed("The signature did not match."))
        )

        #expect(banner.isWarning)
        #expect(banner.detail == "The signature did not match.")
        #expect(banner.primary?.kind == .retry)
    }
}
