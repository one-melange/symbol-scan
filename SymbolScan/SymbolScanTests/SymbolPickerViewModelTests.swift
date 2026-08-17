import Testing
import Foundation
@testable import SymbolScan

/// Drives the real view model + index through the picker flow (the logic behind the
/// substring / arrow-key / stale-selection bugs) without any UI or git/filesystem.
@MainActor @Suite struct SymbolPickerViewModelTests {

    private func makeVM(_ names: [String]) -> SymbolPickerViewModel {
        let index = SymbolIndex()
        index.loadForTesting(names.map {
            Symbol(name: $0, kind: .function, filePath: "f.swift", line: 1)
        })
        return SymbolPickerViewModel(index: index)
    }

    @Test func initShowsLeadingResults() {
        let vm = makeVM((0..<15).map { "sym\($0)" })
        #expect(vm.results.count == 10)
        #expect(vm.selectedIndex == 0)
    }

    @Test func updateQueryFiltersAndResetsSelection() {
        let vm = makeVM(["setValue", "reset", "unrelated"])
        vm.selectedIndex = 1
        vm.updateQuery("set")
        #expect(!vm.results.isEmpty)
        #expect(vm.results.allSatisfy { $0.name.lowercased().contains("set") })
        #expect(vm.selectedIndex == 0)
    }

    @Test func updateQuerySameValueIsNoOp() {
        let vm = makeVM(["setValue", "reset"])
        vm.updateQuery("set")
        let before = vm.results.map(\.id)
        vm.selectedIndex = 1
        vm.updateQuery("set")            // identical → dedup guard returns early
        #expect(vm.selectedIndex == 1)   // selection preserved
        #expect(vm.results.map(\.id) == before)
    }

    @Test func indexReplacementReappliesExistingQuery() {
        let index = SymbolIndex()
        let repoA = URL(fileURLWithPath: "/tmp/repo-a")
        let repoB = URL(fileURLWithPath: "/tmp/repo-b")
        index.loadForTesting([
            Symbol(name: "injectAlpha", kind: .function, filePath: "A.swift", line: 1),
            Symbol(name: "alphaOnly", kind: .function, filePath: "A.swift", line: 2),
        ], repoRoot: repoA)
        let vm = SymbolPickerViewModel(index: index)
        vm.updateQuery("inject")
        #expect(vm.results.map(\.name) == ["injectAlpha"])

        // The replacement deliberately has the same count as repo A. Refresh must be driven by
        // searchable content changing, not by a different symbol count.
        index.loadForTesting([
            Symbol(name: "injectBeta", kind: .function, filePath: "B.swift", line: 1),
            Symbol(name: "betaOnly", kind: .function, filePath: "B.swift", line: 2),
        ], repoRoot: repoB)

        #expect(vm.query == "inject")
        #expect(vm.results.map(\.name) == ["injectBeta"])
        #expect(vm.selectedIndex == 0)
    }

    @Test func indexReplacementClearsMatchesMissingFromNewRepo() {
        let index = SymbolIndex()
        index.loadForTesting([
            Symbol(name: "inject", kind: .function, filePath: "A.swift", line: 1)
        ])
        let vm = SymbolPickerViewModel(index: index)
        vm.updateQuery("inject")
        #expect(!vm.results.isEmpty)

        index.loadForTesting([
            Symbol(name: "unrelated", kind: .function, filePath: "B.swift", line: 1)
        ])

        #expect(vm.query == "inject")
        #expect(vm.results.isEmpty)
        #expect(vm.selectedSymbol() == nil)
    }

    @Test func moveSelectionWrapsBothDirections() {
        let vm = makeVM(["a", "ab", "abc"])
        vm.updateQuery("a")
        #expect(vm.results.count == 3)
        vm.moveSelection(-1)             // wrap up from 0 → last
        #expect(vm.selectedIndex == 2)
        vm.moveSelection(1)              // wrap down from last → 0
        #expect(vm.selectedIndex == 0)
    }

    @Test func moveSelectionOnEmptyIsNoOp() {
        let vm = makeVM(["abc"])
        vm.updateQuery("zzz")
        #expect(vm.results.isEmpty)
        vm.moveSelection(1)
        #expect(vm.selectedIndex == 0)
    }

    @Test func selectedSymbolTracksArrowNavigation() {
        let vm = makeVM(["alpha", "alphabet", "alpine"])
        vm.updateQuery("al")
        vm.moveSelection(1)
        vm.moveSelection(1)
        #expect(vm.selectedIndex == 2)
        #expect(vm.selectedSymbol()?.name == vm.results[2].name)
    }

    @Test func selectedInjectionTextComposesReference() {
        let index = SymbolIndex()
        index.loadForTesting([
            Symbol(name: "search", kind: .function, filePath: "Index/SymbolIndex.swift", line: 105)
        ])
        let vm = SymbolPickerViewModel(index: index)
        // Body only — the leading `@`/`#` prefix comes from the trigger key the user typed
        // (or is supplied by the overlay for ⌘⇧O), not from injectionText.
        #expect(vm.selectedInjectionText() == "Index/SymbolIndex.swift:105 search")
    }

    @Test func selectedInjectionTextNilWhenNoResults() {
        let vm = makeVM(["abc"])
        vm.updateQuery("zzz")
        #expect(vm.results.isEmpty)
        #expect(vm.selectedInjectionText() == nil)
    }
}
