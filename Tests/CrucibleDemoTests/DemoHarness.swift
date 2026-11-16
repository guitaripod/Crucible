@testable import CrucibleCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CrucibleDemo

/// A running demo library with the app's own API client pointed at it, and a state file of its own.
struct DemoHarness {
    let provider: DemoLibraryProvider
    let endpoint: DemoEndpoint
    let api: APIClient
    let stateFile: URL

    var base: URL { endpoint.serverURL }

    func url(_ path: String) -> URL {
        URL(string: base.absoluteString + path)!
    }

    func get(_ path: String, headers: [String: String] = [:], method: String = "GET") async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, try #require(response as? HTTPURLResponse))
    }

    func json(_ path: String) async throws -> [String: Any] {
        let (data, response) = try await get(path)
        #expect(response.statusCode == 200)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func metadata(_ key: String) async throws -> PlexMetadata {
        await api.invalidateCache()
        return try #require(try await api.requestContainer(.metadata(ratingKey: key)).Metadata?.first)
    }

    func stop() async {
        await provider.stop()
    }

    /// A state file of its own in this run's folder, which a test may hand to several servers in turn.
    static func temporaryStateFile() -> URL {
        runFolder.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("state.json")
    }

    /// The folder every state file of this test run lives in, named for the process and removed when it exits, so runs
    /// leave nothing behind in the temporary directory.
    private static let runFolder: URL = {
        atexit { try? FileManager.default.removeItem(at: DemoHarness.runFolderURL) }
        return runFolderURL
    }()

    private static var runFolderURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("crucible-demo-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    static func start(stateFile: URL = temporaryStateFile()) async throws -> DemoHarness {
        let provider = DemoLibraryProvider(assets: nil, stateFileURL: stateFile)
        let endpoint = try await provider.start()
        return DemoHarness(provider: provider, endpoint: endpoint, api: APIClient(baseURL: endpoint.serverURL, token: endpoint.token), stateFile: stateFile)
    }
}

func withDemo(stateFile: URL = DemoHarness.temporaryStateFile(), _ body: (DemoHarness) async throws -> Void) async throws {
    let harness = try await DemoHarness.start(stateFile: stateFile)
    do {
        try await body(harness)
    } catch {
        await harness.stop()
        throw error
    }
    await harness.stop()
}
