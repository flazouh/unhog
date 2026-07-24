import Foundation
import Testing
@testable import UnhogCore

@Suite("Release updates")
struct ReleaseUpdateTests {
    @Test("App versions compare in semver order")
    func comparesVersions() {
        let current = AppVersion(major: 0, minor: 1, patch: 1)
        let newer = AppVersion(major: 0, minor: 1, patch: 2)
        let older = AppVersion(major: 0, minor: 1, patch: 0)

        #expect(current < newer)
        #expect(older < current)
        #expect(AppVersion(parsing: "v0.1.2") == newer)
    }

    @Test("GitHub release payloads parse into comparable updates")
    func parsesGitHubReleasePayload() throws {
        let data = Data(
            """
            {
              "tag_name": "v0.1.2",
              "name": "Unhog 0.1.2",
              "body": "Adds automatic updates.",
              "html_url": "https://github.com/flazouh/unhog/releases/tag/v0.1.2",
              "assets": [
                {
                  "name": "Unhog-0.1.2.dmg",
                  "browser_download_url": "https://example.com/Unhog-0.1.2.dmg"
                }
              ]
            }
            """.utf8
        )

        let release = try GitHubReleaseParser.parse(data)
        let comparison = try ReleaseUpdateChecker().compare(
            currentVersion: AppVersion(major: 0, minor: 1, patch: 1),
            release: release
        )

        guard case let .updateAvailable(update) = comparison else {
            Issue.record("Expected an available update.")
            return
        }

        #expect(update.version.displayString == "0.1.2")
        #expect(update.title == "Unhog 0.1.2")
        #expect(update.releaseNotes == "Adds automatic updates.")
        #expect(
            update.downloadURL.absoluteString
                == "https://example.com/Unhog-0.1.2.dmg"
        )
    }

    @Test("The published checksum travels with the installer")
    func exposesChecksumAsset() throws {
        let release = GitHubReleasePayload(
            tagName: "v0.1.4",
            title: "Unhog 0.1.4",
            body: "Verifies downloads.",
            pageURL: URL(string: "https://example.com/release")!,
            assets: [
                GitHubReleaseAsset(
                    name: "Unhog-0.1.4.dmg.sha256",
                    downloadURL: URL(string: "https://example.com/sum")!
                ),
                GitHubReleaseAsset(
                    name: "Unhog-0.1.4.dmg",
                    downloadURL: URL(string: "https://example.com/dmg")!
                ),
            ]
        )

        let comparison = try ReleaseUpdateChecker().compare(
            currentVersion: AppVersion(major: 0, minor: 1, patch: 3),
            release: release
        )

        guard case let .updateAvailable(update) = comparison else {
            Issue.record("Expected an available update.")
            return
        }

        // The ".sha256" asset must not be mistaken for the installer itself.
        #expect(update.downloadURL.absoluteString == "https://example.com/dmg")
        #expect(update.checksumURL?.absoluteString == "https://example.com/sum")
    }

    @Test("Releases without a checksum asset still offer the installer")
    func toleratesMissingChecksum() throws {
        let release = GitHubReleasePayload(
            tagName: "v0.1.4",
            title: "Unhog 0.1.4",
            body: "Older release layout.",
            pageURL: URL(string: "https://example.com/release")!,
            assets: [
                GitHubReleaseAsset(
                    name: "Unhog-0.1.4.dmg",
                    downloadURL: URL(string: "https://example.com/dmg")!
                )
            ]
        )

        let comparison = try ReleaseUpdateChecker().compare(
            currentVersion: AppVersion(major: 0, minor: 1, patch: 3),
            release: release
        )

        guard case let .updateAvailable(update) = comparison else {
            Issue.record("Expected an available update.")
            return
        }
        #expect(update.checksumURL == nil)
    }

    @Test("shasum output yields just the digest")
    func parsesChecksumFile() {
        let digest = String(repeating: "a1b2c3d4", count: 8)
        #expect(
            ReleaseChecksum.parseSHA256("\(digest)  Unhog-0.1.4.dmg\n") == digest
        )
        #expect(ReleaseChecksum.parseSHA256(digest) == digest)
        #expect(
            ReleaseChecksum.parseSHA256(digest.uppercased() + "  x.dmg")
                == digest
        )
    }

    @Test("Anything that is not a digest is refused")
    func rejectsMalformedChecksums() {
        // An error page or truncated body must not be treated as a digest.
        #expect(ReleaseChecksum.parseSHA256("") == nil)
        #expect(ReleaseChecksum.parseSHA256("<html>404</html>") == nil)
        #expect(ReleaseChecksum.parseSHA256("abc123  Unhog.dmg") == nil)
        #expect(
            ReleaseChecksum.parseSHA256(String(repeating: "z", count: 64)) == nil
        )
    }

    @Test("Matching versions report up to date")
    func reportsUpToDate() throws {
        let release = GitHubReleasePayload(
            tagName: "v0.1.2",
            title: "Unhog 0.1.2",
            body: "No changes",
            pageURL: URL(string: "https://example.com/release")!,
            assets: [
                GitHubReleaseAsset(
                    name: "Unhog-0.1.2.dmg",
                    downloadURL: URL(string: "https://example.com/Unhog-0.1.2.dmg")!
                )
            ]
        )

        let comparison = try ReleaseUpdateChecker().compare(
            currentVersion: AppVersion(major: 0, minor: 1, patch: 2),
            release: release
        )

        #expect(comparison == .upToDate)
    }
}
