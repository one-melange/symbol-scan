import Foundation

/// A minimal OpenAI-compatible `POST /v1/chat/completions` **streaming** client — the actual bridge
/// to llama.cpp's `llama-server` (and, unchanged, to Ollama / LM Studio / mlx_lm.server, which all
/// speak the same wire format). Factored as stateless statics (like `Indexer`): a pure request
/// builder and a pure SSE line parser — the fiddly parts — are unit-tested over canned bytes with no
/// live server, and only `stream(...)` touches the network. There is no URLSession precedent in the
/// app, so this is built from scratch; the streaming read uses `URLSession.bytes(for:)` (macOS 14+).
enum OpenAIChatStream {

    /// One parsed Server-Sent-Events `data:` line.
    enum Event: Equatable {
        case token(String)   // a `delta.content` chunk to append
        case done            // the `data: [DONE]` sentinel
        case ignore          // keepalive, comment, role-only delta, or anything without content
    }

    /// Build the POST request. Pure + testable.
    nonisolated static func makeRequest(baseURL: URL, model: String, prompt: LLMPrompt) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": prompt.system],
                ["role": "user",   "content": prompt.user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return req
    }

    /// Parse one raw SSE line. Pure + testable. Tolerant: blanks, `:` comments/keepalives, role-only
    /// deltas and malformed JSON all map to `.ignore` so the stream just keeps going.
    nonisolated static func parse(line: String) -> Event {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return .ignore }
        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first else { return .ignore }
        // Streaming chunks carry the incremental text in `delta.content`; the first chunk is often a
        // role-only delta and the final one may have no content — both are `.ignore`.
        if let delta = first["delta"] as? [String: Any],
           let content = delta["content"] as? String,
           !content.isEmpty {
            return .token(content)
        }
        return .ignore
    }

    /// Open the streamed completion. The network runs on a **detached** task (off the main actor,
    /// like `SymbolIndex`'s indexing) so token decoding never blocks the UI; cancelling the consumer
    /// cancels the request via `onTermination`.
    nonisolated static func stream(baseURL: URL,
                                   model: String,
                                   prompt: LLMPrompt,
                                   session: URLSession = .shared) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let request = try makeRequest(baseURL: baseURL, model: model, prompt: prompt)
                    let (bytes, response) = try await session.bytes(for: request)

                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        // Read a short slice of the error body for a useful message, then stop.
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 400 { break }
                        }
                        throw LLMError.http(http.statusCode, body.trimmingCharacters(in: .whitespacesAndNewlines))
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        switch parse(line: line) {
                        case .token(let t): continuation.yield(t)
                        case .done:         continuation.finish(); return
                        case .ignore:       continue
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as LLMError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: LLMError.transport(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
