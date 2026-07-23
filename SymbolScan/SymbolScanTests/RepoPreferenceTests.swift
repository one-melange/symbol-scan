import Testing
import Foundation
@testable import SymbolScan

@Suite struct RepoPreferenceTests {

    /// A throwaway UserDefaults suite so tests never touch the real `.standard` domain.
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SymbolScanTests.\(UUID().uuidString)")!
    }

    // MARK: - decodePath (pure)

    @Test func decodePathRejectsNilEmptyAndWhitespace() {
        #expect(RepoPreference.decodePath(nil, isDirectory: { _ in true }) == nil)
        #expect(RepoPreference.decodePath("", isDirectory: { _ in true }) == nil)
        #expect(RepoPreference.decodePath("   \n", isDirectory: { _ in true }) == nil)
    }

    @Test func decodePathRejectsNonDirectory() {
        // Simulates a repo that was deleted/moved since it was persisted.
        #expect(RepoPreference.decodePath("/gone/repo", isDirectory: { _ in false }) == nil)
    }

    @Test func decodePathAcceptsExistingDirectory() {
        let url = RepoPreference.decodePath("/tmp/repo", isDirectory: { $0 == "/tmp/repo" })
        #expect(url?.path == "/tmp/repo")
    }

    // MARK: - UserDefaults round-trips

    @Test func setActivePersistsActiveAndRecents() {
        let d = makeDefaults()
        let repo = URL(fileURLWithPath: NSTemporaryDirectory())
        RepoPreference.setActive(repo, in: d)

        #expect(d.string(forKey: RepoPreference.activeKey) == repo.path)
        #expect(RepoPreference.loadRecents(from: d).map(\.path).contains(repo.path))
    }

    @Test func recentsAreMostRecentFirstDeDupedAndCapped() {
        let d = makeDefaults()
        // Use real temp subdirs so `loadRecents`' directory check passes.
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
        var made: [URL] = []
        for i in 0..<(RepoPreference.recentsLimit + 3) {
            let u = base.appendingPathComponent("rp-\(UUID().uuidString)-\(i)")
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            made.append(u)
            RepoPreference.setActive(u, in: d)
        }
        defer { made.forEach { try? FileManager.default.removeItem(at: $0) } }

        let recents = RepoPreference.loadRecents(from: d)
        #expect(recents.count == RepoPreference.recentsLimit)          // capped
        #expect(recents.first?.path == made.last?.path)               // most-recent-first

        // Re-activating an existing repo de-dups rather than adding a second entry.
        RepoPreference.setActive(made.last!, in: d)
        let paths = RepoPreference.loadRecents(from: d).map(\.path)
        #expect(paths.filter { $0 == made.last!.path }.count == 1)
    }

    @Test func clearRemovesFromActiveAndRecents() {
        let d = makeDefaults()
        let repo = URL(fileURLWithPath: NSTemporaryDirectory())
        RepoPreference.setActive(repo, in: d)
        RepoPreference.clear(repo, from: d)

        #expect(d.string(forKey: RepoPreference.activeKey) == nil)
        #expect(!RepoPreference.loadRecents(from: d).map(\.path).contains(repo.path))
    }
}
