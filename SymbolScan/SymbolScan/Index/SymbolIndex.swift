import Foundation
import Combine
import CryptoKit

@MainActor
class SymbolIndex: ObservableObject {

    @Published var isIndexing: Bool = false
    @Published var indexedRepoRoot: URL?
    @Published private(set) var symbolCount: Int = 0
    /// User-facing reason the last activation/reindex produced no index (nil = fine). Surfaced in
    /// the picker's empty state and the menu-bar header.
    @Published var lastIndexError: String?

    private var symbols: [Symbol] = []
    private var scanner: RepoScanner?

    // MARK: - Activation

    /// Make `repoRoot` the active repo. If a persisted index exists on disk, load it and skip the
    /// scan entirely (this is what makes repo-switching instant — the index is only rebuilt on an
    /// explicit `reindex`). Otherwise fall through to a full scan.
    func activateRepo(_ repoRoot: URL) async {
        guard !isIndexing else { return }

        if let cached = IndexCache.load(for: repoRoot) {
            lastIndexError = nil
            scanner = RepoScanner(root: repoRoot)
            symbols = cached
            symbolCount = cached.count
            indexedRepoRoot = repoRoot
            print("💾 Loaded \(cached.count) cached symbols for \(repoRoot.lastPathComponent)")
            return
        }

        await reindex(repoRoot)
    }

    // MARK: - Indexing

    /// Rescan `repoRoot` from scratch and persist the result to disk. Used on first activation of a
    /// repo and by the explicit Reindex action (⌘R / menu).
    func reindex(_ repoRoot: URL) async {
        guard !isIndexing else { return }
        isIndexing = true
        lastIndexError = nil
        defer { isIndexing = false }

        let s = RepoScanner(root: repoRoot)
        guard s.isGitRepo else {
            print("⚠️ Not a git repo: \(repoRoot.path)")
            lastIndexError = "Not a git repository"
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
            IndexCache.save(deduped, for: repoRoot)
            print("✅ Indexed \(deduped.count) symbols across \(files.count) files in \(repoRoot.lastPathComponent)")
        } catch {
            print("❌ Indexing error: \(error)")
            lastIndexError = error.localizedDescription
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
    /// Seed a known symbol set for tests, bypassing git/async indexing. Pass `repoRoot` to also
    /// drive UI state that keys off `indexedRepoRoot`.
    func loadForTesting(_ symbols: [Symbol], repoRoot: URL? = nil) {
        self.symbols = symbols
        self.symbolCount = symbols.count
        self.indexedRepoRoot = repoRoot
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

// MARK: - Index cache (on-disk persistence)

/// Per-repo symbol cache so switching to a previously-indexed repo is instant instead of a full
/// rescan. One JSON file per repo under Application Support, named by a hash of the repo's absolute
/// path (Application Support, not Caches — the OS may purge Caches, which would defeat the point).
///
/// Lives here (rather than its own file) so it builds without a project-file edit. The pure
/// `encode`/`decode` are separated from the disk IO so the codec is unit-testable without touching
/// the filesystem.
enum IndexCache {
    /// Bump when the payload shape changes; a mismatch makes `decode` return nil → forces a rescan.
    static let version = 1

    private struct Payload: Codable {
        var version: Int
        var repoPath: String
        var symbols: [Symbol]
    }

    // MARK: Pure codec

    static func encode(_ symbols: [Symbol], repoPath: String) -> Data? {
        try? JSONEncoder().encode(Payload(version: version, repoPath: repoPath, symbols: symbols))
    }

    /// Returns the symbols only if the data is a valid payload of the current version.
    static func decode(_ data: Data) -> [Symbol]? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == version else { return nil }
        return payload.symbols
    }

    // MARK: Disk IO

    /// Base directory for cache files; injectable so tests can point at a temp dir.
    static func baseDirectory() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SymbolScan/index", isDirectory: true)
    }

    /// Stable, filesystem-safe filename derived from the repo's absolute path.
    static func fileName(for repoRoot: URL) -> String {
        let digest = SHA256.hash(data: Data(repoRoot.path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".json"
    }

    static func cacheURL(for repoRoot: URL, base: URL? = baseDirectory()) -> URL? {
        base?.appendingPathComponent(fileName(for: repoRoot))
    }

    static func load(for repoRoot: URL, base: URL? = baseDirectory()) -> [Symbol]? {
        guard let url = cacheURL(for: repoRoot, base: base),
              let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    @discardableResult
    static func save(_ symbols: [Symbol], for repoRoot: URL, base: URL? = baseDirectory()) -> Bool {
        guard let base, let url = cacheURL(for: repoRoot, base: base),
              let data = encode(symbols, repoPath: repoRoot.path) else { return false }
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            print("⚠️ Failed to write index cache: \(error)")
            return false
        }
    }
}
