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
                let fileSymbols = (try? RegexParser.parse(url: url, language: lang)) ?? []
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
        if let fresh = try? RegexParser.parse(url: url, language: lang) {
            let stamped = fresh.map { sym in
                Symbol(name: sym.name, kind: sym.kind, filePath: relPath, line: sym.line, signature: sym.signature)
            }
            symbols.append(contentsOf: stamped)
            symbolCount = symbols.count
        }
    }

    // MARK: - Search

    /// Fuzzy symbol search — returns top 10 results sorted by score.
    func search(_ query: String) -> [Symbol] {
        guard !query.isEmpty else {
            return Array(symbols.prefix(10))
        }
        let q = query.lowercased()
        let results = symbols
            .compactMap { sym -> (Symbol, Int)? in
                let score = fuzzyScore(q, sym.name.lowercased())
                return score > 0 ? (sym, score) : nil
            }
            .sorted { $0.1 > $1.1 }
            .prefix(10)
            .map(\.0)
        #if DEBUG
        print("🔎 search(\"\(query)\") → \(results.count): \(results.map(\.name))")
        #endif
        return results
    }

    // MARK: - Fuzzy scoring

    /// Scores how well `query` matches `candidate` using strict substring ("contains")
    /// semantics. Higher = better match. 0 = no match (query is not a substring).
    private func fuzzyScore(_ query: String, _ candidate: String) -> Int {
        // Exact match
        if candidate == query { return 1000 }

        // Exact prefix
        if candidate.hasPrefix(query) { return 800 }

        // Contiguous substring — earlier matches score higher.
        if let r = candidate.range(of: query) {
            let offset = candidate.distance(from: candidate.startIndex, to: r.lowerBound)
            return max(700 - offset * 2, 500)
        }

        // Not a substring → no match. (No scattered-subsequence fallback: it surfaced
        // surprising results like "selectedText" for the query "set".)
        return 0
    }
}
