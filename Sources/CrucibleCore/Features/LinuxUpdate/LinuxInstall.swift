import Foundation

/// What an installer left in `$XDG_STATE_HOME/crucible/install.json`: the tarball's `install.sh` or the checkout's
/// `linux/scripts/install.sh`, the executable it put in place and how big it was, so a stamp left by an earlier install or
/// describing a binary somebody replaced by hand is not believed.
package struct LinuxInstallStamp: Codable, Equatable, Sendable {
    package enum Kind: String, Codable, Sendable {
        case tarball, source
    }

    package var kind: Kind
    package var version: String
    /// The installed executable's absolute path.
    package var binary: String
    /// Its size in bytes when it was installed.
    package var size: Int
    /// The prefix it was installed under (`~/.local`).
    package var prefix: String
    /// The checkout a source install was built from, and its commit.
    package var source: String?
    package var commit: String?
    package var installedAt: String?

    package init(kind: Kind, version: String, binary: String, size: Int, prefix: String, source: String? = nil, commit: String? = nil,
                 installedAt: String? = nil) {
        self.kind = kind
        self.version = version
        self.binary = binary
        self.size = size
        self.prefix = prefix
        self.source = source
        self.commit = commit
        self.installedAt = installedAt
    }

    package static func decode(_ data: Data) -> LinuxInstallStamp? {
        try? JSONDecoder().decode(LinuxInstallStamp.self, from: data)
    }
}

/// How this copy of Crucible was installed, which decides what Software Update may do about a newer one: a tarball install
/// replaces itself, a package belongs to pacman, a checkout's install rebuilds from the checkout, and a build directory or
/// a binary with nothing behind it is left alone.
package enum LinuxInstallKind: Equatable, Sendable {
    case tarball(prefix: String)
    case packaged
    case source(checkout: String)
    case developer
    case standalone

    /// Reads the evidence in the order it deserves: a path in a build directory is a working copy whatever a stamp says,
    /// a path under `/usr` or `/opt` belongs to the package manager, and a stamp counts only when it names the running
    /// executable at the size it has now.
    package static func classify(executable: String, size: Int?, stamp: LinuxInstallStamp?, checkoutExists: (String) -> Bool) -> LinuxInstallKind {
        if executable.contains("/.build/") { return .developer }
        if executable.hasPrefix("/usr/") || executable.hasPrefix("/opt/") { return .packaged }
        guard let stamp, stamp.binary == executable, let size, stamp.size == size else { return .standalone }
        switch stamp.kind {
        case .tarball:
            return .tarball(prefix: stamp.prefix)
        case .source:
            guard let checkout = stamp.source, checkoutExists(checkout) else { return .standalone }
            return .source(checkout: checkout)
        }
    }
}

/// What Software Update offers for an install and the newest release: to install it, a command for whatever owns the
/// install, the download page, or nothing to do.
package enum LinuxUpdateOffer: Equatable, Sendable {
    case upToDate
    /// A tarball install: download, check and install `release` in place.
    case install(LinuxRelease)
    /// A package or a checkout: the command that updates it, with the release that prompted it when there is one.
    case command(String, LinuxRelease?)
    /// A binary with no installer behind it: the release's page.
    case download(LinuxRelease)
    /// A build directory, where an update would land on the build it is running.
    case developerBuild

    /// `package` is the pacman package that owns the executable (`crucible` or `crucible-git`) and `helper` the AUR
    /// helper on the PATH, either nil when unknown.
    package static func make(kind: LinuxInstallKind, current: LinuxVersion, newest: LinuxRelease?, package: String?, helper: String?) -> LinuxUpdateOffer {
        let newer = newest.flatMap { $0.version > current ? $0 : nil }
        switch kind {
        case .developer:
            return .developerBuild
        case .source(let checkout):
            return .command(sourceCommand(checkout: checkout), newer)
        case .packaged:
            guard let newer else { return .upToDate }
            return .command(packageCommand(package: package ?? "crucible", helper: helper), newer)
        case .tarball:
            return newer.map(LinuxUpdateOffer.install) ?? .upToDate
        case .standalone:
            return newer.map(LinuxUpdateOffer.download) ?? .upToDate
        }
    }

    /// Pulls the checkout and runs its installer, which rebuilds and replaces this install.
    package static func sourceCommand(checkout: String) -> String {
        "cd \(shellQuoted(checkout)) && git pull && linux/scripts/install.sh"
    }

    /// The AUR helper's install of the package, which builds the newest version, or makepkg's when no helper is found.
    package static func packageCommand(package: String, helper: String?) -> String {
        if let helper { return "\(helper) -S \(package)" }
        return "git clone https://aur.archlinux.org/\(package).git && cd \(package) && makepkg -si"
    }

    package static func shellQuoted(_ value: String) -> String {
        guard value.contains(where: { !($0.isLetter || $0.isNumber || "/._-+".contains($0)) }) else { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
