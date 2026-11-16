#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A Linux client's version, `X.Y.Z`, compared part by part; a release tag's `linux-` prefix is read past.
package struct LinuxVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    package let major: Int
    package let minor: Int
    package let patch: Int

    package init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    package init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(LinuxRelease.tagPrefix) { trimmed.removeFirst(LinuxRelease.tagPrefix.count) }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part in part.allSatisfy(\.isASCII) ? Int(part) : nil }
        guard numbers.count == 3, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    package var description: String { "\(major).\(minor).\(patch)" }

    package static func < (lhs: LinuxVersion, rhs: LinuxVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// One Linux release on GitHub, tagged `linux-X.Y.Z` beside the server's own releases: its page and notes, and the
/// tarball for one architecture with the checksum published next to it.
package struct LinuxRelease: Equatable, Sendable {
    package let version: LinuxVersion
    package let tag: String
    package let page: URL
    package let notes: String
    package let publishedAt: Date?
    package let tarball: URL
    package let tarballName: String
    package let tarballSize: Int?
    package let checksum: URL

    package static let tagPrefix = "linux-"
    package static let repository = "guitaripod/Crucible"

    /// Every release of the repository, newest first; the server's releases share it, so a page holds a hundred.
    package static var listURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100")!
    }

    /// The releases page, for an install that cannot replace itself.
    package static var releasesPage: URL {
        URL(string: "https://github.com/\(repository)/releases")!
    }

    /// The tarball's file name: `crucible-linux-0.13.0-x86_64.tar.zst`.
    package static func tarballName(version: LinuxVersion, architecture: String) -> String {
        "crucible-linux-\(version)-\(architecture).tar.zst"
    }

    private struct Listed: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int?
        }

        let tag_name: String
        let html_url: URL
        let body: String?
        let draft: Bool?
        let prerelease: Bool?
        let published_at: String?
        let assets: [Asset]?
    }

    /// The newest published Linux release in a GitHub releases listing that carries `architecture`'s tarball and its
    /// `.sha256`; drafts, prereleases and every other component's releases are passed over.
    package static func newest(in data: Data, architecture: String) -> LinuxRelease? {
        guard let listed = try? JSONDecoder().decode([Listed].self, from: data) else { return nil }
        let dates = ISO8601DateFormatter()
        return listed.compactMap { entry -> LinuxRelease? in
            guard entry.tag_name.hasPrefix(tagPrefix), entry.draft != true, entry.prerelease != true,
                  let version = LinuxVersion(entry.tag_name) else { return nil }
            let name = tarballName(version: version, architecture: architecture)
            let assets = entry.assets ?? []
            guard let tarball = assets.first(where: { $0.name == name }),
                  let checksum = assets.first(where: { $0.name == name + ".sha256" }) else { return nil }
            return LinuxRelease(version: version, tag: entry.tag_name, page: entry.html_url,
                                notes: (entry.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                publishedAt: entry.published_at.flatMap(dates.date(from:)), tarball: tarball.browser_download_url,
                                tarballName: name, tarballSize: tarball.size, checksum: checksum.browser_download_url)
        }.max { $0.version < $1.version }
    }
}

/// The SHA-256 a release publishes beside its tarball, in `sha256sum`'s format, and the check of a download against it.
package enum LinuxReleaseChecksum {
    /// The digest `text` gives for `name`: the line naming it, or the only digest in a file that names none.
    package static func digest(in text: String, for name: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var bare: [String] = []
        for line in lines {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
            guard let hash = fields.first?.lowercased(), isDigest(hash) else { continue }
            guard fields.count == 2 else {
                bare.append(hash)
                continue
            }
            let file = fields[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if file == name || (file as NSString).lastPathComponent == name { return hash }
        }
        return bare.count == 1 ? bare[0] : nil
    }

    /// The file's SHA-256 as lowercase hex, read a megabyte at a time.
    package static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `file` is the one `checksumText` describes under `name`.
    package static func matches(_ file: URL, checksumText: String, name: String) throws -> Bool {
        guard let expected = digest(in: checksumText, for: name) else { return false }
        return try sha256(of: file) == expected
    }

    private static func isDigest(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit }
    }
}
