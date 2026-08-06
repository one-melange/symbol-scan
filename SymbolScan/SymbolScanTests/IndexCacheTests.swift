import Testing
import Foundation
@testable import SymbolScan

@Suite struct IndexCacheTests {

    private func sampleSymbols() -> [Symbol] {
        [
            Symbol(name: "SymbolIndex", kind: .class, filePath: "Index/SymbolIndex.swift", line: 5),
            Symbol(name: "activateRepo", kind: .method, filePath: "Index/SymbolIndex.swift", line: 30,
                   signature: "func activateRepo(_ repoRoot: URL) async"),
        ]
    }

    // MARK: - Pure codec

    @Test func encodeDecodeRoundTripsSymbols() throws {
        let symbols = sampleSymbols()
        let data = try #require(IndexCache.encode(symbols, repoPath: "/tmp/repo"))
        let decoded = try #require(IndexCache.decode(data))

        #expect(decoded.count == symbols.count)
        #expect(decoded.map(\.name) == symbols.map(\.name))
        #expect(decoded.map(\.kind) == symbols.map(\.kind))
        #expect(decoded.map(\.filePath) == symbols.map(\.filePath))
        #expect(decoded.map(\.line) == symbols.map(\.line))
        #expect(decoded[1].signature == "func activateRepo(_ repoRoot: URL) async")
    }

    @Test func decodeRejectsGarbage() {
        #expect(IndexCache.decode(Data("not json".utf8)) == nil)
    }

    @Test func decodeRejectsVersionMismatch() throws {
        // A payload tagged with a future version must be rejected so a stale format forces a rescan.
        let json = """
        {"version": 999, "repoPath": "/tmp/repo", "symbols": []}
        """
        #expect(IndexCache.decode(Data(json.utf8)) == nil)
    }

    // MARK: - Disk IO (injected base dir)

    @Test func saveThenLoadFromDisk() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ic-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }

        let repo = URL(fileURLWithPath: "/tmp/some/repo")
        let symbols = sampleSymbols()

        #expect(IndexCache.save(symbols, for: repo, base: base) == true)
        let loaded = try #require(IndexCache.load(for: repo, base: base))
        #expect(loaded.map(\.name) == symbols.map(\.name))
    }

    @Test func loadReturnsNilWhenAbsent() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ic-empty-\(UUID().uuidString)")
        #expect(IndexCache.load(for: URL(fileURLWithPath: "/tmp/nope"), base: base) == nil)
    }

    @Test func fileNameIsStableAndDistinctPerRepo() {
        let a = IndexCache.fileName(for: URL(fileURLWithPath: "/tmp/repo-a"))
        let b = IndexCache.fileName(for: URL(fileURLWithPath: "/tmp/repo-b"))
        #expect(a == IndexCache.fileName(for: URL(fileURLWithPath: "/tmp/repo-a"))) // stable
        #expect(a != b)                                                             // distinct
        #expect(a.hasSuffix(".json"))
    }

    // MARK: - Patch journal (T23)

    private func tempBase() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ic-log-\(UUID().uuidString)")
    }

    @Test func patchEncodeDecodeRoundTrips() throws {
        let patch = IndexCache.Patch(paths: ["A.swift", "gone.swift"], symbols: sampleSymbols())
        let data = try #require(IndexCache.encodePatch(patch))
        // One patch must serialize to a single line (the log is newline-delimited).
        #expect(!data.contains(0x0A))
        let decoded = try #require(IndexCache.decodePatch(data))
        #expect(decoded.paths == patch.paths)
        #expect(decoded.symbols.map(\.name) == patch.symbols.map(\.name))
    }

    @Test func appendThenLoadPatchesRoundTrips() {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = URL(fileURLWithPath: "/tmp/some/repo")

        let p1 = IndexCache.Patch(paths: ["A.swift"], symbols: [sampleSymbols()[0]])
        let p2 = IndexCache.Patch(paths: ["B.swift"], symbols: [sampleSymbols()[1]])
        #expect(IndexCache.appendPatches([p1], for: repo, base: base) == true)
        #expect(IndexCache.appendPatches([p2], for: repo, base: base) == true)   // second append extends

        let loaded = IndexCache.loadPatches(for: repo, base: base)
        #expect(loaded.count == 2)
        #expect(loaded[0].paths == ["A.swift"])   // order preserved
        #expect(loaded[1].paths == ["B.swift"])
    }

    @Test func loadPatchesSkipsATornTrailingLine() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = URL(fileURLWithPath: "/tmp/some/repo")

        IndexCache.appendPatches([IndexCache.Patch(paths: ["A.swift"], symbols: [])], for: repo, base: base)
        // Simulate a crash mid-append: a partial JSON line with no trailing newline.
        let url = try #require(IndexCache.logURL(for: repo, base: base))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"paths":["B.swift"],"sym"#.utf8))
        try handle.close()

        let loaded = IndexCache.loadPatches(for: repo, base: base)
        #expect(loaded.count == 1)                 // the good record survives
        #expect(loaded[0].paths == ["A.swift"])    // the torn one is dropped, not fatal
    }

    @Test func loadPatchesIsEmptyWhenNoLog() {
        let base = tempBase()
        #expect(IndexCache.loadPatches(for: URL(fileURLWithPath: "/tmp/nope"), base: base).isEmpty)
    }

    @Test func clearLogRemovesIt() {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = URL(fileURLWithPath: "/tmp/some/repo")

        IndexCache.appendPatches([IndexCache.Patch(paths: ["A.swift"], symbols: [])], for: repo, base: base)
        #expect(!IndexCache.loadPatches(for: repo, base: base).isEmpty)
        IndexCache.clearLog(for: repo, base: base)
        #expect(IndexCache.loadPatches(for: repo, base: base).isEmpty)
    }

    /// A crash can leave a torn final line in the log. A later append must not fuse onto it and
    /// corrupt its own first record — the torn fragment stays a separate (skipped) line.
    @Test func appendAfterATornTailStaysReadable() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = URL(fileURLWithPath: "/tmp/some/repo")

        IndexCache.appendPatches([IndexCache.Patch(paths: ["A.swift"], symbols: [])], for: repo, base: base)
        // Simulate a crash mid-append: a partial record with no trailing newline.
        let url = try #require(IndexCache.logURL(for: repo, base: base))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"paths":["B.swift"],"sym"#.utf8))
        try handle.close()

        IndexCache.appendPatches([IndexCache.Patch(paths: ["C.swift"], symbols: [])], for: repo, base: base)

        let loaded = IndexCache.loadPatches(for: repo, base: base)
        #expect(loaded.contains { $0.paths == ["A.swift"] })   // original survives
        #expect(loaded.contains { $0.paths == ["C.swift"] })   // new record readable, not corrupted
        #expect(!loaded.contains { $0.paths == ["B.swift"] })  // torn fragment still skipped
    }

    /// A `compact` bumps the repo's write generation; an append tagged with a pre-compact generation
    /// is dropped as superseded, so a stale incremental write can't land on top of a full reindex.
    @Test func compactSupersedesAStaleGenerationAppend() {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = URL(fileURLWithPath: "/tmp/gen/\(UUID().uuidString)")

        IndexCache.save([sampleSymbols()[0]], for: repo, base: base)
        let stale = IndexCache.generation(for: repo, base: base)
        IndexCache.compact(sampleSymbols(), for: repo, base: base)   // authoritative write bumps generation

        let superseded = IndexCache.appendPatches([IndexCache.Patch(paths: ["late.swift"], symbols: [])],
                                                  for: repo, base: base, ifGeneration: stale)
        #expect(superseded == false)
        #expect(IndexCache.loadPatches(for: repo, base: base).isEmpty)   // dropped, log stays clean

        // A write at the current generation still applies.
        let now = IndexCache.generation(for: repo, base: base)
        #expect(IndexCache.appendPatches([IndexCache.Patch(paths: ["ok.swift"], symbols: [])],
                                         for: repo, base: base, ifGeneration: now) == true)
        #expect(IndexCache.loadPatches(for: repo, base: base).count == 1)
    }

    @Test func compactWritesBaseAndClearsLog() {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = URL(fileURLWithPath: "/tmp/some/repo")

        // Seed a base and a non-empty log.
        IndexCache.save([sampleSymbols()[0]], for: repo, base: base)
        IndexCache.appendPatches([IndexCache.Patch(paths: ["A.swift"], symbols: [])], for: repo, base: base)

        #expect(IndexCache.compact(sampleSymbols(), for: repo, base: base) == true)
        // Base now holds the compacted array…
        let loadedBase = IndexCache.load(for: repo, base: base)
        #expect(loadedBase?.map(\.name) == sampleSymbols().map(\.name))
        // …and the log is gone.
        #expect(IndexCache.loadPatches(for: repo, base: base).isEmpty)
    }
}
