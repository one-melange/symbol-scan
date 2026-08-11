import Foundation

// MARK: - Prompt

/// A prompt for the local model: a system instruction plus the user turn carrying the picked
/// symbol's structured, Tree-sitter-derived context. Pure value type so `PromptBuilder` stays
/// off `@MainActor` and unit-testable in isolation (like `SymbolMatcher` / `Symbol.injectionText`).
struct LLMPrompt: Equatable, Sendable {
    let system: String
    let user: String
}

// MARK: - Errors

/// Failures surfaced to the picker's explanation panel. `errorDescription` is the user-facing copy
/// shown in the pane, so keep it short and non-technical. `Sendable` so it can ride the token stream
/// and be stored by test fakes.
enum LLMError: LocalizedError, Sendable, Equatable {
    /// The runtime binary or the model weights aren't available (not bundled, or no model file).
    case modelUnavailable(String)
    /// The local server process failed to launch or never became healthy.
    case serverFailedToStart(String)
    /// The server answered with a non-2xx status.
    case http(Int, String)
    /// The connection dropped or the response couldn't be read.
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let m):     return m
        case .serverFailedToStart(let m):  return "Couldn't start the local model — \(m)"
        case .http(let code, let body):    return "Model server error (\(code))\(body.isEmpty ? "" : ": \(body)")"
        case .transport(let m):            return "Lost the connection to the local model — \(m)"
        }
    }
}

// MARK: - Client seam

/// The transport seam between the picker and whatever runs the model. A picked symbol's prompt goes
/// in; a **cold** stream of token deltas comes back (nothing runs until the caller iterates). Kept
/// tiny and `Sendable` so the view model can hold `any LLMClient` and tests can substitute a fake
/// with no server, no HTTP, and no process. The v1 concrete impl is `LlamaServerClient`; a BYO-HTTP
/// or MLX backend can drop in behind the same protocol later.
protocol LLMClient: Sendable {
    /// Explain `prompt`, streaming the answer as it's generated. Producing runs off the main actor;
    /// cancelling the consuming task cancels the underlying request.
    func explain(_ prompt: LLMPrompt) -> AsyncThrowingStream<String, Error>
}

// MARK: - Prompt building

/// Turns a `Symbol` into an `LLMPrompt`. Pure and `nonisolated` (no IO, no main-actor state) so it's
/// unit-testable exactly like `SymbolMatcher`. v1 is **doc-only**: it uses only fields already on
/// `Symbol` (name / kind / path / line / signature / the T26 `doc`). Richer context (source snippet,
/// enclosing type, outgoing calls) is a deliberate follow-up — see TASKS.md T28.
enum PromptBuilder {
    /// The system instruction. Steers the small coder model toward a tight behavioral summary and
    /// away from code generation, and tells it to be honest when the context is thin (v1 often ships
    /// only name + signature). Kept as a constant so a test can assert it reaches the prompt.
    nonisolated static let system = """
    You are a senior engineer explaining a single code symbol to a teammate. Be concise and precise: \
    describe what the symbol does, its inputs, and any side effects. Base your answer only on the \
    provided context. If the context is thin, say what you can reasonably infer from the name and \
    signature and flag it as an inference. Do not generate code.
    """

    /// A human-readable noun for a `SymbolKind`, used in the prompt header.
    nonisolated static func label(for kind: SymbolKind) -> String {
        switch kind {
        case .function:  return "function"
        case .method:    return "method"
        case .class:     return "class"
        case .struct:    return "struct"
        case .enum:      return "enum"
        case .trait:     return "trait/protocol"
        case .interface: return "interface"
        case .constant:  return "constant"
        case .variable:  return "variable"
        case .type:      return "type alias"
        case .file:      return "file"
        case .directory: return "directory"
        }
    }

    nonisolated static func build(for symbol: Symbol) -> LLMPrompt {
        var lines: [String] = []
        lines.append("[Context from the Tree-sitter index]")
        lines.append("File: \(symbol.filePath):\(symbol.line)")
        lines.append("Kind: \(label(for: symbol.kind))")
        lines.append("Name: \(symbol.name)")
        if let sig = symbol.signature, !sig.isEmpty {
            lines.append("Signature: \(sig)")
        }
        if let doc = symbol.doc, !doc.isEmpty {
            lines.append("")
            lines.append("Documentation comment:")
            lines.append(doc)
        }
        lines.append("")
        lines.append("[Instruction]")
        lines.append("Explain the behavior, inputs, and side effects of this \(label(for: symbol.kind)). Do not generate code.")
        return LLMPrompt(system: system, user: lines.joined(separator: "\n"))
    }
}

// MARK: - Preferences

/// UserDefaults-backed configuration for the local model, mirroring `RepoPreference` /
/// `HotkeyPreference`. All keys have sane defaults so the feature works with no configuration once a
/// runtime + model are present. `nonisolated` reads so the off-main server actor can consult them.
enum LLMPreferences {
    private nonisolated static let modelPathKey = "llm.modelPath"   // absolute path override for the .gguf
    private nonisolated static let modelNameKey = "llm.modelName"   // name sent as the request's "model"
    private nonisolated static let portKey      = "llm.serverPort"  // fixed localhost port for llama-server

    /// Default file name looked up under Application Support when no override path is set.
    nonisolated static let defaultModelFileName = "qwen2.5-coder-3b-instruct-q4_k_m.gguf"

    /// An explicit `.gguf` path the user pointed us at, or nil to use the Application Support default.
    nonisolated static var modelPathOverride: String? {
        UserDefaults.standard.string(forKey: modelPathKey)
    }

    /// The model name sent in the chat request. llama-server ignores it for a single loaded model,
    /// so the default is cosmetic; kept configurable for BYO-endpoint setups that route by name.
    nonisolated static var modelName: String {
        UserDefaults.standard.string(forKey: modelNameKey) ?? "qwen2.5-coder-3b-instruct"
    }

    /// The localhost port llama-server binds. Fixed (not auto-assigned) to keep v1 simple; override
    /// if it collides with something you already run.
    nonisolated static var serverPort: Int {
        let p = UserDefaults.standard.integer(forKey: portKey)
        return p == 0 ? 8127 : p
    }
}
