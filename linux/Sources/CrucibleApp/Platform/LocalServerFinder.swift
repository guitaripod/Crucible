import CrucibleCore
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Asks the local network for Plex Media Servers over GDM (`PlexGDM`): the search goes to the multicast group and, for
/// networks that drop multicast, to the broadcast address, and every answer heard within a moment is a server.
enum LocalServerFinder {
    /// How long answers are listened for; a server on the same network answers within milliseconds.
    private static let listening: Double = 1.2

    static func install() {
        PlexGDM.install { await Task.detached(priority: .userInitiated) { search() }.value }
    }

    /// One search: send, then collect answers until the time is up, one per server.
    private static func search() -> [PlexGDM.Server] {
        let socket = Glibc.socket(AF_INET, Int32(SOCK_DGRAM.rawValue), Int32(IPPROTO_UDP))
        guard socket >= 0 else { return [] }
        defer { close(socket) }
        var on: Int32 = 1
        var hops: UInt8 = 2
        setsockopt(socket, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socket, Int32(IPPROTO_IP), IP_MULTICAST_TTL, &hops, socklen_t(MemoryLayout<UInt8>.size))
        for host in [PlexGDM.group, "255.255.255.255"] { send(PlexGDM.message, to: host, port: PlexGDM.port, on: socket) }
        var found: [String: PlexGDM.Server] = [:]
        let deadline = Date().addingTimeInterval(listening)
        while case let remaining = deadline.timeIntervalSinceNow, remaining > 0 {
            var poller = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, Int32(remaining * 1000)) > 0, let (text, host) = receive(on: socket) else { continue }
            if let server = PlexGDM.parse(text, host: host), found[server.id] == nil { found[server.id] = server }
        }
        return found.values.sorted { $0.name < $1.name }
    }

    private static func send(_ text: String, to host: String, port: UInt16, on socket: Int32) {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return }
        let bytes = Array(text.utf8)
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                sendto(socket, bytes, bytes.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// One answer and the address it came from.
    private static func receive(on socket: Int32) -> (String, String)? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var sender = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &sender) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socket, &buffer, buffer.count, 0, $0, &length) }
        }
        guard count > 0 else { return nil }
        var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &sender.sin_addr, &host, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return (String(decoding: buffer.prefix(count), as: UTF8.self), String(cString: host))
    }
}
