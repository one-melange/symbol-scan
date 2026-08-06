import Foundation
import Combine
import CryptoKit
import os

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

    /// Repo-relative paths reported changed by the file watcher, awaiting an incremental reindex.
    /// Accumulated between drains so a burst of saves coalesces into one splice.
    private var pendingChanges: Set<String> = []

    /// Single-flight guard: only one incremental splice runs at a time, so the read-modify-write of
    /// `symbols` (snapshot → off-main reparse → write-back) can't interleave with another.
    private var incrementalRunning = false

    /// Bumped on every *external* replacement of `symbols` (activation, cache load, full-scan
    /// finish). An incremental captures the epoch when it snapshots and only writes back if it's
    /// unchanged — otherwise a full scan that both started *and* finished during the off-main
    /// reparse (so `jobs[root]` is already nil again) would be silently clobbered by stale data.
    private var publishEpoch = 0

    /// Buffered incremental patches not yet written to the on-disk log. Coalesced: a burst of saves
    /// appends one batch on a debounce (`scheduleFlush`) rather than one write per splice (T23).
    private var pendingPatches: [IndexCache.Patch] = []

    /// Single-flight guard for the log write, mirroring `incrementalRunning` for the reparse.
    private var flushing = false

    /// Debounce for the coalesced flush; re-armed on every buffered patch, cancelled on repo switch,
    /// full scan, or termination.
    private var flushTask: Task<Void, Never>?

    /// Patch records appended to the current base's log since the last compaction. When it crosses
    /// `maxJournalPatchesBeforeCompaction`, the next flush rewrites the base and clears the log so
    /// the log — and the load-time replay cost — stays bounded.
    private var journaledPatchCount = 0

    /// Coalescing window: a save burst within this interval flushes as one appended write. Short so
    /// a crash/quit loses at most this much of the (self-healing) on-disk cache; the in-memory index
    /// is always current regardless.
    private static let incrementalFlushDelay: TimeInterval = 2.0

    /// Compact (full base rewrite + log clear) once the log holds this many patch records, bounding
    /// log growth and replay cost across a long session of edits.
    private static let maxJournalPatchesBeforeCompaction = 200

    // MARK: - Activation

    /// Make `root` the active repo (what the picker searches). Non-blocking: loads the on-disk
    /// cache off the main actor if present (instant, silent), otherwise starts a background scan.
    /// All heavy work runs off the main thread, and switching repos never cancels another repo's
    /// in-flight job — so a long index keeps running while the user works elsewhere.
    func activateRepo(_ root: URL) {
        // Persist + drain the previous repo's writes synchronously BEFORE switching, so switching
        // back to it can't reload a stale base while an append is still in flight.
        drainWritesSynchronously()
        indexedRepoRoot = root
        lastIndexError = nil
        symbols = []
        symbolCount = 0
        pendingChanges = []   // drop any changes queued for the previously-active repo
        pendingPatches = []   // …and its unflushed patches (drainWritesSynchronously persisted them)
        journaledPatchCount = 0
        publishEpoch += 1     // invalidate any in-flight incremental from the previous view
        let epoch = publishEpoch
        isIndexing = jobs[root] != nil   // reflect an already-running background job for this repo

        // Load the on-disk cache OFF the main thread (a big cache's JSON decode can itself block),
        // then apply on the main actor. `Task.detached` guarantees the closure body runs with no
        // actor isolation — a plain `Task {}` here would inherit `@MainActor` and block the UI.
        // `loadCache` returns the merged symbols and the log's patch count from one atomic snapshot,
        // so the journal counter is seeded without a second, separately-serialized read.
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = await Indexer.loadCache(root: root)
            await self?.applyActivation(root: root, cached: loaded?.symbols,
                                        journaledPatches: loaded?.patchCount ?? 0, epoch: epoch)
        }
    }

    /// Main-actor apply for `activateRepo`'s off-main cache probe.
    private func applyActivation(root: URL, cached: [Symbol]?, journaledPatches: Int, epoch: Int) {
        // `indexedRepoRoot == root` alone isn't enough. Two ways a stale cache load must defer to an
        // authoritative full scan started while it was in flight:
        //   • the scan already finished and published → `publishEpoch` bumped (epoch guard);
        //   • the scan is still running → `jobs[root] != nil`. Starting it doesn't bump the epoch, so
        //     without this check the cache would publish and set `isIndexing = false` mid-scan.
        // In the running case, dropping the cache result also skips the `else` branch's `startJob`,
        // which is correct — the running job is the authoritative one.
        guard indexedRepoRoot == root, epoch == publishEpoch, jobs[root] == nil else { return }
        if let cached {
            symbols = cached
            symbolCount = cached.count
            journaledPatchCount = journaledPatches
            isIndexing = false
            publishEpoch += 1
            Log.index.info("Loaded \(cached.count) cached symbols for \(root.lastPathComponent, privacy: .public)")
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
            // A full scan will `compact` an authoritative base + empty log, so drop any buffered
            // increments and cancel their flush — appending them afterward would orphan the log.
            pendingPatches = []
            flushTask?.cancel()
            flushTask = nil
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
                publishEpoch += 1
                // `buildIndex` compacted a fresh base with an empty log — reset the journal so it
                // doesn't count against the next compaction.
                pendingPatches = []
                journaledPatchCount = 0
                flushTask?.cancel()
                flushTask = nil
            }
            Log.index.info("Indexed \(result.symbols.count) symbols across \(result.fileCount) files in \(root.lastPathComponent, privacy: .public)")
            IndexNotifier.notifyIndexed(root: root, count: result.symbols.count)
        case .failure(let error):
            if error is CancellationError { return }   // replaced by a forced re-index
            jobs[root] = nil
            if root == indexedRepoRoot {
                isIndexing = false
                lastIndexError = error.localizedDescription
            }
            Log.index.error("Indexing error for \(root.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if error is IndexError { onRepoInvalid?(root) }
        }
    }

    // MARK: - Incremental reindex (file watcher)

    /// The file watcher observed `paths` change in the active repo. Queue them and drain — a
    /// targeted reparse of just those files, no whole-repo rescan. Paths for a repo that is no
    /// longer active are ignored (the `indexedRepoRoot` guards).
    func filesChanged(_ paths: [URL]) {
        guard let root = indexedRepoRoot else { return }
        let scanner = RepoScanner(root: root)
        for url in paths { pendingChanges.insert(scanner.relativePath(for: url)) }
        drainIncremental(root: root)
    }

    /// The file watcher lost events (dropped/coalesced, or the repo root moved) — a targeted update
    /// can't be trusted, so fall back to an authoritative full rescan.
    func rescanRequested() {
        guard let root = indexedRepoRoot else { return }
        reindex(root)
    }

    /// Splice the currently-pending file changes into `symbols` off the main actor, if it's safe:
    /// the repo is still active, no full scan is running (a full scan is authoritative and will
    /// supersede us), and no other incremental is in flight (single-flight).
    private func drainIncremental(root: URL) {
        guard root == indexedRepoRoot,
              jobs[root] == nil,
              !incrementalRunning,
              !pendingChanges.isEmpty else { return }

        let batch = pendingChanges
        pendingChanges = []
        incrementalRunning = true
        let snapshot = symbols          // snapshot on the main actor before detaching
        let epoch = publishEpoch        // …and the epoch it belongs to

        Task.detached(priority: .utility) { [weak self] in
            let result = await Indexer.reindexFiles(batch, root: root, existing: snapshot)
            await self?.finishIncremental(root: root, updated: result.symbols, patch: result.patch, epoch: epoch)
        }
    }

    /// Main-actor completion for an incremental splice. Publishes silently — no `IndexNotifier`
    /// banner, unlike a full scan — buffers the patch for a coalesced write, then re-drains to pick
    /// up anything that changed mid-splice.
    private func finishIncremental(root: URL, updated: [Symbol], patch: IndexCache.Patch, epoch: Int) {
        incrementalRunning = false
        // Discard if the repo switched away, a full (re)index is running or has published since we
        // snapshotted (epoch bumped), leaving that authoritative result in place — and drop the
        // patch too, since that authoritative base already reflects (or will reflect) the change.
        if root == indexedRepoRoot, jobs[root] == nil, epoch == publishEpoch {
            symbols = updated
            symbolCount = updated.count
            if !patch.paths.isEmpty {
                pendingPatches.append(patch)
                scheduleFlush(root: root)
            }
        }
        drainIncremental(root: root)
    }

    // MARK: - Coalesced cache writes (T23)

    /// (Re)arm the debounce so a burst of splices produces one log write. Each buffered patch
    /// restarts the timer; the flush fires once the saves quiesce for `incrementalFlushDelay`.
    private func scheduleFlush(root: URL) {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.incrementalFlushDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flushNow(root: root)
        }
    }

    /// Persist buffered patches off the main actor: a plain log append, or — once the log has grown
    /// past `maxJournalPatchesBeforeCompaction` — a full base rewrite that collapses the log. Guards
    /// mirror `drainIncremental` (active repo, no full scan running, single-flight).
    private func flushNow(root: URL) {
        guard root == indexedRepoRoot,
              jobs[root] == nil,
              !flushing,
              !pendingPatches.isEmpty else { return }

        flushing = true
        let batch = pendingPatches
        pendingPatches = []
        let willCompact = journaledPatchCount + batch.count > Self.maxJournalPatchesBeforeCompaction
        // The generation this write is based on — if a full reindex compacts before it lands, the
        // write is dropped as superseded (its data is already reflected in that fresh base).
        let generation = IndexCache.generation(for: root)

        // Enqueue the write SYNCHRONOUSLY on the serial IO queue (not via a detached Task, whose
        // dispatch has a gap before it reaches the queue) so a repo-switch / termination
        // `IndexCache.drain()` is a true barrier for it — an in-flight flush can't be lost or reordered.
        let complete: @Sendable (Bool, Bool) -> Void = { [weak self] compacted, wrote in
            Task.detached { await self?.finishFlush(root: root, compacted: compacted && wrote,
                                                    appended: wrote ? batch.count : 0) }
        }
        if willCompact {
            // Compaction writes the whole in-memory array (already includes every buffered patch),
            // so it supersedes the batch rather than appending it.
            IndexCache.enqueueCompact(symbols, for: root, ifGeneration: generation) { complete(true, $0) }
        } else {
            IndexCache.enqueueAppend(batch, for: root, ifGeneration: generation) { complete(false, $0) }
        }
    }

    /// Main-actor completion for a flush: update the journal counter (only while `root` is still the
    /// active repo — a write for a since-switched-away repo must not touch the current repo's count)
    /// and re-arm the debounce for whatever is active now, so patches buffered mid-flush — including
    /// a new repo's, if we switched while this flush was in flight — aren't stranded.
    private func finishFlush(root: URL, compacted: Bool, appended: Int) {
        flushing = false
        if root == indexedRepoRoot {
            journaledPatchCount = compacted ? 0 : journaledPatchCount + appended
        }
        if let active = indexedRepoRoot, !pendingPatches.isEmpty { scheduleFlush(root: active) }
    }

    /// Synchronously persist buffered patches for the active repo **and wait for any in-flight async
    /// flush to finish**, so nothing is lost or reordered. Used before switching repos (so switching
    /// back can't reload a stale base while an append is still pending) and at termination (a detached
    /// write would not be awaited before exit). Blocks the caller briefly — the correct trade for
    /// these infrequent, correctness-critical moments; the debounced steady-state flush stays async.
    ///
    /// Does NOT clear `flushing`: an in-flight flush's completion still hops to the main actor to run
    /// `finishFlush` (which resets it and re-arms), and clearing it here would race that.
    private func drainWritesSynchronously() {
        flushTask?.cancel()
        flushTask = nil
        if let root = indexedRepoRoot, !pendingPatches.isEmpty {
            let batch = pendingPatches
            pendingPatches = []
            IndexCache.appendPatches(batch, for: root, ifGeneration: IndexCache.generation(for: root))
        }
        IndexCache.drain()   // barrier: any write an in-flight flushNow enqueued has now landed
    }

    /// Flush buffered writes at app termination (see `AppDelegate.applicationWillTerminate`).
    func flushPendingWrites() {
        drainWritesSynchronously()
    }

    // MARK: - Search

    /// Strict-substring symbol search — returns the top `SymbolMatcher.defaultResultLimit` results
    /// ranked by score. Ranking/matching lives in `SymbolMatcher` so it can be unit-tested in isolation.
    func search(_ query: String) -> [Symbol] {
        let results = SymbolMatcher.search(query, in: symbols)
        #if DEBUG
        // Query text is the user's typing — keep it `.private` so it's redacted in captured logs.
        Log.search.debug("search(\(query, privacy: .private)) → \(results.count) results")
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

    /// How many results the picker shows by default. Small on purpose: the overlay lists a short,
    /// scannable set rather than every match, and strict-substring ranking puts the best ones first.
    static let defaultResultLimit = 10

    /// Returns the best `limit` symbols for `query`, ranked by `score` descending.
    /// An empty query returns the first `limit` symbols unranked.
    static func search(_ query: String, in symbols: [Symbol], limit: Int = defaultResultLimit) -> [Symbol] {
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
/// rescan. Two files per repo under Application Support, named by a hash of the repo's absolute
/// path (Application Support, not Caches — the OS may purge Caches, which would defeat the point):
/// a `<hash>.json` **base snapshot** and a `<hash>.log` **append-only patch log** (T23).
///
/// The base is the whole symbol array; each incremental save appends one small `Patch` line to the
/// log instead of rewriting the base, so a save's write cost is proportional to the change, not the
/// repo size. Loading replays the log over the base (see `Indexer.loadCache`). A full reindex or a
/// grown log triggers `compact`, which rewrites the base and clears the log.
///
/// Lives here (rather than its own file) so it builds without a project-file edit. The pure
/// `encode`/`decode` (and `encodePatch`/`decodePatch`) are separated from the disk IO so the codec
/// is unit-testable without touching the filesystem.
enum IndexCache {
    /// Bump when the payload shape *or content* changes; a mismatch makes `decode` return nil →
    /// forces a rescan. v2: added `.file`/`.directory` entries. v3: symbols now come from
    /// Tree-sitter, so regex-built caches must be discarded. v4: `.tsx` is parsed with the
    /// TSX grammar and `.js`/`.jsx` are indexed — caches built before that are missing
    /// those symbols entirely, and would otherwise be served forever. v5: the git enumeration
    /// path now excludes `target`/`vendor`/`__pycache__`/`.next`/`dist`, caps parse file size,
    /// and skips symlinked dirs — pre-v5 caches can contain now-excluded entries (and the
    /// incremental writer must never patch a stale v4 array into an inconsistent mix). v6: the
    /// cache is now a base snapshot + append-only patch log (T23) — a pre-v6 base has no log, so
    /// forcing a rescan on upgrade guarantees base and log start consistent.
    static let version = 6

    private struct Payload: Codable {
        var version: Int
        var repoPath: String
        var symbols: [Symbol]
    }

    /// One incremental update, appended to the log as a single JSONL line. `paths` is the full
    /// changed set (so a deleted / now-ignored file, which contributes no `symbols`, still has its
    /// old entries removed on replay); `symbols` are the freshly-parsed **code + `.file`** entries
    /// for the surviving files — never `.directory`, which is always derived (see `Indexer.normalize`).
    struct Patch: Codable {
        var paths: [String]
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

    /// Encodes one patch as a single line (no embedded newlines — `JSONEncoder` never emits them
    /// for a compact object, so one `Patch` maps to exactly one log line).
    static func encodePatch(_ patch: Patch) -> Data? {
        try? JSONEncoder().encode(patch)
    }

    static func decodePatch(_ data: Data) -> Patch? {
        try? JSONDecoder().decode(Patch.self, from: data)
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

    /// The patch log sits beside the base snapshot: `<hash>.json` → `<hash>.log`.
    static func logURL(for repoRoot: URL, base: URL? = baseDirectory()) -> URL? {
        cacheURL(for: repoRoot, base: base)?.deletingPathExtension().appendingPathExtension("log")
    }

    /// Serializes ALL cache IO for every repo (base writes, log appends, log clears, reads). Cache
    /// files are written from several off-main tasks at once — a full-scan `compact` and an
    /// incremental `appendPatches` can be in flight together — so without this a stale append could
    /// interleave with, or land *after*, an authoritative compaction and restore inconsistent state.
    /// Writes are small and infrequent, so a single global serial queue is simpler than per-repo
    /// locks and plenty fast.
    private static let ioQueue = DispatchQueue(label: "com.symbolscan.indexcache.io")

    /// Per-repo write generation (keyed by cache filename), bumped by every authoritative `compact`.
    /// An incremental write captures the generation it was scheduled under and is dropped if the
    /// generation has since advanced — i.e. a full reindex has superseded it. Mutated only on
    /// `ioQueue`. Process-local (resets on relaunch, where the on-disk base+log are already
    /// consistent because the last writes were ordered through this queue).
    private static var generations: [String: Int] = [:]

    /// The current write generation for `repoRoot` — captured by an incremental write so a later
    /// `compact` can supersede it.
    static func generation(for repoRoot: URL, base: URL? = baseDirectory()) -> Int {
        ioQueue.sync { generations[fileName(for: repoRoot), default: 0] }
    }

    static func load(for repoRoot: URL, base: URL? = baseDirectory()) -> [Symbol]? {
        ioQueue.sync {
            guard let url = cacheURL(for: repoRoot, base: base),
                  let data = try? Data(contentsOf: url) else { return nil }
            return decode(data)
        }
    }

    @discardableResult
    static func save(_ symbols: [Symbol], for repoRoot: URL, base: URL? = baseDirectory()) -> Bool {
        ioQueue.sync { writeBaseLocked(symbols, for: repoRoot, base: base) }
    }

    /// Append `patches` to the repo's log as newline-terminated JSON lines. Plain append (not an
    /// atomic full rewrite) — that's the whole point of the journal — and crash-safe: a torn final
    /// line just fails to decode and is skipped by `loadPatches`. Pass `ifGeneration` to make the
    /// write conditional: if a `compact` has advanced the repo's generation since it was captured,
    /// the append is dropped (superseded by a full reindex) and returns false.
    @discardableResult
    static func appendPatches(_ patches: [Patch], for repoRoot: URL,
                              base: URL? = baseDirectory(), ifGeneration: Int? = nil) -> Bool {
        ioQueue.sync {
            if let g = ifGeneration, g != generations[fileName(for: repoRoot), default: 0] {
                return false   // superseded by a full reindex between scheduling and writing
            }
            return appendLocked(patches, for: repoRoot, base: base)
        }
    }

    /// Read every well-formed patch line from the repo's log, in order. Missing log → empty.
    /// Malformed lines (e.g. a torn trailing append) are skipped rather than aborting the load.
    static func loadPatches(for repoRoot: URL, base: URL? = baseDirectory()) -> [Patch] {
        ioQueue.sync { loadPatchesLocked(for: repoRoot, base: base) }
    }

    /// Read the base snapshot **and** its patch log as one atomic operation. Doing both reads inside a
    /// single `ioQueue.sync` is the point: a separate `load` + `loadPatches` can straddle an
    /// authoritative `compact` (which rewrites the base and clears the log under the same queue),
    /// yielding a base and a log from different generations — e.g. the old base with the freshly
    /// emptied log. Returns nil when there's no base (a log without a base can't be trusted).
    static func loadSnapshot(for repoRoot: URL, base: URL? = baseDirectory()) -> (base: [Symbol], patches: [Patch])? {
        ioQueue.sync {
            guard let url = cacheURL(for: repoRoot, base: base),
                  let data = try? Data(contentsOf: url),
                  let symbols = decode(data) else { return nil }
            return (symbols, loadPatchesLocked(for: repoRoot, base: base))
        }
    }

    static func clearLog(for repoRoot: URL, base: URL? = baseDirectory()) {
        ioQueue.sync { clearLogLocked(for: repoRoot, base: base) }
    }

    /// Rewrite the base snapshot from the authoritative in-memory `symbols` and clear the log — the
    /// amortized full write that collapses the journal back into the base. Used by a full reindex
    /// and when the log grows past the coalescing threshold. Base write + log clear happen as one
    /// serialized unit, and the repo's generation is bumped so any concurrently-scheduled
    /// incremental write (which captured the old generation) is dropped rather than applied on top.
    /// Pass `ifGeneration` to also make the compaction itself conditional (used by the in-memory
    /// incremental compaction, which must not clobber a fresher full reindex).
    @discardableResult
    static func compact(_ symbols: [Symbol], for repoRoot: URL,
                        base: URL? = baseDirectory(), ifGeneration: Int? = nil) -> Bool {
        ioQueue.sync {
            let key = fileName(for: repoRoot)
            if let g = ifGeneration, g != generations[key, default: 0] { return false }
            generations[key, default: 0] += 1
            guard writeBaseLocked(symbols, for: repoRoot, base: base) else { return false }
            clearLogLocked(for: repoRoot, base: base)
            return true
        }
    }

    /// Enqueue an append on the serial IO queue and deliver the result to `completion` (which runs on
    /// that queue). Unlike a detached `Task`, the enqueue is **synchronous** — the work is on the
    /// queue before this returns — so a later `drain()` is a true barrier for it, which is how
    /// repo-switch and termination guarantee an in-flight flush is durable and ordered. `ifGeneration`
    /// drops the write if a `compact` has advanced the repo's generation since it was captured.
    static func enqueueAppend(_ patches: [Patch], for repoRoot: URL, base: URL? = baseDirectory(),
                              ifGeneration: Int, completion: @escaping @Sendable (Bool) -> Void) {
        ioQueue.async {
            let wrote = ifGeneration == generations[fileName(for: repoRoot), default: 0]
                && appendLocked(patches, for: repoRoot, base: base)
            completion(wrote)
        }
    }

    /// Compaction counterpart of `enqueueAppend` (bumps the generation, writes base, clears log).
    static func enqueueCompact(_ symbols: [Symbol], for repoRoot: URL, base: URL? = baseDirectory(),
                               ifGeneration: Int, completion: @escaping @Sendable (Bool) -> Void) {
        ioQueue.async {
            let key = fileName(for: repoRoot)
            var wrote = false
            if ifGeneration == generations[key, default: 0] {
                generations[key, default: 0] += 1
                if writeBaseLocked(symbols, for: repoRoot, base: base) {
                    clearLogLocked(for: repoRoot, base: base)
                    wrote = true
                }
            }
            completion(wrote)
        }
    }

    /// Barrier: block the caller until every write enqueued before this call has finished. Used at
    /// repo-switch and termination to make in-flight async flushes durable and correctly ordered
    /// before the repo can be reloaded (or the process exits).
    static func drain() { ioQueue.sync {} }

    // MARK: Locked internals (call only while holding `ioQueue`)

    private static func writeBaseLocked(_ symbols: [Symbol], for repoRoot: URL, base: URL?) -> Bool {
        guard let base, let url = cacheURL(for: repoRoot, base: base),
              let data = encode(symbols, repoPath: repoRoot.path) else { return false }
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Log.index.error("Failed to write index cache: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func appendLocked(_ patches: [Patch], for repoRoot: URL, base: URL?) -> Bool {
        guard !patches.isEmpty, let base, let url = logURL(for: repoRoot, base: base) else { return false }
        var blob = Data()
        for patch in patches {
            guard let line = encodePatch(patch) else { continue }
            blob.append(line)
            blob.append(0x0A)   // '\n'
        }
        guard !blob.isEmpty else { return false }
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            // `forUpdating` (read+write) so we can inspect the last byte for a torn tail; a write-only
            // handle can't be read. nil when the file doesn't exist yet → create it below.
            if let handle = try? FileHandle(forUpdating: url) {
                defer { try? handle.close() }
                let end = try handle.seekToEnd()
                // Guard against a torn final line from a previous crashed append: if the file doesn't
                // end in a newline, insert one first so the partial record stays a separate (skipped)
                // line instead of fusing onto — and corrupting — our first new record.
                if end > 0 {
                    try handle.seek(toOffset: end - 1)
                    if try handle.read(upToCount: 1) != Data([0x0A]) { blob.insert(0x0A, at: 0) }
                    try handle.seekToEnd()
                }
                try handle.write(contentsOf: blob)
            } else {
                try blob.write(to: url)   // no file yet → create it with the first batch
            }
            return true
        } catch {
            Log.index.error("Failed to append index patch log: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func clearLogLocked(for repoRoot: URL, base: URL?) {
        guard let url = logURL(for: repoRoot, base: base) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func loadPatchesLocked(for repoRoot: URL, base: URL?) -> [Patch] {
        guard let url = logURL(for: repoRoot, base: base),
              let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { decodePatch(Data($0)) }
    }
}
