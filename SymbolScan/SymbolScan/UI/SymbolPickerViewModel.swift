import SwiftUI
import Combine

/// The picker's local-LLM "explain" state, driven by `explain()`. `Equatable` so the view can key
/// off it and tests can assert transitions. `.streaming` and `.done` both carry the accumulated text
/// — `.streaming` while tokens are still arriving (spinner shown), `.done` once the stream ended.
enum ExplanationState: Equatable {
    case idle
    case loading
    case streaming(String)
    case done(String)
    case failed(String)

    /// The text to render in the pane (partial while streaming, full when done), or nil.
    var displayText: String? {
        switch self {
        case .streaming(let s), .done(let s): return s
        default: return nil
        }
    }

    /// True while we're waiting on or receiving tokens — drives the pane's progress spinner.
    var isBusy: Bool {
        switch self {
        case .loading, .streaming: return true
        default: return false
        }
    }
}

/// Holds the picker's mutable state in a reference type so key handlers can read/write
/// the *live* values (a SwiftUI `@State` would be captured stale at install time).
@MainActor
final class SymbolPickerViewModel: ObservableObject {
    /// Mirrors the search field's text. Updated synchronously via `updateQuery(_:)` from
    /// the field's AppKit delegate callback — which runs *outside* a SwiftUI view update,
    /// so the assignment here is not a re-entrant publish.
    @Published var query: String = ""
    @Published private(set) var results: [Symbol] = []
    @Published var selectedIndex: Int = 0

    /// The AI-explanation state for the current selection (`.idle` until the user presses ⌘E).
    @Published private(set) var explanation: ExplanationState = .idle

    let index: SymbolIndex

    /// The model transport, or nil when the app was built/launched without one (and in unit tests
    /// that don't exercise the explain flow) — in which case `explain()` is a no-op.
    let llmClient: (any LLMClient)?

    /// The in-flight explain task, cancelled when the selection changes or a new explain starts.
    /// Not private so tests (`@testable`) can `await explainTask?.value` for deterministic assertions.
    private(set) var explainTask: Task<Void, Never>?

    init(index: SymbolIndex, llmClient: (any LLMClient)? = nil) {
        self.index = index
        self.llmClient = llmClient
        self.results = index.search("")
    }

    /// Apply a new search string and recompute results synchronously. Called from the
    /// search field's `controlTextDidChange`, so there's no need to defer through Combine.
    func updateQuery(_ newValue: String) {
        guard newValue != query else { return }
        query = newValue
        results = index.search(newValue)
        selectedIndex = 0
        resetExplanation()
    }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + results.count) % results.count
        resetExplanation()
    }

    /// Cancel any in-flight explanation and return to `.idle`. Called whenever the selection moves,
    /// so the pane never shows one symbol's explanation while a different row is highlighted.
    func resetExplanation() {
        explainTask?.cancel()
        explainTask = nil
        if explanation != .idle { explanation = .idle }
    }

    /// Stream an AI explanation of the current selection into `explanation`. No-op if no client is
    /// configured or nothing is selected. Safe to call repeatedly — a new call supersedes the old.
    func explain() {
        guard let client = llmClient, let symbol = selectedSymbol() else { return }
        explainTask?.cancel()
        explanation = .loading
        let prompt = PromptBuilder.build(for: symbol)
        // Runs on the view model's `@MainActor`, so each assignment publishes on the main thread; the
        // stream's token production happens off-main (see `OpenAIChatStream.stream`), we just consume.
        explainTask = Task { [weak self] in
            var buffer = ""
            do {
                for try await token in client.explain(prompt) {
                    buffer += token
                    self?.explanation = .streaming(buffer)
                }
                guard let self, !Task.isCancelled else { return }
                self.explanation = buffer.isEmpty
                    ? .failed("The model returned no output.")
                    : .done(buffer)
            } catch {
                guard let self, !Task.isCancelled else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.explanation = .failed(message)
            }
        }
    }

    /// The currently selected symbol, or nil if nothing is selected.
    func selectedSymbol() -> Symbol? {
        guard selectedIndex < results.count else { return nil }
        return results[selectedIndex]
    }

    /// The exact text to inject/copy for the current selection, or nil if nothing is selected.
    /// Composition (path + name for code symbols, name + parent dir for files/dirs) lives on
    /// `Symbol.injectionText` so it stays pure and testable.
    func selectedInjectionText() -> String? {
        selectedSymbol()?.injectionText
    }
}
