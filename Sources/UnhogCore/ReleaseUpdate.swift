import Foundation

public struct ReleaseUpdate: Sendable, Equatable {
    public let version: AppVersion
    public let title: String
    public let releaseNotes: String
    public let pageURL: URL
    public let downloadURL: URL
    public let checksumURL: URL?

    public init(
        version: AppVersion,
        title: String,
        releaseNotes: String,
        pageURL: URL,
        downloadURL: URL,
        checksumURL: URL? = nil
    ) {
        self.version = version
        self.title = title
        self.releaseNotes = releaseNotes
        self.pageURL = pageURL
        self.downloadURL = downloadURL
        self.checksumURL = checksumURL
    }
}

public enum ReleaseChecksum {
    /// `shasum -a 256` writes "<digest>  <file name>", so the digest is the first
    /// field. Anything that is not a 64-character hex string is refused rather
    /// than compared, so a truncated or error-page body cannot pass as a match.
    public static func parseSHA256(_ text: String) -> String? {
        guard let field = text.split(whereSeparator: \.isWhitespace).first,
            field.count == 64,
            field.allSatisfy(\.isHexDigit)
        else {
            return nil
        }
        return field.lowercased()
    }
}

public enum ReleaseUpdateComparison: Sendable, Equatable {
    case upToDate
    case updateAvailable(ReleaseUpdate)
}

public struct GitHubReleasePayload: Sendable, Equatable {
    public let tagName: String
    public let title: String
    public let body: String
    public let pageURL: URL
    public let assets: [GitHubReleaseAsset]

    public init(
        tagName: String,
        title: String,
        body: String,
        pageURL: URL,
        assets: [GitHubReleaseAsset]
    ) {
        self.tagName = tagName
        self.title = title
        self.body = body
        self.pageURL = pageURL
        self.assets = assets
    }
}

public struct GitHubReleaseAsset: Sendable, Equatable {
    public let name: String
    public let downloadURL: URL

    public init(name: String, downloadURL: URL) {
        self.name = name
        self.downloadURL = downloadURL
    }
}

public enum GitHubReleaseParser {
    public static func parse(_ data: Data) throws -> GitHubReleasePayload {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw ReleaseUpdateError.invalidResponse
        }

        guard let tagName = dictionary["tag_name"] as? String,
            let title = dictionary["name"] as? String,
            let body = dictionary["body"] as? String,
            let pageURLString = dictionary["html_url"] as? String,
            let pageURL = URL(string: pageURLString)
        else {
            throw ReleaseUpdateError.invalidResponse
        }

        let rawAssets = dictionary["assets"] as? [[String: Any]] ?? []
        let assets = rawAssets.compactMap { asset -> GitHubReleaseAsset? in
            guard let name = asset["name"] as? String,
                let downloadURLString = asset["browser_download_url"] as? String,
                let downloadURL = URL(string: downloadURLString)
            else {
                return nil
            }
            return GitHubReleaseAsset(name: name, downloadURL: downloadURL)
        }

        return GitHubReleasePayload(
            tagName: tagName,
            title: title,
            body: body,
            pageURL: pageURL,
            assets: assets
        )
    }
}

public enum ReleaseUpdateError: Error, Equatable, Sendable, LocalizedError {
    case invalidResponse
    case missingDownloadAsset
    case invalidVersion
    case checksumMismatch
    case downloadsDirectoryUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Could not read the latest release information."
        case .missingDownloadAsset:
            "The latest release does not include a downloadable installer."
        case .invalidVersion:
            "Could not determine the installed app version."
        case .checksumMismatch:
            "The downloaded update did not match the checksum published with "
                + "the release, so it was discarded."
        case .downloadsDirectoryUnavailable:
            "Could not find the Downloads folder to save the update into."
        }
    }
}

public struct ReleaseUpdateChecker: Sendable {
    public init() {}

    public func compare(
        currentVersion: AppVersion,
        release: GitHubReleasePayload
    ) throws -> ReleaseUpdateComparison {
        guard let version = AppVersion(parsing: release.tagName) else {
            throw ReleaseUpdateError.invalidVersion
        }

        guard let installer = preferredInstaller(in: release.assets) else {
            throw ReleaseUpdateError.missingDownloadAsset
        }

        if version <= currentVersion {
            return .upToDate
        }

        return .updateAvailable(
            ReleaseUpdate(
                version: version,
                title: release.title,
                releaseNotes: release.body,
                pageURL: release.pageURL,
                downloadURL: installer.downloadURL,
                checksumURL: checksumURL(for: installer, in: release.assets)
            )
        )
    }

    private func preferredInstaller(
        in assets: [GitHubReleaseAsset]
    ) -> GitHubReleaseAsset? {
        assets.first { $0.name.hasSuffix(".dmg") } ?? assets.first
    }

    /// The release pipeline publishes "<installer>.sha256" beside the disk image.
    /// Releases made before that existed simply have no checksum to check.
    private func checksumURL(
        for installer: GitHubReleaseAsset,
        in assets: [GitHubReleaseAsset]
    ) -> URL? {
        assets.first { $0.name == installer.name + ".sha256" }?.downloadURL
    }
}
