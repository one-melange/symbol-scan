import SwiftUI
import Combine

/// Holds the picker's mutable state in a reference type so key handlers can read/write
/// the *live* values (a SwiftUI `@State` would be captured stale at install time).
@MainActor
final class SymbolPickerViewModel: ObservableObject {
    /// Bound directly to the search `TextField`. Never reassign this yourself — doing so
    /// from a view callback is a re-entrant publish and breaks the field's display.
    @Published var query: String = ""
    @Published private(set) var results: [Symbol] = []
    @Published var selectedIndex: Int = 0

    let index: SymbolIndex
    private var cancellables = Set<AnyCancellable>()

    init(index: SymbolIndex) {
        self.index = index
        self.results = index.search("")

        // Recompute results whenever the query changes. `.receive(on:)` defers the
        // results/selectedIndex mutations to the next runloop tick, so they never fire
        // *inside* a SwiftUI view update ("Publishing changes from within view updates").
        $query
            .removeDuplicates()
            .dropFirst()                       // skip the initial "" (already searched above)
            .receive(on: RunLoop.main)
            .sink { [weak self] q in
                guard let self else { return }
                self.results = self.index.search(q)
                self.selectedIndex = 0
            }
            .store(in: &cancellables)
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
