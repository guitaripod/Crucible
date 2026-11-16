import CrucibleCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MidgarCore

/// Software Update on Linux (docs/LINUX.md §12, the Tailscode Linux pattern): reads how this copy was installed, asks
/// GitHub for the newest Linux release at most once a day and whenever asked, and acts on what the install allows. A
/// tarball install downloads the release, checks it against its SHA-256, installs it with the release's own installer
/// and restarts into it; a package or a checkout gets the command that updates it; a build directory is left alone.
@MainActor
final class SoftwareUpdate {
    enum Phase: Equatable {
        case idle
        case checking
        case downloading
        case installing
        case installed(LinuxVersion)
        case failed(String)
    }

    static let shared = SoftwareUpdate()

    let install: LinuxInstallKind
    let current: LinuxVersion
    /// The running executable, which a tarball update replaces.
    let executable: String
    private(set) var phase = Phase.idle { didSet { notify() } }
    private(set) var newest: LinuxRelease? { didSet { notify() } }
    private(set) var lastChecked: Date?
    /// The pacman package that owns a packaged install and the AUR helper on the PATH, found off the main thread.
    private(set) var ownerPackage: String?
    private(set) var aurHelper: String?
    /// Quits the app the way Ctrl+Q does, for the restart into a new version.
    var onQuit: (() -> Void)?

    private var observers: [UUID: @MainActor () -> Void] = [:]
    private var task: Task<Void, Never>?

    private enum Key {
        static let automatic = "linux.update.automatic"
        static let lastChecked = "linux.update.lastChecked"
        static let newest = "linux.update.newest"
    }

    private static let interval: TimeInterval = 24 * 60 * 60
    private static let launchDelay: TimeInterval = 20

    private init() {
        executable = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath().path
        current = LinuxVersion(CrucibleLinux.version) ?? LinuxVersion(major: 0, minor: 0, patch: 0)
        let size = (try? FileManager.default.attributesOfItem(atPath: executable)[.size] as? NSNumber)?.intValue
        let stamp = (try? Data(contentsOf: Self.stampURL)).flatMap(LinuxInstallStamp.decode)
        install = LinuxInstallKind.classify(executable: executable, size: size, stamp: stamp) { checkout in
            FileManager.default.fileExists(atPath: checkout + "/.git")
        }
        let defaults = UserDefaults.standard
        let checked = defaults.double(forKey: Key.lastChecked)
        lastChecked = checked > 0 ? Date(timeIntervalSince1970: checked) : nil
        newest = defaults.data(forKey: Key.newest).flatMap { try? JSONDecoder().decode(LinuxRelease.self, from: $0) }
        if install == .packaged { findOwner() }
    }

    static var stampURL: URL { AppPlatform.logsDirectory.appendingPathComponent("install.json") }

    /// What the screen offers now.
    var offer: LinuxUpdateOffer {
        LinuxUpdateOffer.make(kind: install, current: current, newest: newest, package: ownerPackage, helper: aurHelper)
    }

    /// Whether a newer release than this one is known, for the About row.
    var hasUpdate: Bool {
        switch offer {
        case .install, .download: return true
        case .command(_, let release): return release != nil
        case .upToDate, .developerBuild: return false
        }
    }

    /// Whether this install looks for releases at all: a build directory and a checkout follow their own source.
    var checksReleases: Bool {
        switch install {
        case .tarball, .packaged, .standalone: return true
        case .source, .developer: return false
        }
    }

    var checksAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: Key.automatic) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.automatic)
            notify()
        }
    }

    func observe(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func stopObserving(_ id: UUID) {
        observers[id] = nil
    }

    private func notify() {
        for handler in observers.values { handler() }
    }

    // MARK: Checking

    /// Checks a while after launch when automatic checks are on and the last one is a day old.
    func checkIfDue() {
        guard checksReleases, checksAutomatically else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.interval { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchDelay) { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    /// Asks GitHub for the newest Linux release now.
    func check() {
        guard checksReleases, task == nil else { return }
        phase = .checking
        task = Task { [weak self] in
            let result = await Self.fetchNewest()
            guard let self else { return }
            self.task = nil
            switch result {
            case .success(let release):
                self.lastChecked = Date()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Key.lastChecked)
                if let release, let data = try? JSONEncoder().encode(release) {
                    UserDefaults.standard.set(data, forKey: Key.newest)
                } else {
                    UserDefaults.standard.removeObject(forKey: Key.newest)
                }
                self.newest = release
                self.phase = .idle
                MidgarLog.notice("Software Update: \(release.map { "newest Linux release \($0.version)" } ?? "no Linux release yet"), running \(self.current)",
                                 category: .lifecycle)
            case .failure(let error):
                MidgarLog.error("Software Update could not reach GitHub: \(error.localizedDescription)", category: .lifecycle)
                self.phase = .failed(String(localized: "Couldn’t Check for Updates"))
            }
        }
    }

    private nonisolated static func fetchNewest() async -> Result<LinuxRelease?, Error> {
        do {
            var request = URLRequest(url: listURL)
            request.timeoutInterval = 20
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Crucible-Linux", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await HTTPSession.current.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return .success(LinuxRelease.newest(in: data, architecture: architecture))
        } catch {
            return .failure(error)
        }
    }

    /// GitHub's releases listing, or `CRUCIBLE_RELEASES_URL` for a headless check against a local listing.
    private nonisolated static var listURL: URL {
        ProcessInfo.processInfo.environment["CRUCIBLE_RELEASES_URL"].flatMap(URL.init(string:)) ?? LinuxRelease.listURL
    }

    /// The machine's architecture as the tarball names it (`x86_64`, `aarch64`).
    nonisolated static var architecture: String {
        var name = utsname()
        uname(&name)
        return withUnsafeBytes(of: &name.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: Installing

    private enum UpdateError: LocalizedError {
        case download
        case checksum
        case installer(String)

        var errorDescription: String? {
            switch self {
            case .download: return String(localized: "Couldn’t Download")
            case .checksum: return String(localized: "The download didn't match its checksum, so nothing was installed.")
            case .installer(let line): return String(localized: "The installer stopped: \(line)")
            }
        }
    }

    /// Downloads the newest release into the cache, checks it, and installs it over this tarball install.
    func installUpdate() {
        guard case .install(let release) = offer, case .tarball(let prefix) = install, task == nil else { return }
        phase = .downloading
        let folder = AppPlatform.cachesDirectory.appendingPathComponent("update", isDirectory: true)
        task = Task { [weak self] in
            let result = await Self.download(release, into: folder) { await MainActor.run { SoftwareUpdate.shared.enterInstalling() } }
            let installed: Result<Void, Error>
            switch result {
            case .success(let installer): installed = await Self.run(installer.path, ["--prefix", prefix])
            case .failure(let error): installed = .failure(error)
            }
            try? FileManager.default.removeItem(at: folder)
            guard let self else { return }
            self.task = nil
            switch installed {
            case .success:
                MidgarLog.notice("Software Update installed \(release.version) under \(prefix)", category: .lifecycle)
                self.phase = .installed(release.version)
            case .failure(let error):
                MidgarLog.error("Software Update did not install \(release.version): \(error.localizedDescription)", category: .lifecycle)
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func enterInstalling() {
        phase = .installing
    }

    /// Fetches the checksum and the tarball, checks one against the other and unpacks the tarball; answers the release's
    /// installer.
    private nonisolated static func download(_ release: LinuxRelease, into folder: URL, verified: @Sendable () async -> Void) async -> Result<URL, Error> {
        do {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var checksumRequest = URLRequest(url: release.checksum)
            checksumRequest.timeoutInterval = 30
            let (checksumData, checksumResponse) = try await HTTPSession.current.data(for: checksumRequest)
            guard (checksumResponse as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }
            var request = URLRequest(url: release.tarball)
            request.timeoutInterval = 120
            let (temporary, response) = try await HTTPSession.current.download(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }
            let tarball = folder.appendingPathComponent(release.tarballName)
            try FileManager.default.moveItem(at: temporary, to: tarball)
            guard try LinuxReleaseChecksum.matches(tarball, checksumText: String(decoding: checksumData, as: UTF8.self), name: release.tarballName) else {
                throw UpdateError.checksum
            }
            await verified()
            let unpacked = folder.appendingPathComponent("unpacked", isDirectory: true)
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            if case .failure(let error) = await run("/usr/bin/env", ["tar", "--zstd", "-xf", tarball.path, "-C", unpacked.path]) { throw error }
            let installer = unpacked.appendingPathComponent(release.tarballName.replacingOccurrences(of: ".tar.zst", with: ""))
                .appendingPathComponent("install.sh")
            guard FileManager.default.isExecutableFile(atPath: installer.path) else { throw UpdateError.installer("install.sh") }
            return .success(installer)
        } catch {
            return .failure(error)
        }
    }

    /// Runs a program to its end off the main thread; a failure carries the last line it printed.
    private nonisolated static func run(_ path: String, _ arguments: [String]) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failure(error))
                    return
                }
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let last = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init)
                    continuation.resume(returning: .failure(UpdateError.installer(last ?? "exit \(process.terminationStatus)")))
                    return
                }
                continuation.resume(returning: .success(()))
            }
        }
    }

    // MARK: Restarting

    /// Starts the installed version once this process has ended, then quits: a shell in a session of its own waits for
    /// this process id to go and runs the new executable at the install's path.
    func restart() {
        guard case .installed = phase, case .tarball(let prefix) = install else { return }
        let binary = prefix + "/lib/crucible/crucible"
        let script = "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; exec \(LinuxUpdateOffer.shellQuoted(binary))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["setsid", "sh", "-c", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("CRUCIBLE_") { environment[key] = nil }
        process.environment = environment
        do {
            try process.run()
            onQuit?()
        } catch {
            MidgarLog.error("Software Update could not restart Crucible: \(error.localizedDescription)", category: .lifecycle)
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Packages

    /// Asks pacman which package owns the executable and looks for an AUR helper, off the main thread.
    private func findOwner() {
        let executable = executable
        DispatchQueue.global(qos: .utility).async {
            let package = Self.output("/usr/bin/env", ["pacman", "-Qqo", executable])
            let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin"
            let helper = ["paru", "yay", "pikaur", "trizen"].first { name in
                path.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.ownerPackage = package
                    self.aurHelper = helper
                    self.notify()
                }
            }
        }
    }

    private nonisolated static func output(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !text.isEmpty ? text : nil
    }
}
