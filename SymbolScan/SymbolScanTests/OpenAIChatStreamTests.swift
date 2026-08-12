import Testing
import Foundation
@testable import SymbolScan

/// The SSE parser and request builder are the fiddly, server-independent parts of the transport, so
/// they're unit-tested over canned strings — no llama-server, no network.
@Suite struct OpenAIChatStreamTests {

    private let base = URL(string: "http://127.0.0.1:8127")!

    // MARK: - parse(line:)

    @Test func parsesContentDelta() {
        let line = #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#
        #expect(OpenAIChatStream.parse(line: line) == .token("Hello"))
    }

    @Test func parsesDoneSentinel() {
        #expect(OpenAIChatStream.parse(line: "data: [DONE]") == .done)
    }

    @Test func ignoresRoleOnlyDelta() {
        let line = #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#
        #expect(OpenAIChatStream.parse(line: line) == .ignore)
    }

    @Test func ignoresBlankAndCommentLines() {
        #expect(OpenAIChatStream.parse(line: "") == .ignore)
        #expect(OpenAIChatStream.parse(line: ": keepalive") == .ignore)
    }

    @Test func ignoresMalformedJSON() {
        #expect(OpenAIChatStream.parse(line: "data: {not json") == .ignore)
    }

    @Test func ignoresEmptyContentDelta() {
        let line = #"data: {"choices":[{"delta":{"content":""}}]}"#
        #expect(OpenAIChatStream.parse(line: line) == .ignore)
    }

    // MARK: - makeRequest

    @Test func buildsStreamingChatRequest() throws {
        let prompt = LLMPrompt(system: "sys", user: "usr")
        let req = try OpenAIChatStream.makeRequest(baseURL: base, model: "qwen", prompt: prompt)

        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "http://127.0.0.1:8127/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(req.httpBody)
        let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(obj["stream"] as? Bool == true)
        #expect(obj["model"] as? String == "qwen")
        let messages = try #require(obj["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        #expect(messages.first?["role"] == "system")
        #expect(messages.first?["content"] == "sys")
        #expect(messages.last?["content"] == "usr")
    }
}
