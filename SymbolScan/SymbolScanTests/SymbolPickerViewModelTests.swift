import Testing
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

    @Test func selectedSymbolNameTracksArrowNavigation() {
        let vm = makeVM(["alpha", "alphabet", "alpine"])
        vm.updateQuery("al")
        vm.moveSelection(1)
        vm.moveSelection(1)
        #expect(vm.selectedIndex == 2)
        #expect(vm.selectedSymbolName() == vm.results[2].name)
    }
}
