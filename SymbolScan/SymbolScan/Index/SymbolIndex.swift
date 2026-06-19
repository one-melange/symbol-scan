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

            self.symbols = collected
            self.symbolCount = collected.count
            self.indexedRepoRoot = repoRoot
            print("✅ Indexed \(collected.count) symbols across \(files.count) files in \(repoRoot.lastPathComponent)")
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
        return symbols
            .compactMap { sym -> (Symbol, Int)? in
                let score = fuzzyScore(q, sym.name.lowercased())
                return score > 0 ? (sym, score) : nil
            }
            .sorted { $0.1 > $1.1 }
            .prefix(10)
            .map(\.0)
    }

    // MARK: - Fuzzy scoring

    /// Scores how well `query` matches `candidate`.
    /// Higher = better match. 0 = no match.
    private func fuzzyScore(_ query: String, _ candidate: String) -> Int {
        // Exact match
        if candidate == query { return 1000 }

        // Exact prefix
        if candidate.hasPrefix(query) { return 800 }

        // Subsequence match with scoring
        var score = 0
        var qi = query.startIndex
        var ci = candidate.startIndex
        var consecutive = 0
        var lastMatchIndex: String.Index? = nil

        while qi < query.endIndex && ci < candidate.endIndex {
            if query[qi] == candidate[ci] {
                // Bonus for consecutive matches
                consecutive += 1
                score += 10 + consecutive * 5

                // Bonus for word boundary (preceded by _, -, uppercase boundary)
                if ci == candidate.startIndex {
                    score += 20
                } else {
                    let prev = candidate.index(before: ci)
                    if candidate[prev] == "_" || candidate[prev] == "-" {
                        score += 15
                    }
                }

                lastMatchIndex = ci
                qi = query.index(after: qi)
            } else {
                consecutive = 0
            }
            ci = candidate.index(after: ci)
        }

        // All query chars must match
        guard qi == query.endIndex else { return 0 }

        // Penalty for distance from start
        if let last = lastMatchIndex {
            let distance = candidate.distance(from: candidate.startIndex, to: last)
            score -= distance * 2
        }

        return max(score, 1)
    }
}
