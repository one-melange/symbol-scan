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

    /// In-flight background index jobs, keyed by repo root. Repos index concurrently; switching the
    /// active repo never cancels another repo's job, so a long index of repo A keeps running while
    /// the user works in repo B.
    private var jobs: [URL: Task<Void, Never>] = [:]

    /// Invoked on the main actor when an index job fails because the path isn't a usable git repo,
    /// so the app can forget a dead/renamed repo preference.
    var onRepoInvalid: ((URL) -> Void)?

    // MARK: - Activation

    /// Make `root` the active repo (what the picker searches). Non-blocking: loads the on-disk
    /// cache off the main actor if present (instant, silent), otherwise starts a background scan.
    /// All heavy work runs off the main thread, and switching repos never cancels another repo's
    /// in-flight job — so a long index keeps running while the user works elsewhere.
    func activateRepo(_ root: URL) {
        indexedRepoRoot = root
        lastIndexError = nil
        symbols = []
        symbolCount = 0
        isIndexing = jobs[root] != nil   // reflect an already-running background job for this repo

        // Load the on-disk cache OFF the main thread (a big cache's JSON decode can itself block),
        // then apply on the main actor. `Task.detached` guarantees the closure body runs with no
        // actor isolation — a plain `Task {}` here would inherit `@MainActor` and block the UI.
        Task.detached(priority: .userInitiated) { [weak self] in
            let cached = await Indexer.loadCache(root: root)
            await self?.applyActivation(root: root, cached: cached)
        }
    }

    /// Main-actor apply for `activateRepo`'s off-main cache probe.
    private func applyActivation(root: URL, cached: [Symbol]?) {
        guard indexedRepoRoot == root else { return }   // superseded by a newer switch
        if let cached {
            symbols = cached
            symbolCount = cached.count
            isIndexing = false
            print("💾 Loaded \(cached.count) cached symbols for \(root.lastPathComponent)")
        } else {
            startJob(root: root, force: false)
        }
    }

    // MARK: - Indexing

    /// Rescan `root` from scratch, bypassing the cache. Used by the explicit Reindex action (⌘R).
    /// Non-blocking; cancels only a still-running job for the *same* repo.
    func reindex(_ root: URL) {
        startJob(root: root, force: true)
    }

    /// Start (or attach to) a background index job for `root`. Jobs for different repos run
    /// concurrently. Publishing back into the active-repo view is guarded by `indexedRepoRoot`.
    private func startJob(root: URL, force: Bool) {
        if let existing = jobs[root] {
            if force {
                existing.cancel()
            } else {
                if root == indexedRepoRoot { isIndexing = true }
                return   // already indexing this repo — attach rather than duplicate
            }
        }
        if root == indexedRepoRoot {
            isIndexing = true
            lastIndexError = nil
        }
        // `Task.detached` (not `Task {}`) so the heavy scan/parse runs with no actor isolation and
        // never touches the main thread; results are handed back via the `@MainActor` `finishJob`.
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<Indexer.Result, Error>
            do {
                outcome = .success(try await Indexer.buildIndex(root: root))
            } catch {
                outcome = .failure(error)
            }
            await self?.finishJob(root: root, outcome: outcome)
        }
        jobs[root] = task
    }

    /// Main-actor completion for an index job: publish results if `root` is still the active repo,
    /// fire the completion banner (real scans only — cache hits don't reach here), and surface
    /// errors. A cancelled job (superseded by a forced re-index of the same repo) leaves state to
    /// its replacement.
    private func finishJob(root: URL, outcome: Result<Indexer.Result, Error>) {
        switch outcome {
        case .success(let result):
            jobs[root] = nil
            if root == indexedRepoRoot {
                symbols = result.symbols
                symbolCount = result.symbols.count
                isIndexing = false
                lastIndexError = nil
            }
            print("✅ Indexed \(result.symbols.count) symbols across \(result.fileCount) files in \(root.lastPathComponent)")
            IndexNotifier.notifyIndexed(root: root, count: result.symbols.count)
        case .failure(let error):
            if error is CancellationError { return }   // replaced by a forced re-index
            jobs[root] = nil
            if root == indexedRepoRoot {
                isIndexing = false
                lastIndexError = error.localizedDescription
            }
            print("❌ Indexing error for \(root.lastPathComponent): \(error)")
            if error is IndexError { onRepoInvalid?(root) }
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
    /// Bump when the payload shape *or content* changes; a mismatch makes `decode` return nil →
    /// forces a rescan. v2: added `.file`/`.directory` entries. v3: symbols now come from
    /// Tree-sitter, so regex-built caches must be discarded. v4: `.tsx` is parsed with the
    /// TSX grammar and `.js`/`.jsx` are indexed — caches built before that are missing
    /// those symbols entirely, and would otherwise be served forever.
    static let version = 4

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
