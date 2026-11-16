import Foundation
import Testing
@testable import CrucibleCore

struct HostedBrainLayerTests {
    private struct Fake: HostedBrainProviding {
        var onDevice = false
        var ready = true
        var aliases: Set<String> = ["a", "b"]
        var reply: Result<String, HostedBrainError> = .success("ok")

        var isReady: Bool { ready }
        var isOnDevice: Bool { onDevice }
        func answers(alias: String, input: String, language: String) -> Bool { aliases.contains(alias) }
        func ask(alias: String, input: String, language: String) async throws(HostedBrainError) -> String {
            switch reply {
            case .success(let text): return onDevice ? "device:\(text)" : "hosted:\(text)"
            case .failure(let error): throw error
            }
        }
    }

    @Test func theDeviceAnswersFirstAndTheHostedModelCatchesItsFailures() async throws {
        let both = HostedBrainLayers([Fake(onDevice: true), Fake()])
        #expect(try await both.ask(alias: "a", input: "", language: "English") == "device:ok")
        let failing = HostedBrainLayers([Fake(onDevice: true, reply: .failure(.declined)), Fake()])
        #expect(try await failing.ask(alias: "a", input: "", language: "English") == "hosted:ok")
        let alone = HostedBrainLayers([Fake(onDevice: true, reply: .failure(.declined))])
        await #expect(throws: HostedBrainError.declined) { try await alone.ask(alias: "a", input: "", language: "English") }
    }

    @Test func anAliasTheDeviceCannotAnswerGoesStraightToTheHostedModel() async throws {
        let layers = HostedBrainLayers([Fake(onDevice: true, aliases: ["a"]), Fake()])
        #expect(try await layers.ask(alias: "b", input: "", language: "English") == "hosted:ok")
        #expect(layers.route(for: ["a", "b"], input: "", language: "English") == .hosted)
        #expect(layers.route(for: ["a"], input: "", language: "English") == .onDeviceFirst)
    }

    @Test func routesSayWhetherAnythingCanLeaveTheDevice() {
        #expect(HostedBrainLayers([Fake(onDevice: true)]).route(for: ["a"], input: "", language: "English") == .onDevice)
        #expect(HostedBrainLayers([Fake(onDevice: true), Fake()]).route(for: ["a"], input: "", language: "English") == .onDeviceFirst)
        #expect(HostedBrainLayers([Fake()]).route(for: ["a"], input: "", language: "English") == .hosted)
        #expect(HostedBrainLayers([Fake(onDevice: true, ready: false), Fake()]).route(for: ["a"], input: "", language: "English") == .hosted)
    }

    @Test func aModelThatIsNotReadyIsLeftOut() async {
        let layers = HostedBrainLayers([Fake(onDevice: true, ready: false)])
        #expect(!layers.isAvailable)
        #expect(!layers.canAnswer(alias: "a", input: "", language: "English"))
        await #expect(throws: HostedBrainError.unavailable) { try await layers.ask(alias: "a", input: "", language: "English") }
    }
}
