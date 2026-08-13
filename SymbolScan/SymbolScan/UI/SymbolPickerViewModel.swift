import SwiftUI
import Combine

/// The picker's local-LLM "explain" state, driven by `explain()`. `Equatable` so the view can key
/// off it and tests can assert transitions. `.streaming` and `.done` both carry the accumulated text
/// — `.streaming` while tokens are still arriving (spinner shown), `.done` once the stream ended.
enum ExplanationState: Equatable {
    case idle
    case preparing(String)   // one-time model provisioning (download) / warmup message
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

    /// True while we're preparing, waiting on, or receiving tokens — drives the pane's spinner.
    var isBusy: Bool {
        switch self {
        case .preparing, .loading, .streaming: return true
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

    /// Provisions the model (first-run download). When present and not yet ready, `explain()` shows
    /// download progress and streams once it's on disk. Nil in tests / when explain is inert.
    let provisioner: ModelProvisioner?

    /// The in-flight explain task, cancelled when the selection changes or a new explain starts.
    /// Not private so tests (`@testable`) can `await explainTask?.value` for deterministic assertions.
    private(set) var explainTask: Task<Void, Never>?

    init(index: SymbolIndex,
         llmClient: (any LLMClient)? = nil,
         provisioner: ModelProvisioner? = nil) {
        self.index = index
        self.llmClient = llmClient
        self.provisioner = provisioner
        self.results = index.search("")
    }

    /// Final safety net: if the view model is torn down while an explanation is streaming (e.g. the
    /// overlay is released), cancel the task so generation stops. `resetExplanation()` in the
    /// controller's `hide()` is the primary, deterministic cancellation path.
    deinit {
        explainTask?.cancel()
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
        select((selectedIndex + delta + results.count) % results.count)
    }

    /// The single entry point for changing the selection — from arrow keys, mouse hover, or a tap.
    /// Centralized so **every** selection change clears a stale explanation; hover used to set
    /// `selectedIndex` directly, which left the pane showing one symbol's answer under another
    /// symbol's heading. A no-op when the index is unchanged, so hovering the current row keeps it.
    func select(_ index: Int) {
        guard index != selectedIndex else { return }
        selectedIndex = index
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
        // The bundled runtime is Apple-Silicon-only — fail clearly on Intel rather than spinning up
        // (and downloading a model for) a helper that can't exec here.
        guard LLMRuntime.isSupported else {
            explanation = .failed(LLMRuntime.unsupportedMessage)
            return
        }
        explanation = .loading
        let prompt = PromptBuilder.build(for: symbol)
        // Runs on the view model's `@MainActor`, so each assignment publishes on the main thread; the
        // download + token production happen off-main, we just reflect them.
        explainTask = Task { [weak self] in
            // 1) Make sure the model is on disk. On first run this may still be downloading — show
            //    live progress rather than a spinner, so the one-time ~2 GB fetch is legible.
            if let provisioner = self?.provisioner {
                let ready = await self?.awaitModelReady(provisioner) ?? false
                guard ready else { return }
            }
            guard let self, !Task.isCancelled else { return }

            // 2) Stream the explanation.
            self.explanation = .loading
            var buffer = ""
            do {
                for try await token in client.explain(prompt) {
                    buffer += token
                    self.explanation = .streaming(buffer)
                }
                guard !Task.isCancelled else { return }
                self.explanation = buffer.isEmpty
                    ? .failed("The model returned no output.")
                    : .done(buffer)
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.explanation = .failed(message)
            }
        }
    }

    /// Drive the pane through model provisioning until the model is ready. Returns false (and sets a
    /// terminal `.failed`) if the download failed or the task was cancelled, so the caller stops.
    /// Reflects download progress into `.preparing(...)` by polling the provisioner's published state.
    private func awaitModelReady(_ provisioner: ModelProvisioner) async -> Bool {
        provisioner.start()
        while true {
            switch provisioner.state {
            case .ready:
                return true
            case .failed(let message):
                explanation = .failed(message)
                return false
            case .downloading(let fraction):
                explanation = .preparing("Setting up the local model… \(Int((fraction * 100).rounded()))% (one time)")
            case .unknown:
                explanation = .preparing("Preparing the local model…")
            }
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return false }
            if Task.isCancelled { return false }
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
