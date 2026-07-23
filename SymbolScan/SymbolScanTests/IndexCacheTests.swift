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
}
