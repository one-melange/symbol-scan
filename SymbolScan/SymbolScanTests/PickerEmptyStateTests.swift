import Testing
import Foundation
@testable import SymbolScan

@Suite struct PickerEmptyStateTests {

    private let repo = URL(fileURLWithPath: "/tmp/my-repo")

    @Test func noRepoPointsAtARealAffordance() {
        let copy = PickerEmptyState.copy(repoRoot: nil, symbolCount: 0,
                                         isIndexing: false, query: "", error: nil)
        #expect(copy.title == "No repo selected")
        // Regression guard for the old lying copy: the hint must name a control that exists.
        let hint = try? #require(copy.hint)
        #expect(hint?.contains("⌘O") == true || hint?.contains("menu-bar") == true)
        // And it must not claim the old, nonexistent "menu bar icon" wording verbatim.
        #expect(copy.hint?.contains("Index a repo via the menu bar icon") != true)
    }

    @Test func indexingShowsRepoName() {
        let copy = PickerEmptyState.copy(repoRoot: repo, symbolCount: 0,
                                         isIndexing: true, query: "", error: nil)
        #expect(copy.title == "Indexing my-repo…")
        #expect(copy.hint == nil)
    }

    @Test func errorSurfacesTheMessageAsHint() {
        let copy = PickerEmptyState.copy(repoRoot: repo, symbolCount: 0,
                                         isIndexing: false, query: "", error: "Not a git repository")
        #expect(copy.title == "Couldn't index my-repo")
        #expect(copy.hint == "Not a git repository")
    }

    @Test func indexedButNoResultsEchoesQuery() {
        let copy = PickerEmptyState.copy(repoRoot: repo, symbolCount: 120,
                                         isIndexing: false, query: "zzz", error: nil)
        #expect(copy.title == "No results for \"zzz\"")
        #expect(copy.hint == nil)
    }

    @Test func fourStatesProduceDistinctCopy() {
        let noRepo = PickerEmptyState.copy(repoRoot: nil, symbolCount: 0, isIndexing: false, query: "", error: nil)
        let indexing = PickerEmptyState.copy(repoRoot: repo, symbolCount: 0, isIndexing: true, query: "", error: nil)
        let error = PickerEmptyState.copy(repoRoot: repo, symbolCount: 0, isIndexing: false, query: "", error: "boom")
        let noHits = PickerEmptyState.copy(repoRoot: repo, symbolCount: 5, isIndexing: false, query: "q", error: nil)
        #expect(Set([noRepo.title, indexing.title, error.title, noHits.title]).count == 4)
    }
}
