import Foundation

/// Finds a Plex server on the tailnet when plex.tv does not list a route to it. plex.tv only knows
/// the addresses a server reports about itself, and a computer's Tailscale address is not among
/// them, so without this a phone on the tailnet can fail to find a server it can plainly reach.
///
/// Two searches run side by side and every answer is verified: the machine identifier a candidate
/// returns must be the server's own, so nothing but that server is ever trusted.
/// - By name: the server's friendly name, turned into the MagicDNS names it likely has, resolved
///   to tailnet addresses. Needs nothing from the person.
/// - By device list: with a Tailscale API token, every computer that is online is asked directly.
///
/// ```swift
/// let found = await TailnetServerFinder.live.routes(for: servers.map(TailnetTarget.init(choice:)))
/// ```
package struct TailnetServerFinder: Sendable {
    package struct Environment: Sendable {
        package var localAddress: @Sendable () -> String?
        package var resolve: @Sendable (_ name: String) async -> [String]
        package var machineIdentifier: @Sendable (_ url: URL) async -> String?
        package var devices: @Sendable (_ token: String) async throws -> [TailscaleDevice]
        package var token: @Sendable () -> String?
        package var tokenRejected: @Sendable () -> Void

        package init(
            localAddress: @escaping @Sendable () -> String?,
            resolve: @escaping @Sendable (String) async -> [String],
            machineIdentifier: @escaping @Sendable (URL) async -> String?,
            devices: @escaping @Sendable (String) async throws -> [TailscaleDevice],
            token: @escaping @Sendable () -> String?,
            tokenRejected: @escaping @Sendable () -> Void
        ) {
            self.localAddress = localAddress
            self.resolve = resolve
            self.machineIdentifier = machineIdentifier
            self.devices = devices
            self.token = token
            self.tokenRejected = tokenRejected
        }

        package static let live = Environment(
            localAddress: { TailnetPresence.localAddress() },
            resolve: { name in await HostResolver.ipv4Addresses(of: name) },
            machineIdentifier: { url in await TailnetServerFinder.identity(of: url) },
            devices: { token in try await TailscaleAPI.devices(token: token) },
            token: { TailnetAccess.state == .saved ? TailnetAccess.token : nil },
            tokenRejected: { TailnetAccess.markRejected() }
        )
    }

    package static let live = TailnetServerFinder(environment: .live)

    private let environment: Environment
    private let maxConcurrentProbes = 12

    package init(environment: Environment) {
        self.environment = environment
    }

    /// Verified tailnet routes per machine identifier. Empty when this device is not on the tailnet.
    package func routes(for targets: [TailnetTarget]) async -> [String: [URL]] {
        guard !targets.isEmpty, environment.localAddress() != nil else { return [:] }
        let findings = Findings(wanted: Set(targets.map(\.id)))
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await searchByName(targets, findings) }
            group.addTask { await searchByDeviceList(targets, findings) }
            for await _ in group where findings.isComplete {
                group.cancelAll()
            }
        }
        let result = findings.routes
        AppLogger.notice("Tailnet search for \(targets.map(\.name).joined(separator: ", ")): \(result.values.joined().map(\.absoluteString))", .networking)
        return result
    }

    private func searchByName(_ targets: [TailnetTarget], _ findings: Findings) async {
        await withTaskGroup(of: Void.self) { group in
            for target in targets {
                for name in MagicDNSName.candidates(forServerNamed: target.name) {
                    group.addTask {
                        let addresses = await environment.resolve(name).filter(TailnetPresence.isTailnetAddress)
                        for address in addresses.prefix(1) where !Task.isCancelled {
                            await verify(address: address, targets: [target], findings)
                        }
                    }
                }
            }
        }
    }

    private func searchByDeviceList(_ targets: [TailnetTarget], _ findings: Findings) async {
        guard let token = environment.token() else { return }
        let devices: [TailscaleDevice]
        do {
            devices = try await environment.devices(token)
        } catch TailscaleAPIError.tokenRejected {
            AppLogger.error("Tailscale rejected the saved API token", .networking)
            environment.tokenRejected()
            return
        } catch {
            AppLogger.error("Tailscale device list unavailable: \(error)", .networking)
            return
        }
        let addresses = devices.filter { $0.isWorthProbing() }.compactMap(\.tailnetIPv4)
        AppLogger.info("Probing \(addresses.count) of \(devices.count) tailnet devices", .networking)
        var pending = addresses.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            func addNext() {
                guard !Task.isCancelled, !findings.isComplete, let address = pending.next() else { return }
                group.addTask { await verify(address: address, targets: targets, findings) }
            }
            for _ in 0..<maxConcurrentProbes { addNext() }
            for await _ in group { addNext() }
        }
    }

    /// Asks `address` on each port the targets listen on whether it is one of them: plain HTTP
    /// first (the tailnet already encrypts it), then the certificate-valid plex.direct name for
    /// servers that insist on HTTPS.
    private func verify(address: String, targets: [TailnetTarget], _ findings: Findings) async {
        var ports: [Int] = []
        for port in targets.flatMap(\.ports) where !ports.contains(port) { ports.append(port) }
        for port in ports where !Task.isCancelled {
            guard let plain = URL(string: "http://\(address):\(port)") else { continue }
            let secure = targets.compactMap { $0.plexDirectURL(address: address, port: port) }
            for url in [plain] + secure {
                guard let answer = await environment.machineIdentifier(url) else { continue }
                if targets.contains(where: { $0.id == answer }) {
                    findings.add(id: answer, url: url)
                    return
                }
                break
            }
        }
    }

    private static func identity(of url: URL) async -> String? {
        var request = URLRequest(url: url.appendingPathComponent("identity"))
        request.timeoutInterval = 2.5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return (try? JSONDecoder().decode(PlexIdentity.self, from: data))?.MediaContainer.machineIdentifier
    }
}

private final class Findings: @unchecked Sendable {
    private let lock = NSLock()
    private let wanted: Set<String>
    private var found: [String: [URL]] = [:]

    init(wanted: Set<String>) {
        self.wanted = wanted
    }

    var routes: [String: [URL]] {
        lock.withLock { found }
    }

    var isComplete: Bool {
        lock.withLock { wanted.allSatisfy { found[$0] != nil } }
    }

    func add(id: String, url: URL) {
        lock.withLock {
            guard wanted.contains(id), !(found[id]?.contains(url) ?? false) else { return }
            found[id, default: []].append(url)
        }
    }
}

/// Name resolution with a deadline: `getaddrinfo` cannot be cancelled, so a resolver that hangs
/// must not hold the search past `deadline`.
enum HostResolver {
    static func ipv4Addresses(of name: String, deadline: TimeInterval = 2) async -> [String] {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.global(qos: .userInitiated).async { once.resume(lookup(name)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline) { once.resume([]) }
        }
    }

    private static func lookup(_ name: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &head) == 0, let first = head else { return [] }
        defer { freeaddrinfo(head) }
        var addresses: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let address = pointer.pointee.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, pointer.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0,
                  let host = String(validatingCString: buffer), !addresses.contains(host)
            else { continue }
            addresses.append(host)
        }
        return addresses
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String], Never>?

    init(_ continuation: CheckedContinuation<[String], Never>) {
        self.continuation = continuation
    }

    func resume(_ value: [String]) {
        let taken = lock.withLock { () -> CheckedContinuation<[String], Never>? in
            defer { continuation = nil }
            return continuation
        }
        taken?.resume(returning: value)
    }
}
