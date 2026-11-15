@testable import CrucibleCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@Suite(.serialized)
struct OpenAICompatibleBrainTests {
    private static let aliasesJSON = Data("""
    {"version": 1, "aliases": [
      {"alias": "watch.plan.v1", "max_tokens": 300, "response_schema": {"type": "object", "properties": {"kind": {"type": "string"}}}},
      {"alias": "recap.describe.v1", "max_tokens": 2000},
      {"alias": "missing.v1", "max_tokens": 100}
    ]}
    """.utf8)

    private static let prompts = OpenAICompatiblePrompts(aliasesJSON: aliasesJSON) { alias in
        alias == "missing.v1" ? nil : "Answer in {language} for \(alias)."
    }!

    private func brain(_ address: String, key: String? = nil) -> OpenAICompatibleBrain {
        OpenAICompatibleBrain(address: URL(string: address)!, model: "qwen3", key: key, prompts: Self.prompts)
    }

    private func body(of request: URLRequest) -> [String: Any] {
        (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    private func reply(_ content: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": content]]]])
    }

    @Test func promptsTakeEachAliasWithInstructionsAndLeaveOutTheRest() {
        #expect(Set(Self.prompts.aliases.keys) == ["watch.plan.v1", "recap.describe.v1"])
        #expect(Self.prompts.aliases["watch.plan.v1"]?.maxTokens == 300)
        #expect(Self.prompts.aliases["watch.plan.v1"]?.schema != nil)
        #expect(Self.prompts.aliases["recap.describe.v1"]?.schema == nil)
        #expect(OpenAICompatiblePrompts(aliasesJSON: Data("[]".utf8)) { _ in "" } == nil)
    }

    @Test(arguments: [
        ("http://192.168.1.20:8080", "http://192.168.1.20:8080/v1/chat/completions"),
        ("http://192.168.1.20:8080/", "http://192.168.1.20:8080/v1/chat/completions"),
        ("http://localhost:8081/v1", "http://localhost:8081/v1/chat/completions"),
        ("http://localhost:8081/v1/", "http://localhost:8081/v1/chat/completions"),
        ("https://api.example.com/v1/chat/completions", "https://api.example.com/v1/chat/completions"),
        ("http://host/openai/v1", "http://host/openai/v1/chat/completions"),
    ])
    func theEndpointIsFoundWhicheverPartOfTheAddressWasTyped(address: String, endpoint: String) {
        #expect(OpenAICompatibleBrain.endpoint(for: URL(string: address)!).absoluteString == endpoint)
    }

    @Test func theRequestCarriesTheAliasInstructionsInTheLanguageAndTheSchema() throws {
        let alias = try #require(Self.prompts.aliases["watch.plan.v1"])
        let request = brain("http://localhost:8081/v1", key: "secret").request(for: alias, alias: "watch.plan.v1", input: "something funny", language: "Finnish", shaped: true)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let body = body(of: request)
        #expect(body["model"] as? String == "qwen3")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "Answer in Finnish for watch.plan.v1."], ["role": "user", "content": "something funny"]])
        #expect(body["max_tokens"] as? Int == 1200)
        let format = try #require(body["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect((format["json_schema"] as? [String: Any])?["name"] as? String == "watch_plan_v1")
    }

    @Test func anUnshapedRequestOrOneWithoutAKeyLeavesThoseOut() throws {
        let alias = try #require(Self.prompts.aliases["watch.plan.v1"])
        let request = brain("http://localhost:8081").request(for: alias, alias: "watch.plan.v1", input: "x", language: "English", shaped: false)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(body(of: request)["response_format"] == nil)
    }

    @Test func aLongAliasKeepsItsOwnTokenCapTimesFour() throws {
        let alias = try #require(Self.prompts.aliases["recap.describe.v1"])
        let request = brain("http://localhost:8081").request(for: alias, alias: "recap.describe.v1", input: "x", language: "English", shaped: true)
        #expect(body(of: request)["max_tokens"] as? Int == 8000)
        #expect(body(of: request)["response_format"] == nil)
    }

    @Test func theReplyIsTheJSONPastReasoningAndFences() throws {
        #expect(try OpenAICompatibleBrain.reply(status: 200, data: reply(#"{"kind":"film"}"#)) == #"{"kind":"film"}"#)
        #expect(try OpenAICompatibleBrain.reply(status: 200, data: reply("<think>maybe {a} or {b}</think>\n```json\n{\"kind\":\"show\"}\n```")) == #"{"kind":"show"}"#)
        #expect(try OpenAICompatibleBrain.reply(status: 200, data: reply("A plain recap.")) == "A plain recap.")
    }

    @Test(arguments: [(429, HostedBrainError.busy), (503, .busy), (400, .declined), (422, .declined), (401, .failed), (404, .failed), (500, .failed)])
    func eachStatusMeansItsOwnNextStep(status: Int, error: HostedBrainError) {
        #expect(throws: error) { try OpenAICompatibleBrain.reply(status: status, data: Data()) }
    }

    @Test func aReplyThatIsNotAChatCompletionFails() {
        #expect(throws: HostedBrainError.failed) { try OpenAICompatibleBrain.reply(status: 200, data: Data("{\"error\":\"x\"}".utf8)) }
        #expect(throws: HostedBrainError.failed) { try OpenAICompatibleBrain.reply(status: 200, data: Data("not json".utf8)) }
    }

    @Test func anAliasWithoutInstructionsIsUnavailable() async {
        await #expect(throws: HostedBrainError.unavailable) { try await brain("http://localhost:1").ask(alias: "missing.v1", input: "x", language: "English") }
    }

    @Test func askingAServerReadsItsAnswer() async throws {
        let server = DetailStubServer()
        server.reply(path: "/v1/chat/completions", body: ["choices": [["message": ["content": #"{"kind":"film"}"#]]]])
        let answer = try await brain("http://\(server.host)").ask(alias: "watch.plan.v1", input: "x", language: "English")
        #expect(answer == #"{"kind":"film"}"#)
        #expect(server.requests == ["/v1/chat/completions"])
    }

    @Test func aServerThatDeclinesTheSchemaIsAskedOnceMoreWithoutIt() async {
        let server = DetailStubServer()
        server.reply(path: "/v1/chat/completions", status: 400, body: [:])
        await #expect(throws: HostedBrainError.declined) { try await brain("http://\(server.host)").ask(alias: "watch.plan.v1", input: "x", language: "English") }
        #expect(server.requests.count == 2)
    }

    @Test func anAliasWithoutASchemaIsNotAskedTwice() async {
        let server = DetailStubServer()
        server.reply(path: "/v1/chat/completions", status: 400, body: [:])
        await #expect(throws: HostedBrainError.declined) { try await brain("http://\(server.host)").ask(alias: "recap.describe.v1", input: "x", language: "English") }
        #expect(server.requests.count == 1)
    }

    @Test func anUnreachableServerIsOffline() async {
        let server = DetailStubServer()
        server.failTransport(path: "/v1/chat/completions")
        await #expect(throws: HostedBrainError.offline) { try await brain("http://\(server.host)").ask(alias: "watch.plan.v1", input: "x", language: "English") }
    }
}
