import Foundation
import os

/// Holds the newest Crucible Guides bundle this device trusts: the seed built into the app, replaced by the
/// signed bundle downloaded weekly from Midgar's gateway. The download is the whole bundle, never a part, so
/// it says nothing about anyone's library, and it carries no identifier.
package actor GuideStore {
    package static let shared = GuideStore()

    package static let url = URL(string: "https://api.midgarcorp.cc/v1/crucible/guides")!
    package static let refreshInterval: TimeInterval = 7 * 86_400
    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "essentials")
    private static let etagKey = "essentials_guides_etag"
    private static let checkedKey = "essentials_guides_checked"

    private let directory: URL
    private let defaults: UserDefaults
    private let seed: @Sendable () -> Data?
    private var loaded: (bundle: GuideBundle, sequence: Int)?

    package init(
        directory: URL = AppPlatform.persistentDirectory.appendingPathComponent("Essentials", isDirectory: true),
        defaults: UserDefaults = .standard,
        seed: @escaping @Sendable () -> Data? = { GuideStore.bundledSeed() }
    ) {
        self.directory = directory
        self.defaults = defaults
        self.seed = seed
    }

    /// The bundle compiled into the app, so Essentials works offline on first launch and in App Review.
    package static func bundledSeed() -> Data? {
        guard let url = Bundle.module.url(forResource: "guides.envelope", withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    private var savedURL: URL { directory.appendingPathComponent("guides.envelope.json") }

    /// The current bundle: the newer of the saved download and the seed, with the demo library's own guide
    /// added while the demo runs.
    package func bundle() -> GuideBundle? {
        let base = trustedBundle()
        guard defaults.bool(forKey: DemoMode.activeKey) else { return base }
        return GuideBundle(format: 1, generated: base?.generated ?? "", licence: base?.licence ?? "", shows: (base?.shows ?? []) + [DemoGuide.paperLanterns])
    }

    private func trustedBundle() -> GuideBundle? {
        if let loaded { return loaded.bundle }
        let candidates = [try? Data(contentsOf: savedURL), seed()].compactMap { $0 }
        var best: (GuideBundle, Int)?
        for data in candidates {
            guard let envelope = try? JSONDecoder().decode(GuideEnvelope.self, from: data),
                  let bundle = try? envelope.open() else { continue }
            if best == nil || envelope.sequence > best!.1 { best = (bundle, envelope.sequence) }
        }
        if let best { loaded = (best.0, best.1) }
        return loaded?.bundle
    }

    /// Downloads a newer bundle when a week has passed since the last check (or always with `force`), and keeps
    /// it only when it is signed by a trusted key, unexpired and newer than the one in use.
    @discardableResult
    package func refresh(session: URLSession = .shared, force: Bool = false, now: Date = Date()) async -> Bool {
        _ = trustedBundle()
        guard !defaults.bool(forKey: DemoMode.activeKey) else { return false }
        let last = defaults.double(forKey: Self.checkedKey)
        guard force || now.timeIntervalSince1970 - last >= Self.refreshInterval else { return false }
        var request = URLRequest(url: Self.url, timeoutInterval: 20)
        request.setValue("crucible", forHTTPHeaderField: "X-App-ID")
        if let etag = defaults.string(forKey: Self.etagKey) { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
            Self.log.notice("Guides check failed to reach the server")
            return false
        }
        defaults.set(now.timeIntervalSince1970, forKey: Self.checkedKey)
        guard http.statusCode == 200 else { return false }
        do {
            let envelope = try JSONDecoder().decode(GuideEnvelope.self, from: data)
            let bundle = try envelope.open(now: now, after: loaded?.sequence ?? 0)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: savedURL, options: .atomic)
            loaded = (bundle, envelope.sequence)
            if let etag = http.value(forHTTPHeaderField: "ETag") { defaults.set(etag, forKey: Self.etagKey) }
            Self.log.notice("Guides updated to #\(envelope.sequence) with \(bundle.shows.count) shows")
            return true
        } catch {
            Self.log.notice("Guides download refused: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
