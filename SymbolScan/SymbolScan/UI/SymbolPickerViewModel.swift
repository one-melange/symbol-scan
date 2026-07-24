import SwiftUI
import Combine

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

    let index: SymbolIndex

    init(index: SymbolIndex) {
        self.index = index
        self.results = index.search("")
    }

    /// Apply a new search string and recompute results synchronously. Called from the
    /// search field's `controlTextDidChange`, so there's no need to defer through Combine.
    func updateQuery(_ newValue: String) {
        guard newValue != query else { return }
        query = newValue
        results = index.search(newValue)
        selectedIndex = 0
    }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + results.count) % results.count
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
