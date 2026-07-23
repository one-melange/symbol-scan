import Testing
import Foundation
@testable import SymbolScan

@Suite struct StatusMenuTitleTests {

    private let repo = URL(fileURLWithPath: "/tmp/my-repo")

    @Test func noRepo() {
        #expect(StatusMenuModel.title(repo: nil, count: 0, isIndexing: false, error: nil)
                == "No repo selected")
    }

    @Test func indexingTakesPrecedenceOverCount() {
        #expect(StatusMenuModel.title(repo: repo, count: 10, isIndexing: true, error: nil)
                == "Indexing my-repo…")
    }

    @Test func indexedShowsCount() {
        #expect(StatusMenuModel.title(repo: repo, count: 42, isIndexing: false, error: nil)
                == "my-repo — 42 symbols")
    }

    @Test func errorShowsMessage() {
        #expect(StatusMenuModel.title(repo: repo, count: 0, isIndexing: false, error: "Not a git repository")
                == "my-repo: Not a git repository")
    }
}
