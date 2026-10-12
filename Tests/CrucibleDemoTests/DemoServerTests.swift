@testable import CrucibleCore
import Darwin
import Foundation
import Testing
@testable import CrucibleDemo

struct DemoServerTests {
    @Test func startsOnLoopbackWellUnderASecond() async throws {
        let started = ContinuousClock.now
        let harness = try await DemoHarness.start()
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(1))
        #expect(harness.endpoint.serverURL.host == "127.0.0.1")
        #expect(harness.endpoint.serverURL.port != nil)
        #expect(harness.endpoint.serverURL == harness.endpoint.plexTVURL)
        #expect(harness.endpoint.token == "demo-token")
        #expect(harness.endpoint.serverName == "Crucible Demo")
        #expect(harness.endpoint.accountName == "Demo")
        await harness.stop()
    }

    @Test func startingTwiceReturnsTheSameEndpoint() async throws {
        let provider = DemoLibraryProvider(assets: nil, stateFileURL: DemoHarness.temporaryStateFile())
        async let first = provider.start()
        async let second = provider.start()
        let endpoints = try await [first, second]
        #expect(endpoints[0] == endpoints[1])
        #expect(try await provider.start() == endpoints[0])
        await provider.stop()
    }

    @Test func stopThenStartTwiceGivesNewEndpointsAndTheOldOnesRefuse() async throws {
        let provider = DemoLibraryProvider(assets: nil, stateFileURL: DemoHarness.temporaryStateFile())
        var seen = [DemoEndpoint]()
        for _ in 0..<3 {
            let endpoint = try await provider.start()
            seen.append(endpoint)
            let (_, response) = try await URLSession.shared.data(from: endpoint.serverURL.appendingPathComponent("identity"))
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            await provider.stop()
            await #expect(throws: URLError.self) {
                _ = try await URLSession.shared.data(from: endpoint.serverURL.appendingPathComponent("identity"))
            }
        }
        #expect(Set(seen.map(\.serverURL)).count == 3)
        await provider.stop()
    }

    @Test func fiftyParallelRequestsAllSucceed() async throws {
        try await withDemo { demo in
            let paths = ["/identity", "/library/sections", "/hubs", "/library/metadata/1001", "/library/sections/1/all",
                         "/status/sessions/history/all?X-Plex-Container-Size=20", "/hubs/search?query=sea",
                         "/photo/:/transcode?url=/library/metadata/1001/thumb/1&width=300&height=450"]
            let statuses = try await withThrowingTaskGroup(of: Int.self) { group in
                for index in 0..<50 {
                    group.addTask { try await demo.get(paths[index % paths.count]).1.statusCode }
                }
                var all = [Int]()
                for try await status in group { all.append(status) }
                return all
            }
            #expect(statuses.count == 50)
            #expect(statuses.allSatisfy { $0 == 200 })
        }
    }

    @Test func keepAliveServesSeveralRequestsOnOneConnection() async throws {
        try await withDemo { demo in
            let port = try #require(demo.base.port)
            let request = "GET /identity HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
            let reply = try RawSocket.exchange(port: port, requests: [String](repeating: request, count: 3), expectedResponses: 3)
            #expect(reply.components(separatedBy: "HTTP/1.1 200 OK").count == 4)
            #expect(reply.contains("Connection: keep-alive"))
            #expect(reply.contains("Content-Type: application/json"))
        }
    }

    @Test func unknownRoutesAnswerNotFound() async throws {
        try await withDemo { demo in
            let (_, missing) = try await demo.get("/nope")
            #expect(missing.statusCode == 404)
            let (_, item) = try await demo.get("/library/metadata/999999")
            #expect(item.statusCode == 404)
        }
    }

    @Test func headRequestsCarryLengthButNoBody() async throws {
        try await withDemo { demo in
            let (data, response) = try await demo.get("/library/sections", method: "HEAD")
            #expect(response.statusCode == 200)
            #expect(data.isEmpty)
            #expect((Int(response.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0) > 0)
        }
    }
}

enum RawSocket {
    /// Sends the requests down one TCP connection and reads until `expectedResponses` status lines have come back.
    static func exchange(port: Int, requests: [String], expectedResponses: Int) throws -> String {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw URLError(.cannotConnectToHost) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        for request in requests { _ = request.withCString { send(descriptor, $0, strlen($0), 0) } }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while String(decoding: received, as: UTF8.self).components(separatedBy: "HTTP/1.1 ").count - 1 < expectedResponses {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count <= 0 { break }
            received.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: received, as: UTF8.self)
    }
}
