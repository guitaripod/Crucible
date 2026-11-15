import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MidgarCore

/// The instructions and reply shapes of the hosted aliases (`tools/ai/aliases.json` and its prompts), so a model the
/// person runs answers as Midgar's would.
package struct OpenAICompatiblePrompts: Sendable {
    package struct Alias: Sendable, Equatable {
        package let instructions: String
        package let maxTokens: Int
        package let schema: Data?
    }

    package let aliases: [String: Alias]

    /// Reads `aliases.json`, taking each alias's instructions from `instructions(alias)`; an alias without them is left out.
    package init?(aliasesJSON: Data, instructions: (String) -> String?) {
        guard let root = try? JSONSerialization.jsonObject(with: aliasesJSON) as? [String: Any],
              let entries = root["aliases"] as? [[String: Any]] else { return nil }
        var aliases: [String: Alias] = [:]
        for entry in entries {
            guard let name = entry["alias"] as? String, let text = instructions(name) else { continue }
            let schema = (entry["response_schema"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) }
            aliases[name] = Alias(instructions: text, maxTokens: entry["max_tokens"] as? Int ?? 400, schema: schema)
        }
        self.aliases = aliases
    }
}

/// A hosted brain on any OpenAI-compatible chat completions server (llama.cpp, Ollama, LM Studio, vLLM or a hosted
/// service): each alias's instructions in the language the app is shown in, the request as the message, and the reply
/// held to the alias's JSON shape where the server supports it, and found in the text where it does not.
package struct OpenAICompatibleBrain: HostedBrainProviding {
    package let endpoint: URL
    package let model: String
    package let key: String?
    package let prompts: OpenAICompatiblePrompts

    /// How long a local model may think before the request counts as failed.
    private static let timeout: TimeInterval = 120

    package init(address: URL, model: String, key: String?, prompts: OpenAICompatiblePrompts) {
        self.endpoint = Self.endpoint(for: address)
        self.model = model
        self.key = key
        self.prompts = prompts
    }

    /// `/v1/chat/completions` under `address`, whether the person typed the base, the `/v1` path or the full endpoint.
    package static func endpoint(for address: URL) -> URL {
        let path = address.path
        if path.hasSuffix("/chat/completions") { return address }
        if path.hasSuffix("/v1") || path.hasSuffix("/v1/") { return address.appendingPathComponent("chat/completions") }
        return address.appendingPathComponent("v1").appendingPathComponent("chat/completions")
    }

    package func ask(alias: String, input: String, language: String) async throws(HostedBrainError) -> String {
        guard let entry = prompts.aliases[alias] else { throw .unavailable }
        do {
            return try await send(request(for: entry, alias: alias, input: input, language: language, shaped: true), alias: alias)
        } catch HostedBrainError.declined where entry.schema != nil {
            return try await send(request(for: entry, alias: alias, input: input, language: language, shaped: false), alias: alias)
        }
    }

    /// The chat completions request for one alias; `shaped` asks the server to hold the reply to the alias's JSON
    /// schema, which not every server takes. The token cap leaves room for a thinking model's reasoning.
    package func request(for entry: OpenAICompatiblePrompts.Alias, alias: String, input: String, language: String, shaped: Bool) -> URLRequest {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": entry.instructions.replacingOccurrences(of: "{language}", with: language)],
                ["role": "user", "content": input],
            ],
            "max_tokens": max(entry.maxTokens * 4, 1200),
            "temperature": 0.3,
            "stream": false,
        ]
        if shaped, let schema = entry.schema, let object = try? JSONSerialization.jsonObject(with: schema) {
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": alias.replacingOccurrences(of: ".", with: "_"), "schema": object]]
        }
        var request = URLRequest(url: endpoint, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        return request
    }

    private func send(_ request: URLRequest, alias: String) async throws(HostedBrainError) -> String {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await HTTPSession.current.data(for: request)
        } catch {
            MidgarLog.notice("Own model unreachable at \(endpoint.host ?? "?"): \(error.localizedDescription)", category: .networking)
            throw .offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            return try Self.reply(status: status, data: data)
        } catch {
            if error == .failed { MidgarLog.notice("Own model answered HTTP \(status) for \(alias)", category: .networking) }
            throw error
        }
    }

    /// The answer in a server's reply: the JSON object in the message, or the message itself when it holds none.
    package static func reply(status: Int, data: Data) throws(HostedBrainError) -> String {
        switch status {
        case 200..<300: break
        case 429, 503: throw .busy
        case 400, 422: throw .declined
        default: throw .failed
        }
        guard let text = content(of: data) else { throw .failed }
        return json(in: text) ?? text
    }

    /// The message text of an OpenAI-compatible reply.
    package static func content(of data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { return nil }
        return message["content"] as? String
    }

    /// The JSON object in a reply, past any reasoning a thinking model wrote first and any code fence around it.
    package static func json(in text: String) -> String? {
        var body = text
        if let close = body.range(of: "</think>", options: .backwards) { body = String(body[close.upperBound...]) }
        guard let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}"), start < end else { return nil }
        return String(body[start...end])
    }
}
