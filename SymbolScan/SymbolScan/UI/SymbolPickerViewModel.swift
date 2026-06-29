import SwiftUI
import Combine

/// Holds the picker's mutable state in a reference type so a window-level key
/// monitor can read/write the *live* values (a SwiftUI `@State` would be captured
/// stale at install time).
@MainActor
final class SymbolPickerViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var results: [Symbol] = []
    @Published var selectedIndex: Int = 0

    let index: SymbolIndex

    init(index: SymbolIndex) {
        self.index = index
        self.results = index.search("")
    }

    func updateQuery(_ q: String) {
        query = q
        results = index.search(q)
        selectedIndex = 0
    }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + results.count) % results.count
    }

    /// The name of the currently selected symbol, or nil if nothing is selected.
    func selectedSymbolName() -> String? {
        guard selectedIndex < results.count else { return nil }
        return results[selectedIndex].name
    }
}
