import Testing
import Foundation
@testable import SymbolScan

/// Covers `Indexer.reindexFiles` — the per-file incremental splice behind reindex-on-save (T4).
///
/// Like `IndexerTests`, these run against a real temp git repo with real grammars and real IO on
/// purpose: the value being tested is that a targeted reparse stays consistent with what a full
/// scan would produce (membership, ranking order, dedup, dropped deletions). The FSEvents watcher
/// itself is deliberately not tested — all of its decision logic (`isExcluded`, membership, splice,
/// drain) lives in pure/off-watcher code exercised here, so no flaky filesystem-event timing is
/// needed. The only seam is `cacheBase:`, keeping the cache write out of Application Support.
@Suite struct IncrementalIndexTests {

    /// A real git repo with two source files (one nested) already built into an index. Returns the
    /// initial symbols plus both temp dirs so a test can splice against them and clean up.
    private func seededRepo() async throws -> (root: URL, cacheBase: URL, symbols: [Symbol]) {
        let root = try TestSupport.makeTempDir(prefix: "ss-incr")
        try TestSupport.runGit(["init", "-q"], in: root)
        try TestSupport.write("func appMain() {}", to: "App.swift", in: root)
        try TestSupport.write("func helper() {}", to: "lib/util.swift", in: root)

        let cacheBase = try TestSupport.makeTempDir(prefix: "ss-incr-cache")
        let result = try await Indexer.buildIndex(root: root, cacheBase: cacheBase)
        return (root, cacheBase, result.symbols)
    }

    private func cleanUp(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Add / modify / delete

    /// A brand-new, never-git-added file is picked up (the whole point: an agent just created it).
    /// `runGit` only does `init`, so every fixture file here is untracked — this is the untracked case.
    @Test func addsSymbolsForANewUntrackedFile() async throws {
        let (root, cacheBase, existing) = try await seededRepo()
        defer { cleanUp(root, cacheBase) }
        try TestSupport.write("func brandNew() {}", to: "New.swift", in: root)

        let updated = await Indexer.reindexFiles(["New.swift"], root: root,
                                                 existing: existing, cacheBase: cacheBase)
        #expect(updated.contains { $0.name == "brandNew" && $0.kind == .function })
        #expect(updated.contains { $0.name == "New.swift" && $0.kind == .file })
        // Untouched files keep their symbols.
        #expect(updated.contains { $0.name == "appMain" && $0.kind == .function })
        #expect(updated.contains { $0.name == "helper" && $0.kind == .function })
    }

    @Test func modifyReplacesTheFilesSymbols() async throws {
        let (root, cacheBase, existing) = try await seededRepo()
        defer { cleanUp(root, cacheBase) }
        try TestSupport.write("func appMainRenamed() {}", to: "App.swift", in: root)

        let updated = await Indexer.reindexFiles(["App.swift"], root: root,
                                                 existing: existing, cacheBase: cacheBase)
        #expect(updated.contains { $0.name == "appMainRenamed" })
        #expect(!updated.contains { $0.name == "appMain" })          // old symbol gone
        #expect(updated.contains { $0.name == "helper" })            // other file untouched
        #expect(updated.filter { $0.name == "App.swift" && $0.kind == .file }.count == 1)  // no dup file entry
    }

    @Test func deleteRemovesSymbolsAndTheNowEmptyDirectory() async throws {
        let (root, cacheBase, existing) = try await seededRepo()
        defer { cleanUp(root, cacheBase) }
        // Precondition: the seeded index has the nested file's symbol and a `lib` directory entry.
        #expect(existing.contains { $0.name == "helper" })
        #expect(existing.contains { $0.name == "lib" && $0.kind == .directory })

        try FileManager.default.removeItem(at: root.appendingPathComponent("lib/util.swift"))
        let updated = await Indexer.reindexFiles(["lib/util.swift"], root: root,
                                                 existing: existing, cacheBase: cacheBase)
        #expect(!updated.contains { $0.name == "helper" })
        #expect(!updated.contains { $0.filePath == "lib/util.swift" })          // code + .file entry gone
        #expect(!updated.contains { $0.name == "lib" && $0.kind == .directory }) // last file gone → dir gone
        #expect(updated.contains { $0.name == "appMain" })                       // untouched
    }

    // MARK: - Membership must match a full scan

    @Test func gitignoredFileIsNotIndexed() async throws {
        let (root, cacheBase, existing) = try await seededRepo()
        defer { cleanUp(root, cacheBase) }
        try TestSupport.write("secret/\n", to: ".gitignore", in: root)
        try TestSupport.write("func secretFn() {}", to: "secret/hidden.swift", in: root)

        let updated = await Indexer.reindexFiles(["secret/hidden.swift"], root: root,
                                                 existing: existing, cacheBase: cacheBase)
        #expect(!updated.contains { $0.name == "secretFn" })
        #expect(!updated.contains { $0.filePath == "secret/hidden.swift" })
    }

    /// A file above the byte cap is skipped by the parser but still recorded as a searchable `.file`
    /// entry — same contract as a minified bundle. The file is many short lines so only the byte cap
    /// (not `isMinified`) can catch it.
    @Test func oversizeFileGetsFileEntryButNoCodeSymbols() async throws {
        let (root, cacheBase, existing) = try await seededRepo()
        defer { cleanUp(root, cacheBase) }
        let big = (0..<150_000).map { "func f\($0)() {}" }.joined(separator: "\n")
        #expect(big.utf8.count > SymbolParser.maxParseFileSizeBytes)
        try TestSupport.write(big, to: "Huge.swift", in: root)

        let updated = await Indexer.reindexFiles(["Huge.swift"], root: root,
                                                 existing: existing, cacheBase: cacheBase)
        #expect(updated.contains { $0.name == "Huge.swift" && $0.kind == .file })            // searchable
        #expect(!updated.contains { $0.filePath == "Huge.swift" && $0.kind == .function })   // not parsed
    }

    // MARK: - Invariants + persistence

    /// The splice re-establishes the full-scan invariants: code symbols before file/dir entries, and
    /// no duplicate keys.
    @Test func preservesOrderingAndDedupAfterSplice() async throws {
        let (root, cacheBase, existing) = try await seededRepo()
        defer { cleanUp(root, cacheBase) }
        try TestSupport.write("func brandNew() {}", to: "feature/New.swift", in: root)

        let updated = await Indexer.reindexFiles(["feature/New.swift"], root: root,
                                                 existing: existing, cacheBase: cacheBase)
        let firstPath = try #require(updated.firstIndex { $0.kind == .file || $0.kind == .directory })
        let lastCode = try #require(updated.lastIndex { $0.kind != .file && $0.kind != .directory })
        #expect(lastCode < firstPath)

        let keys = updated.map { "\($0.name)|\($0.filePath)|\($0.line)" }
        #expect(Set(keys).count == keys.count)
        // The new directory entry is derived, not left stale.
        #expect(updated.contains { $0.name == "feature" && $0.kind == .directory })
    }

    @Test func reindexFilesPersistsToCache() async throws {
        let (root, cacheBase, existing) = try await seededRepo()
        defer { cleanUp(root, cacheBase) }
        try TestSupport.write("func brandNew() {}", to: "New.swift", in: root)

        let updated = await Indexer.reindexFiles(["New.swift"], root: root,
                                                 existing: existing, cacheBase: cacheBase)
        let loaded = try #require(await Indexer.loadCache(root: root, cacheBase: cacheBase))
        #expect(loaded.map(\.name).sorted() == updated.map(\.name).sorted())
    }

    /// An empty change set is a no-op that returns the input untouched (and doesn't rewrite the cache).
    @Test func emptyChangeSetIsANoOp() async throws {
        let (root, cacheBase, existing) = try await seededRepo()
        defer { cleanUp(root, cacheBase) }
        let updated = await Indexer.reindexFiles([], root: root, existing: existing, cacheBase: cacheBase)
        #expect(updated.map(\.name) == existing.map(\.name))
    }
}
