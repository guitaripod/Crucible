import Foundation
#if canImport(Network)
import Network
#else
import Glibc
#endif

/// Reports what identifies the network in use (its status, interfaces and gateways) when watching starts and whenever it
/// changes: Network.framework's path monitor on Apple platforms, rtnetlink link, address and route events on Linux.
package final class NetworkPathWatcher: @unchecked Sendable {
    private let onChange: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "com.guitaripod.crucible.routes", qos: .utility)
    #if canImport(Network)
    private var monitor: NWPathMonitor?
    #else
    private var source: DispatchSourceRead?
    #endif

    package init(onChange: @escaping @Sendable (String) -> Void) {
        self.onChange = onChange
    }

    package func start() {
        #if canImport(Network)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [onChange] path in onChange(Self.signature(of: path)) }
        monitor.start(queue: queue)
        self.monitor = monitor
        #else
        startNetlink()
        #endif
    }

    package func cancel() {
        #if canImport(Network)
        monitor?.cancel()
        monitor = nil
        #else
        source?.cancel()
        source = nil
        #endif
    }

    #if canImport(Network)
    private static func signature(of path: NWPath) -> String {
        let interfaces = path.availableInterfaces.map { "\($0.type)-\($0.name)" }.joined(separator: ",")
        let gateways = path.gateways.map { "\($0)" }.joined(separator: ",")
        return "\(path.status)|\(interfaces)|\(gateways)"
    }
    #else
    /// The kernel's `struct sockaddr_nl` (linux/netlink.h), which Glibc's module map leaves out.
    private struct NetlinkAddress {
        var family = sa_family_t(AF_NETLINK)
        var padding: UInt16 = 0
        var portID: UInt32 = 0
        var groups: UInt32 = 0
    }

    /// rtnetlink's multicast groups for links, IPv4 and IPv6 addresses and routes (linux/rtnetlink.h).
    private static let routeGroups: UInt32 = 0x1 | 0x10 | 0x100 | 0x40 | 0x400

    /// Subscribes to rtnetlink's link, address and route groups; every message makes the signature be read again.
    private func startNetlink() {
        let fd = socket(AF_NETLINK, Int32(SOCK_RAW.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { return }
        var address = NetlinkAddress(groups: Self.routeGroups)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<NetlinkAddress>.size)) }
        }
        guard bound == 0 else {
            close(fd)
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [onChange] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            while recv(fd, &buffer, buffer.count, Int32(MSG_DONTWAIT)) > 0 {}
            onChange(Self.currentSignature())
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        queue.async { [onChange] in onChange(Self.currentSignature()) }
    }

    /// Interfaces that are up with an address, and the default gateways from the kernel's routing table.
    private static func currentSignature() -> String {
        var interfaces = Set<String>()
        var head: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&head) == 0, let first = head {
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let entry = cursor {
                let flags = Int32(entry.pointee.ifa_flags)
                let family = entry.pointee.ifa_addr?.pointee.sa_family
                if flags & Int32(IFF_UP) != 0, flags & Int32(IFF_LOOPBACK) == 0,
                   family == sa_family_t(AF_INET) || family == sa_family_t(AF_INET6) {
                    interfaces.insert(String(cString: entry.pointee.ifa_name))
                }
                cursor = entry.pointee.ifa_next
            }
            freeifaddrs(first)
        }
        let routes = (try? String(contentsOfFile: "/proc/net/route", encoding: .utf8)) ?? ""
        let gateways = routes.split(separator: "\n").dropFirst().compactMap { line -> String? in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count > 2, fields[1] == "00000000" else { return nil }
            return "\(fields[0])-\(fields[2])"
        }
        let status = interfaces.isEmpty ? "unsatisfied" : "satisfied"
        return "\(status)|\(interfaces.sorted().joined(separator: ","))|\(gateways.sorted().joined(separator: ","))"
    }
    #endif
}
