import Testing
import Foundation
@testable import SymbolScan

/// Covers `Indexer.buildIndex` — the scan → parse → dedup → cache composition (T22). Every piece it
/// calls is unit-tested elsewhere; what's tested *here* is that they compose. That distinction is
/// not academic: the minified-bundle bug (T8) slipped through with every individual unit behaving
/// correctly, and only showed up when the whole pipeline ran against a real repo.
///
/// So these run against a real temp git repo with real grammars and real file IO, deliberately —
/// mocking the scanner would just re-test the units. The only seam is `cacheBase:`, which keeps the
/// cache write out of the user's Application Support directory.
@Suite struct IndexerTests {

    /// Longest line in the fake Vite bundle, comfortably past `SymbolParser.minifiedLineThreshold`.
    private static let bundleDeclarations = 400

    /// A git repo covering every dialect, a non-source file, a nested directory, and a minified
    /// bundle whose *name* looks like ordinary source (Vite emits `index-<hash>.js`, so the
    /// name-level screen in `Language.detect` can't catch it — only the content check can).
    private func makeFixtureRepo() throws -> URL {
        let root = try TestSupport.makeTempDir(prefix: "ss-indexer")
        try TestSupport.runGit(["init", "-q"], in: root)

        try TestSupport.write("func appMain() {}", to: "App.swift", in: root)
        try TestSupport.write("""
        package main

        type Server struct{}

        func (s *Server) Close() {}
        """, to: "server.go", in: root)
        try TestSupport.write("export const Widget = () => <div />;", to: "ui/Widget.tsx", in: root)
        try TestSupport.write("export function helper() {}", to: "util.js", in: root)
        try TestSupport.write("# notes", to: "README.md", in: root)

        let bundle = (0..<Self.bundleDeclarations).map { "function m\($0)(a,b){return a+b}" }.joined()
        #expect(bundle.count > SymbolParser.minifiedLineThreshold)
        try TestSupport.write(bundle, to: "assets/index-DJ7HgGZS.js", in: root)

        return root
    }

    /// Runs a full build with the cache redirected into its own temp dir. Returns the result plus
    /// both directories so a test can inspect the cache and clean up.
    private func build() async throws -> (result: Indexer.Result, root: URL, cacheBase: URL) {
        let root = try makeFixtureRepo()
        let cacheBase = try TestSupport.makeTempDir(prefix: "ss-indexer-cache")
        let result = try await Indexer.buildIndex(root: root, cacheBase: cacheBase)
        return (result, root, cacheBase)
    }

    private func cleanUp(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Composition

    @Test func buildsSymbolsFromEveryDialectInOneRepo() async throws {
        let (result, root, cacheBase) = try await build()
        defer { cleanUp(root, cacheBase) }
        let s = result.symbols

        // One pass over a mixed repo yields symbols from every grammar — the whole point of the
        // per-file (not per-repo) language routing.
        #expect(s.contains { $0.name == "appMain" && $0.kind == .function })
        #expect(s.contains { $0.name == "Server" && $0.kind == .struct })
        #expect(s.contains { $0.name == "Close" && $0.kind == .method })
        #expect(s.contains { $0.name == "Widget" && $0.kind == .function })
        #expect(s.contains { $0.name == "helper" && $0.kind == .function })
    }

    @Test func goReceiverSignatureSurvivesTheFullPipeline() async throws {
        let (result, root, cacheBase) = try await build()
        defer { cleanUp(root, cacheBase) }
        let close = try #require(result.symbols.first { $0.name == "Close" })
        #expect(close.signature == "(*Server) Close")
    }

    @Test func symbolsCarryRepoRelativePaths() async throws {
        let (result, root, cacheBase) = try await build()
        defer { cleanUp(root, cacheBase) }
        // T2's regression: paths must be repo-relative, not bare filenames or absolute.
        let widget = try #require(result.symbols.first { $0.name == "Widget" && $0.kind == .function })
        #expect(widget.filePath == "ui/Widget.tsx")
    }

    // MARK: - Minified bundles (T8)

    /// The regression that matters. Two committed 4.9 MB Vite bundles once contributed 16,901 junk
    /// symbols to a real index; no unit test caught it because each unit was correct in isolation.
    /// The bundle must yield **no code symbols** while still being reachable as a file entry.
    @Test func skipsMinifiedSourcesEndToEnd() async throws {
        let (result, root, cacheBase) = try await build()
        defer { cleanUp(root, cacheBase) }

        let fromBundle = result.symbols.filter {
            $0.filePath == "assets/index-DJ7HgGZS.js" && $0.kind != .file && $0.kind != .directory
        }
        #expect(fromBundle.isEmpty, "minified bundle leaked \(fromBundle.count) symbols")
        #expect(!result.symbols.contains { $0.name == "m0" })   // a mangled name from inside it

        // Still indexed as a file, so the path itself remains searchable/injectable.
        #expect(result.symbols.contains { $0.name == "index-DJ7HgGZS.js" && $0.kind == .file })
    }

    // MARK: - File / directory entries (T18)

    @Test func includesFileAndDirectoryEntries() async throws {
        let (result, root, cacheBase) = try await build()
        defer { cleanUp(root, cacheBase) }
        let s = result.symbols

        // Every repo file, including ones no grammar parses.
        #expect(s.contains { $0.name == "README.md" && $0.kind == .file })
        #expect(s.contains { $0.name == "App.swift" && $0.kind == .file })
        // Directories are derived, not enumerated.
        #expect(s.contains { $0.name == "ui" && $0.kind == .directory })
        #expect(s.contains { $0.name == "assets" && $0.kind == .directory })
    }

    /// Pins the ordering `Indexer` documents: code symbols are appended *before* file/directory
    /// entries so an exact-name symbol outranks a same-named path in the picker.
    @Test func codeSymbolsPrecedeFileAndDirectoryEntries() async throws {
        let (result, root, cacheBase) = try await build()
        defer { cleanUp(root, cacheBase) }

        let firstPathEntry = try #require(
            result.symbols.firstIndex { $0.kind == .file || $0.kind == .directory })
        let lastCodeSymbol = try #require(
            result.symbols.lastIndex { $0.kind != .file && $0.kind != .directory })
        #expect(lastCodeSymbol < firstPathEntry)
    }

    @Test func fileCountCountsSourceFilesOnly() async throws {
        let (result, root, cacheBase) = try await build()
        defer { cleanUp(root, cacheBase) }
        // App.swift, server.go, ui/Widget.tsx, util.js, assets/index-DJ7HgGZS.js — README.md is not
        // a source file. The bundle still counts: it's enumerated, just not parsed.
        #expect(result.fileCount == 5)
    }

    @Test func outputContainsNoDuplicates() async throws {
        let (result, root, cacheBase) = try await build()
        defer { cleanUp(root, cacheBase) }
        let keys = result.symbols.map { "\($0.name)|\($0.filePath)|\($0.line)" }
        #expect(Set(keys).count == keys.count)
    }

    // MARK: - Cache persistence (the seam)

    @Test func writesACacheThatLoadCacheReturns() async throws {
        let (result, root, cacheBase) = try await build()
        defer { cleanUp(root, cacheBase) }

        let loaded = try #require(await Indexer.loadCache(root: root, cacheBase: cacheBase))
        #expect(loaded.count == result.symbols.count)
        #expect(loaded.map(\.name) == result.symbols.map(\.name))

        // The write landed in the injected base and nowhere else.
        let written = try FileManager.default.contentsOfDirectory(atPath: cacheBase.path)
        #expect(written == [IndexCache.fileName(for: root)])
    }

    @Test func loadCacheReturnsNilForAnUnindexedRepo() async throws {
        let cacheBase = try TestSupport.makeTempDir(prefix: "ss-indexer-empty")
        defer { cleanUp(cacheBase) }
        let loaded = await Indexer.loadCache(root: URL(fileURLWithPath: "/tmp/never-indexed"),
                                             cacheBase: cacheBase)
        #expect(loaded == nil)
    }

    // MARK: - Failure and cancellation

    @Test func throwsNotGitRepoForPlainDirectory() async throws {
        let plain = try TestSupport.makeTempDir(prefix: "ss-indexer-nogit")
        let cacheBase = try TestSupport.makeTempDir(prefix: "ss-indexer-cache")
        defer { cleanUp(plain, cacheBase) }

        await #expect(throws: IndexError.notGitRepo) {
            _ = try await Indexer.buildIndex(root: plain, cacheBase: cacheBase)
        }
    }

    /// A forced re-index cancels the in-flight job for the same repo (T19), so `buildIndex` must
    /// honour cancellation rather than running to completion and overwriting the cache.
    @Test func cancellationStopsTheBuild() async throws {
        let root = try makeFixtureRepo()
        let cacheBase = try TestSupport.makeTempDir(prefix: "ss-indexer-cache")
        defer { cleanUp(root, cacheBase) }

        let task = Task { try await Indexer.buildIndex(root: root, cacheBase: cacheBase) }
        task.cancel()   // flag is set synchronously, before the body reaches any checkpoint

        await #expect(throws: CancellationError.self) { try await task.value }
        // Cancelled before the cache write, so nothing was persisted.
        #expect(await Indexer.loadCache(root: root, cacheBase: cacheBase) == nil)
    }
}
