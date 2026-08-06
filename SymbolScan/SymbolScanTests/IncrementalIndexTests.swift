import Testing
import Foundation
@testable import SymbolScan

/// Covers `Indexer.reindexFiles` — the per-file incremental splice behind reindex-on-save (T4) —
/// and, since T23, the journal persistence it feeds: `reindexFiles` now returns `(symbols, patch)`
/// and does no IO; the caller appends the patch to the log, which `loadCache` replays over the base.
///
/// Like `IndexerTests`, these run against a real temp git repo with real grammars and real IO on
/// purpose: the value being tested is that a targeted reparse (and its replayed patch) stays
/// consistent with what a full scan would produce (membership, ranking order, dedup, dropped
/// deletions). The FSEvents watcher and the debounce timer are deliberately not tested — all of the
/// decision logic (`isExcluded`, membership, splice, `normalize`, replay) lives in pure code
/// exercised here, so no flaky filesystem-event or timer timing is needed.
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

        let (updated, patch) = await Indexer.reindexFiles(["New.swift"], root: root, existing: existing)
        #expect(updated.contains { $0.name == "brandNew" && $0.kind == .function })
        #expect(updated.contains { $0.name == "New.swift" && $0.kind == .file })
        // Untouched files keep their symbols.
        #expect(updated.contains { $0.name == "appMain" && $0.kind == .function })
        #expect(updated.contains { $0.name == "helper" && $0.kind == .function })
        // The patch carries only the changed file: its path, its code symbol, and its `.file` entry.
        #expect(patch.paths == ["New.swift"])
        #expect(patch.symbols.contains { $0.name == "brandNew" })
        #expect(patch.symbols.contains { $0.name == "New.swift" && $0.kind == .file })
        #expect(!patch.symbols.contains { $0.name == "appMain" })   // untouched files are NOT in the patch
    }

    @Test func modifyReplacesTheFilesSymbols() async throws {
        let (root, cacheBase, existing) = try await seededRepo()
        defer { cleanUp(root, cacheBase) }
        try TestSupport.write("func appMainRenamed() {}", to: "App.swift", in: root)

        let (updated, _) = await Indexer.reindexFiles(["App.swift"], root: root, existing: existing)
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
        let (updated, patch) = await Indexer.reindexFiles(["lib/util.swift"], root: root, existing: existing)
        #expect(!updated.contains { $0.name == "helper" })
        #expect(!updated.contains { $0.filePath == "lib/util.swift" })          // code + .file entry gone
        #expect(!updated.contains { $0.name == "lib" && $0.kind == .directory }) // last file gone → dir gone
        #expect(updated.contains { $0.name == "appMain" })                       // untouched
        // A deletion still names the path (so replay removes it) but contributes no symbols.
        #expect(patch.paths == ["lib/util.swift"])
        #expect(patch.symbols.isEmpty)
    }

    // MARK: - Membership must match a full scan

    @Test func gitignoredFileIsNotIndexed() async throws {
        let (root, cacheBase, existing) = try await seededRepo()
        defer { cleanUp(root, cacheBase) }
        try TestSupport.write("secret/\n", to: ".gitignore", in: root)
        try TestSupport.write("func secretFn() {}", to: "secret/hidden.swift", in: root)

        let (updated, _) = await Indexer.reindexFiles(["secret/hidden.swift"], root: root, existing: existing)
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

        let (updated, _) = await Indexer.reindexFiles(["Huge.swift"], root: root, existing: existing)
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

        let (updated, _) = await Indexer.reindexFiles(["feature/New.swift"], root: root, existing: existing)
        let firstPath = try #require(updated.firstIndex { $0.kind == .file || $0.kind == .directory })
        let lastCode = try #require(updated.lastIndex { $0.kind != .file && $0.kind != .directory })
        #expect(lastCode < firstPath)

        let keys = updated.map { "\($0.name)|\($0.filePath)|\($0.line)" }
        #expect(Set(keys).count == keys.count)
        // The new directory entry is derived, not left stale.
        #expect(updated.contains { $0.name == "feature" && $0.kind == .directory })
    }

    /// Appending the returned patch to the log and reloading reconstructs exactly the spliced array —
    /// this is the on-disk half: `loadCache` = base + replayed log, `normalize`d.
    @Test func patchAppendedToLogReplaysOnLoad() async throws {
        let (root, cacheBase, existing) = try await seededRepo()
        defer { cleanUp(root, cacheBase) }
        try TestSupport.write("func brandNew() {}", to: "New.swift", in: root)

        let (updated, patch) = await Indexer.reindexFiles(["New.swift"], root: root, existing: existing)
        IndexCache.appendPatches([patch], for: root, base: cacheBase)   // what SymbolIndex's flush does

        let loaded = try #require(await Indexer.loadCache(root: root, cacheBase: cacheBase)).symbols
        // Full equivalence: same entries in the same canonical order (not just the same name set).
        #expect(loaded.map { "\($0.name)|\($0.filePath)|\($0.kind.rawValue)" }
                == updated.map { "\($0.name)|\($0.filePath)|\($0.kind.rawValue)" })
    }

    /// The linchpin: a *sequence* of incremental edits, persisted as appended patches and replayed on
    /// load, yields the same index as a full `buildIndex` of the final tree — proving replay ⇒
    /// full-scan-identical (ordering and all).
    @Test func replayedLogEqualsAFullScanOfTheFinalTree() async throws {
        let (root, cacheBase, existing) = try await seededRepo()
        defer { cleanUp(root, cacheBase) }

        // A burst of edits: add, modify, add-nested, delete — each appended as its own patch.
        try TestSupport.write("func added() {}", to: "Added.swift", in: root)
        try TestSupport.write("func appMain2() {}", to: "App.swift", in: root)
        try TestSupport.write("func deep() {}", to: "a/b/Deep.swift", in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("lib/util.swift"))

        var symbols = existing
        for change in ["Added.swift", "App.swift", "a/b/Deep.swift", "lib/util.swift"] {
            let (updated, patch) = await Indexer.reindexFiles([change], root: root, existing: symbols)
            symbols = updated
            IndexCache.appendPatches([patch], for: root, base: cacheBase)
        }

        let replayed = try #require(await Indexer.loadCache(root: root, cacheBase: cacheBase)).symbols
        // A fresh full scan of the same on-disk tree (writes a new base under a separate cache base).
        let fresh = try TestSupport.makeTempDir(prefix: "ss-incr-fresh")
        defer { cleanUp(fresh) }
        let full = try await Indexer.buildIndex(root: root, cacheBase: fresh).symbols

        func key(_ s: Symbol) -> String { "\(s.name)|\(s.filePath)|\(s.kind.rawValue)|\(s.line)" }
        #expect(replayed.map(key) == full.map(key))   // identical order + content
    }

    /// A single `reindexFiles` call covering MULTIPLE changed files must land in the same canonical
    /// order as a full scan. `reindexFiles` iterates a `Set`, so without `normalize`'s within-group
    /// sort the code symbols would append in hash-dependent order and diverge from a full scan
    /// (changing empty-query / equal-score ranking). The per-file linchpin test can't catch this.
    @Test func multiFileBatchMatchesFullScanOrder() async throws {
        let (root, cacheBase, existing) = try await seededRepo()
        defer { cleanUp(root, cacheBase) }

        // Deliberately non-alphabetical creation; spliced all at once in ONE batch.
        try TestSupport.write("func alpha() {}", to: "z/Alpha.swift", in: root)
        try TestSupport.write("func beta() {}",  to: "a/Beta.swift",  in: root)
        try TestSupport.write("func gamma() {}", to: "m/Gamma.swift", in: root)

        let batch: Set<String> = ["z/Alpha.swift", "a/Beta.swift", "m/Gamma.swift"]
        let (spliced, _) = await Indexer.reindexFiles(batch, root: root, existing: existing)

        let fresh = try TestSupport.makeTempDir(prefix: "ss-incr-multi-fresh")
        defer { cleanUp(fresh) }
        let full = try await Indexer.buildIndex(root: root, cacheBase: fresh).symbols

        func key(_ s: Symbol) -> String { "\(s.name)|\(s.filePath)|\(s.kind.rawValue)|\(s.line)" }
        #expect(spliced.map(key) == full.map(key))   // identical canonical order, not just same set
    }

    /// An empty change set is a no-op: unchanged symbols, and a patch that names nothing (so the
    /// caller appends nothing).
    @Test func emptyChangeSetIsANoOp() async throws {
        let (root, cacheBase, existing) = try await seededRepo()
        defer { cleanUp(root, cacheBase) }
        let (updated, patch) = await Indexer.reindexFiles([], root: root, existing: existing)
        #expect(updated.map(\.name) == existing.map(\.name))
        #expect(patch.paths.isEmpty)
        #expect(patch.symbols.isEmpty)
    }
}
