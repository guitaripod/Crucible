import Foundation
import Testing
@testable import CrucibleCore

@Suite("Linux software update")
struct LinuxUpdateTests {
    /// The shape GitHub's releases listing has, with the server's releases beside the Linux client's.
    private static func listing(_ releases: [(tag: String, draft: Bool, prerelease: Bool, assets: [String])]) -> Data {
        let entries = releases.map { release -> [String: Any] in
            [
                "tag_name": release.tag,
                "html_url": "https://github.com/guitaripod/Crucible/releases/tag/\(release.tag)",
                "body": "Notes for \(release.tag)",
                "draft": release.draft,
                "prerelease": release.prerelease,
                "published_at": "2026-11-20T10:00:00Z",
                "assets": release.assets.map { ["name": $0, "browser_download_url": "https://github.com/dl/\(release.tag)/\($0)", "size": 41_000_000] },
            ]
        }
        return try! JSONSerialization.data(withJSONObject: entries)
    }

    private static func assets(_ version: String) -> [String] {
        ["crucible-linux-\(version)-x86_64.tar.zst", "crucible-linux-\(version)-x86_64.tar.zst.sha256"]
    }

    @Test func versionsCompareByNumberNotByText() {
        #expect(LinuxVersion("0.10.0")! > LinuxVersion("0.9.12")!)
        #expect(LinuxVersion("linux-1.2.3") == LinuxVersion(major: 1, minor: 2, patch: 3))
        #expect(LinuxVersion("1.2") == nil)
        #expect(LinuxVersion("server-v0.6.4") == nil)
        #expect(LinuxVersion("1.2.x") == nil)
        #expect(LinuxVersion("0.13.0")?.description == "0.13.0")
    }

    @Test func theNewestLinuxReleaseIsFoundAmongTheServers() throws {
        let data = Self.listing([
            ("server-v0.6.4", false, false, ["crucible-server-linux-x86_64.tar.gz"]),
            ("linux-0.14.0", true, false, Self.assets("0.14.0")),
            ("linux-0.13.1", false, true, Self.assets("0.13.1")),
            ("linux-0.13.0", false, false, Self.assets("0.13.0")),
            ("linux-0.12.9", false, false, Self.assets("0.12.9")),
            ("linux-0.13.5", false, false, ["crucible-linux-0.13.5-aarch64.tar.zst", "crucible-linux-0.13.5-aarch64.tar.zst.sha256"]),
        ])
        let release = try #require(LinuxRelease.newest(in: data, architecture: "x86_64"))
        #expect(release.version == LinuxVersion("0.13.0"))
        #expect(release.tarballName == "crucible-linux-0.13.0-x86_64.tar.zst")
        #expect(release.tarball.absoluteString == "https://github.com/dl/linux-0.13.0/crucible-linux-0.13.0-x86_64.tar.zst")
        #expect(release.checksum.lastPathComponent == "crucible-linux-0.13.0-x86_64.tar.zst.sha256")
        #expect(release.notes == "Notes for linux-0.13.0")
        #expect(release.publishedAt != nil)
        #expect(LinuxRelease.newest(in: data, architecture: "aarch64")?.version == LinuxVersion("0.13.5"))
        #expect(LinuxRelease.newest(in: Data("{\"message\":\"API rate limit exceeded\"}".utf8), architecture: "x86_64") == nil)
    }

    @Test func aChecksumFileNamesItsTarball() {
        let digest = String(repeating: "ab", count: 32)
        let other = String(repeating: "cd", count: 32)
        #expect(LinuxReleaseChecksum.digest(in: "\(digest)  crucible-linux-0.13.0-x86_64.tar.zst\n", for: "crucible-linux-0.13.0-x86_64.tar.zst") == digest)
        #expect(LinuxReleaseChecksum.digest(in: "\(other)  other.tar.zst\n\(digest) *dist/crucible.tar.zst", for: "crucible.tar.zst") == digest)
        #expect(LinuxReleaseChecksum.digest(in: digest.uppercased(), for: "anything") == digest)
        #expect(LinuxReleaseChecksum.digest(in: "\(other)  other.tar.zst", for: "crucible.tar.zst") == nil)
        #expect(LinuxReleaseChecksum.digest(in: "not a digest  crucible.tar.zst", for: "crucible.tar.zst") == nil)
    }

    @Test func aDownloadMatchesOnlyItsOwnChecksum() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("crucible-update-\(UUID().uuidString).tar.zst")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("Halcyon".utf8).write(to: file)
        let digest = "3d7c1a63e8b0d2a6a1fd8e6e7f9c79f8fd3b02df13d4e4d0c9a39bd4a5a6c3e8"
        let actual = try LinuxReleaseChecksum.sha256(of: file)
        #expect(actual.count == 64)
        #expect(try LinuxReleaseChecksum.matches(file, checksumText: "\(actual)  \(file.lastPathComponent)", name: file.lastPathComponent))
        #expect(try !LinuxReleaseChecksum.matches(file, checksumText: "\(digest)  \(file.lastPathComponent)", name: file.lastPathComponent))
    }

    @Test func anInstallIsReadFromWhereItRunsAndAStampThatStillDescribesIt() {
        let binary = "/home/maren/.local/lib/crucible/crucible"
        let tarball = LinuxInstallStamp(kind: .tarball, version: "0.13.0", binary: binary, size: 1200, prefix: "/home/maren/.local")
        let source = LinuxInstallStamp(kind: .source, version: "0.13.0", binary: binary, size: 1200, prefix: "/home/maren/.local",
                                       source: "/home/maren/src/Crucible", commit: "abc123")
        let exists: (String) -> Bool = { $0 == "/home/maren/src/Crucible" }
        #expect(LinuxInstallKind.classify(executable: "/home/maren/src/Crucible/.build/release/crucible", size: 1200, stamp: tarball,
                                          checkoutExists: exists) == .developer)
        #expect(LinuxInstallKind.classify(executable: "/usr/lib/crucible/crucible", size: 1200, stamp: tarball, checkoutExists: exists) == .packaged)
        #expect(LinuxInstallKind.classify(executable: binary, size: 1200, stamp: tarball, checkoutExists: exists) == .tarball(prefix: "/home/maren/.local"))
        #expect(LinuxInstallKind.classify(executable: binary, size: 1201, stamp: tarball, checkoutExists: exists) == .standalone)
        #expect(LinuxInstallKind.classify(executable: binary, size: 1200, stamp: source, checkoutExists: exists) == .source(checkout: "/home/maren/src/Crucible"))
        #expect(LinuxInstallKind.classify(executable: binary, size: 1200, stamp: source, checkoutExists: { _ in false }) == .standalone)
        #expect(LinuxInstallKind.classify(executable: binary, size: 1200, stamp: nil, checkoutExists: exists) == .standalone)
        let deck = LinuxInstallStamp(kind: .steamdeck, version: "0.17.0", binary: binary, size: 1200, prefix: "/home/maren/.local", commit: "abc123")
        #expect(LinuxInstallKind.classify(executable: binary, size: 1200, stamp: deck, checkoutExists: exists) == .developer)
    }

    @Test func eachInstallIsOfferedWhatCanUpdateIt() throws {
        let data = Self.listing([("linux-0.13.0", false, false, Self.assets("0.13.0"))])
        let release = try #require(LinuxRelease.newest(in: data, architecture: "x86_64"))
        let current = LinuxVersion("0.12.0")!
        let prefix = LinuxInstallKind.tarball(prefix: "/home/maren/.local")
        #expect(LinuxUpdateOffer.make(kind: prefix, current: current, newest: release, package: nil, helper: nil) == .install(release))
        #expect(LinuxUpdateOffer.make(kind: prefix, current: LinuxVersion("0.13.0")!, newest: release, package: nil, helper: nil) == .upToDate)
        #expect(LinuxUpdateOffer.make(kind: prefix, current: current, newest: nil, package: nil, helper: nil) == .upToDate)
        #expect(LinuxUpdateOffer.make(kind: .packaged, current: current, newest: release, package: "crucible-plex", helper: "paru")
            == .command("paru -S crucible-plex", release))
        #expect(LinuxUpdateOffer.make(kind: .packaged, current: current, newest: release, package: "crucible-plex-git", helper: nil)
            == .command("git clone https://aur.archlinux.org/crucible-plex-git.git && cd crucible-plex-git && makepkg -si", release))
        #expect(LinuxUpdateOffer.make(kind: .source(checkout: "/home/maren/src/My Crucible"), current: LinuxVersion("0.13.0")!, newest: release,
                                      package: nil, helper: nil) == .command("cd '/home/maren/src/My Crucible' && git pull && linux/scripts/install.sh", nil))
        #expect(LinuxUpdateOffer.make(kind: .standalone, current: current, newest: release, package: nil, helper: nil) == .download(release))
        #expect(LinuxUpdateOffer.make(kind: .developer, current: current, newest: release, package: nil, helper: nil) == .developerBuild)
    }

    @Test func aStampRoundTripsAsTheInstallersWriteIt() throws {
        let json = """
        {"kind":"tarball","version":"0.13.0","binary":"/home/maren/.local/lib/crucible/crucible","size":153000000,
         "prefix":"/home/maren/.local","installedAt":"2026-11-20T10:00:00Z"}
        """
        let stamp = try #require(LinuxInstallStamp.decode(Data(json.utf8)))
        #expect(stamp.kind == .tarball && stamp.size == 153_000_000 && stamp.source == nil)
        #expect(LinuxInstallStamp.decode(Data("{\"kind\":\"zip\"}".utf8)) == nil)
        let deck = """
        {"kind":"steamdeck","version":"0.17.0","binary":"/home/deck/.local/lib/crucible/crucible","size":160321968,
         "prefix":"/home/deck/.local","commit":"abc123","installedAt":"2026-11-16T17:21:38Z"}
        """
        #expect(LinuxInstallStamp.decode(Data(deck.utf8))?.kind == .steamdeck)
    }
}
