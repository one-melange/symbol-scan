import Foundation

/// Failure modes surfaced to the user when an index job can't run.
enum IndexError: LocalizedError {
    case notGitRepo

    var errorDescription: String? {
        switch self {
        case .notGitRepo: return "Not a git repository"
        }
    }
}

/// The heavy indexing work, pulled out of `SymbolIndex` so it can run **off the main actor**.
///
/// `enum` statics are `nonisolated`, so awaiting `buildIndex` from `SymbolIndex`'s `@MainActor`
/// context runs the body on the cooperative thread pool — the `git ls-files` wait, the
/// parse-every-file loop, dedup and the JSON cache write all stay off the main thread, so the
/// menu-bar UI never freezes (the bug that motivated this: indexing a large repo locked the app).
///
/// It reuses the existing pieces — `RepoScanner`, `SymbolParser.parse`,
/// `RepoScanner.directories(for:)`, `IndexCache` — and adds no main-actor dependencies.
enum Indexer {

    struct Result {
        let symbols: [Symbol]
        let fileCount: Int
    }

    /// Canonical ordering + dir-derivation + dedup, shared by every path that produces a symbol
    /// array (`buildIndex`, `reindexFiles`, and cache load) so ranking is identical no matter how
    /// the array was assembled. Pure.
    ///
    /// - order: code symbols first, then `.file`, then `.directory` — so an exact-name symbol match
    ///   ranks ahead of a same-named file/dir;
    /// - `.directory` entries are **derived** from the `.file` set (any incoming `.directory` is
    ///   dropped and rebuilt), so removed files never leave orphan dirs and a replayed log needs no
    ///   dir bookkeeping;
    /// - dedup on the `name|filePath|line` string key — `Symbol` hashes a fresh-per-init `id`, so a
    ///   `Set<Symbol>` would never collapse same-name/path/line duplicates.
    static func normalize(_ symbols: [Symbol]) -> [Symbol] {
        let code = symbols.filter { $0.kind != .file && $0.kind != .directory }
        let files = symbols.filter { $0.kind == .file }

        var rebuilt = code
        rebuilt.append(contentsOf: files)
        for dir in RepoScanner.directories(for: files.map(\.filePath)) {
            let name = (dir as NSString).lastPathComponent
            rebuilt.append(Symbol(name: name, kind: .directory, filePath: dir, line: 0))
        }

        var seen = Set<String>()
        return rebuilt.filter { seen.insert("\($0.name)|\($0.filePath)|\($0.line)").inserted }
    }

    /// Replay `patches` over `base`: for each patch, drop every symbol whose `filePath` is in the
    /// patch's `paths` (clearing a changed file's old code + `.file` entries, or removing a deleted
    /// file entirely), then append the patch's fresh symbols. Pure; the caller `normalize`s the
    /// result. Applied in order so the last patch touching a path wins.
    static func applyPatches(base: [Symbol], _ patches: [IndexCache.Patch]) -> [Symbol] {
        var symbols = base
        for patch in patches {
            let removed = Set(patch.paths)
            symbols = symbols.filter { !removed.contains($0.filePath) }
            symbols.append(contentsOf: patch.symbols)
        }
        return symbols
    }

    /// Full scan of `root`: parse source files into symbols, add file/directory entries,
    /// dedup, persist to the on-disk cache, and return the result. Throws `IndexError.notGitRepo`
    /// for a non-git directory, or `CancellationError` if a superseding (forced) re-index of the
    /// **same** repo cancelled this job.
    ///
    /// `cacheBase` exists purely so tests can exercise the whole composition without writing to the
    /// user's real Application Support directory — everything else here already works against a
    /// temp repo. It mirrors the `base:` parameter `IndexCache.save`/`load` have always had, and
    /// defaults to the same value, so production call sites pass `(root:)` and behave identically.
    static func buildIndex(root: URL, cacheBase: URL? = IndexCache.baseDirectory()) async throws -> Result {
        let scanner = RepoScanner(root: root)
        guard scanner.isGitRepo else { throw IndexError.notGitRepo }

        let files = try await scanner.enumerateSourceFiles()
        var collected: [Symbol] = []
        for url in files {
            try Task.checkCancellation()
            guard let lang = Language.detect(from: url) else { continue }
            let rel = scanner.relativePath(for: url)
            let fileSymbols = (try? SymbolParser.parse(url: url, language: lang, relativePath: rel)) ?? []
            collected.append(contentsOf: fileSymbols)
        }

        // Index every repo file (any type) as its own `.file` entry, so paths are
        // searchable/injectable alongside in-file symbols. `.directory` entries are derived by
        // `normalize` from these `.file` paths (the `.file` set IS `enumerateAllFiles`, so the
        // derived dir set is identical to enumerating them directly).
        try Task.checkCancellation()
        let allFiles = (try? await scanner.enumerateAllFiles()) ?? []
        for relPath in allFiles {
            let name = (relPath as NSString).lastPathComponent
            collected.append(Symbol(name: name, kind: .file, filePath: relPath, line: 0))
        }

        // Canonical order (code, then file, then derived dir) + dedup.
        let symbols = normalize(collected)

        try Task.checkCancellation()
        // A full scan is authoritative: rewrite the base snapshot AND clear any stale patch log.
        IndexCache.compact(symbols, for: root, base: cacheBase)   // encode + write also off-main
        return Result(symbols: symbols, fileCount: files.count)
    }

    /// Load a persisted index off the main actor (JSON decode of a large cache can itself block).
    /// Reconstructs the current symbol set by replaying the patch log over the base snapshot, then
    /// `normalize`s it so ranking matches a full scan. Base and log are read as **one atomic
    /// snapshot** (`IndexCache.loadSnapshot`) so a concurrent `compact` can't yield a base and log
    /// from different generations. Also returns the log's `patchCount` — from that same snapshot — so
    /// the caller can seed its compaction counter without a second, separately-serialized read.
    /// Returns nil when there's no valid base cache for `root` (a missing base means the log, if any,
    /// can't be trusted). See `buildIndex` for `cacheBase`.
    static func loadCache(root: URL, cacheBase: URL? = IndexCache.baseDirectory()) async -> (symbols: [Symbol], patchCount: Int)? {
        guard let snap = IndexCache.loadSnapshot(for: root, base: cacheBase) else { return nil }
        guard !snap.patches.isEmpty else { return (snap.base, 0) }
        return (normalize(applyPatches(base: snap.base, snap.patches)), snap.patches.count)
    }

    /// Incremental reindex: re-parse only the `changed` files (repo-relative paths) and splice the
    /// result into `existing`, WITHOUT a whole-repo rescan. Returns both the new full symbol array
    /// (for the in-memory publish) and the `Patch` describing just this change — the caller persists
    /// the patch (coalesced) rather than rewriting the whole cache here (T23). Runs off the main
    /// actor like `buildIndex`.
    ///
    /// A changed file is re-included only if it would survive a full scan — it still exists, isn't a
    /// symlink, isn't in an excluded dir, and isn't gitignored (`RepoScanner.ignored`) — so a
    /// created file is added, a modified file is refreshed, and a deleted/renamed-away/now-ignored
    /// file is dropped. The result is re-ordered and de-duplicated by `normalize`, so ranking stays
    /// identical to a full scan, and the returned `Patch` replays to the same thing on load.
    static func reindexFiles(
        _ changed: Set<String>,
        root: URL,
        existing: [Symbol]
    ) async -> (symbols: [Symbol], patch: IndexCache.Patch) {
        guard !changed.isEmpty else { return (existing, IndexCache.Patch(paths: [], symbols: [])) }
        let scanner = RepoScanner(root: root)
        let ignored = await scanner.ignored(Array(changed))
        let fm = FileManager.default

        // Freshly-parsed code + `.file` entries for the surviving changed files. This is exactly the
        // patch's `symbols` payload — a deleted/ignored file contributes nothing here but is still
        // named in the patch's `paths`, so replay removes its old entries.
        var fresh: [Symbol] = []
        for rel in changed {
            let url = root.appendingPathComponent(rel)
            let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            guard fm.fileExists(atPath: url.path),
                  !isSymlink,
                  !RepoScanner.isExcluded(rel),
                  !ignored.contains(rel) else { continue }   // deleted / symlink / excluded / gitignored

            // Every repo file gets a searchable `.file` entry, even oversized/unparseable ones.
            let name = (rel as NSString).lastPathComponent
            fresh.append(Symbol(name: name, kind: .file, filePath: rel, line: 0))

            if let lang = Language.detect(from: url) {
                let codeSymbols = (try? SymbolParser.parse(url: url, language: lang, relativePath: rel)) ?? []
                fresh.append(contentsOf: codeSymbols)
            }
        }

        let patch = IndexCache.Patch(paths: Array(changed), symbols: fresh)
        // Splice in memory the same way load replays the patch, so the published array and the
        // eventually-persisted base+log agree exactly.
        let symbols = normalize(applyPatches(base: existing, [patch]))
        return (symbols, patch)
    }
}
