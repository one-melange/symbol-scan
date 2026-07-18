import Foundation
import Combine

@MainActor
class SymbolIndex: ObservableObject {

    @Published var isIndexing: Bool = false
    @Published var indexedRepoRoot: URL?
    @Published private(set) var symbolCount: Int = 0

    private var symbols: [Symbol] = []
    private var scanner: RepoScanner?

    // MARK: - Indexing

    func index(repoRoot: URL) async {
        guard !isIndexing else { return }
        isIndexing = true
        defer { isIndexing = false }

        let s = RepoScanner(root: repoRoot)
        guard s.isGitRepo else {
            print("⚠️ Not a git repo: \(repoRoot.path)")
            return
        }
        self.scanner = s

        do {
            let files = try await s.enumerateSourceFiles()
            print("📁 Found \(files.count) files: \(files.map(\.lastPathComponent))")
            var collected: [Symbol] = []

            for url in files {
                guard let lang = Language.detect(from: url) else { continue }
                let relPath = s.relativePath(for: url)
                let fileSymbols = (try? RegexParser.parse(url: url, language: lang, relativePath: relPath)) ?? []
                collected.append(contentsOf: fileSymbols)
            }

            // Drop accidental duplicates (e.g. the same file enumerated twice).
            var seen = Set<String>()
            let deduped = collected.filter { sym in
                seen.insert("\(sym.name)|\(sym.filePath)|\(sym.line)").inserted
            }

            self.symbols = deduped
            self.symbolCount = deduped.count
            self.indexedRepoRoot = repoRoot
            print("✅ Indexed \(deduped.count) symbols across \(files.count) files in \(repoRoot.lastPathComponent)")
        } catch {
            print("❌ Indexing error: \(error)")
        }
    }

    /// Re-index a single file (call on file-save events)
    func reindexFile(url: URL) async {
        guard let scanner, let lang = Language.detect(from: url) else { return }
        let relPath = scanner.relativePath(for: url)

        // Remove old symbols from this file
        symbols.removeAll { $0.filePath == relPath }

        // Re-parse
        if let fresh = try? RegexParser.parse(url: url, language: lang, relativePath: relPath) {
            symbols.append(contentsOf: fresh)
            symbolCount = symbols.count
        }
    }

    // MARK: - Search

    /// Strict-substring symbol search — returns the top 10 results ranked by score.
    /// Ranking/matching lives in `SymbolMatcher` so it can be unit-tested in isolation.
    func search(_ query: String) -> [Symbol] {
        let results = SymbolMatcher.search(query, in: symbols)
        #if DEBUG
        print("🔎 search(\"\(query)\") → \(results.count): \(results.map(\.name))")
        #endif
        return results
    }

    #if DEBUG
    /// Seed a known symbol set for tests, bypassing git/async indexing.
    func loadForTesting(_ symbols: [Symbol]) {
        self.symbols = symbols
        self.symbolCount = symbols.count
    }
    #endif
}

// MARK: - Matching

/// Pure, dependency-free symbol matching/ranking. Lives here (rather than its own file) so
/// it builds without a project-file edit, but it is intentionally free of `SymbolIndex`'s
/// `@MainActor`/IO so it can be unit-tested in isolation.
///
/// Semantics are strict substring ("contains"): a symbol matches only when the lowercased
/// query appears as a contiguous run inside the lowercased name. There is intentionally no
/// scattered-subsequence fallback (it surfaced surprising results like "selectedText" for
/// the query "set").
enum SymbolMatcher {

    /// Returns the best `limit` symbols for `query`, ranked by `score` descending.
    /// An empty query returns the first `limit` symbols unranked.
    static func search(_ query: String, in symbols: [Symbol], limit: Int = 10) -> [Symbol] {
        guard !query.isEmpty else {
            return Array(symbols.prefix(limit))
        }
        let q = query.lowercased()
        return symbols
            .compactMap { sym -> (Symbol, Int)? in
                let s = score(query: q, candidate: sym.name.lowercased())
                return s > 0 ? (sym, s) : nil
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Scores how well `query` matches `candidate`. Both are expected to already be
    /// lowercased. Higher = better. 0 = no match (query is not a substring).
    static func score(query: String, candidate: String) -> Int {
        // Exact match
        if candidate == query { return 1000 }

        // Exact prefix
        if candidate.hasPrefix(query) { return 800 }

        // Contiguous substring — earlier matches score higher.
        if let r = candidate.range(of: query) {
            let offset = candidate.distance(from: candidate.startIndex, to: r.lowerBound)
            return max(700 - offset * 2, 500)
        }

        // Not a substring → no match.
        return 0
    }
}
