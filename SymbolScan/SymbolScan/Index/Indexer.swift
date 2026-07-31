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

        // Index every repo file (any type) and directory as its own entry, so paths are
        // searchable/injectable alongside in-file symbols. Appended after code symbols so an
        // exact-name symbol match still ranks ahead of a same-named file/dir.
        try Task.checkCancellation()
        let allFiles = (try? await scanner.enumerateAllFiles()) ?? []
        for relPath in allFiles {
            let name = (relPath as NSString).lastPathComponent
            collected.append(Symbol(name: name, kind: .file, filePath: relPath, line: 0))
        }
        for dir in RepoScanner.directories(for: allFiles) {
            let name = (dir as NSString).lastPathComponent
            collected.append(Symbol(name: name, kind: .directory, filePath: dir, line: 0))
        }

        // Drop accidental duplicates (e.g. the same file enumerated twice).
        var seen = Set<String>()
        let deduped = collected.filter { sym in
            seen.insert("\(sym.name)|\(sym.filePath)|\(sym.line)").inserted
        }

        try Task.checkCancellation()
        IndexCache.save(deduped, for: root, base: cacheBase)   // encode + write also off-main
        return Result(symbols: deduped, fileCount: files.count)
    }

    /// Load a persisted index off the main actor (JSON decode of a large cache can itself block).
    /// Returns nil when there's no valid cache for `root`. See `buildIndex` for `cacheBase`.
    static func loadCache(root: URL, cacheBase: URL? = IndexCache.baseDirectory()) async -> [Symbol]? {
        IndexCache.load(for: root, base: cacheBase)
    }

    /// Incremental reindex: re-parse only the `changed` files (repo-relative paths) and splice the
    /// result into `existing`, WITHOUT a whole-repo rescan. Returns the new full symbol array (also
    /// persisted to the cache). Runs off the main actor like `buildIndex`.
    ///
    /// A changed file is re-included only if it would survive a full scan — it still exists, isn't a
    /// symlink, isn't in an excluded dir, and isn't gitignored (`RepoScanner.ignored`) — so a
    /// created file is added, a modified file is refreshed, and a deleted/renamed-away/now-ignored
    /// file is dropped. `.directory` entries are recomputed from the resulting file set rather than
    /// patched, and the whole result is re-ordered (code symbols before file/dir entries) and
    /// de-duplicated exactly as `buildIndex` does, so ranking stays identical to a full scan.
    static func reindexFiles(
        _ changed: Set<String>,
        root: URL,
        existing: [Symbol],
        cacheBase: URL? = IndexCache.baseDirectory()
    ) async -> [Symbol] {
        guard !changed.isEmpty else { return existing }
        let scanner = RepoScanner(root: root)
        let ignored = await scanner.ignored(Array(changed))
        let fm = FileManager.default

        // Drop every symbol belonging to a changed file — this clears its old code symbols AND its
        // old `.file` entry in one pass. `.directory` entries key on dir paths, not file paths, and
        // are rebuilt wholesale below.
        var kept = existing.filter { !changed.contains($0.filePath) }

        // Re-add the surviving members of the changed set.
        for rel in changed {
            let url = root.appendingPathComponent(rel)
            let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            guard fm.fileExists(atPath: url.path),
                  !isSymlink,
                  !RepoScanner.isExcluded(rel),
                  !ignored.contains(rel) else { continue }   // deleted / symlink / excluded / gitignored

            // Every repo file gets a searchable `.file` entry, even oversized/unparseable ones.
            let name = (rel as NSString).lastPathComponent
            kept.append(Symbol(name: name, kind: .file, filePath: rel, line: 0))

            if let lang = Language.detect(from: url) {
                let codeSymbols = (try? SymbolParser.parse(url: url, language: lang, relativePath: rel)) ?? []
                kept.append(contentsOf: codeSymbols)
            }
        }

        // Re-establish the full-scan invariant: code symbols first, then `.file`, then `.directory`
        // (so an exact-name symbol match ranks ahead of a same-named file/dir). `.directory` entries
        // are derived fresh from the current file set so removed files don't leave orphan dirs.
        let codeSymbols = kept.filter { $0.kind != .file && $0.kind != .directory }
        let fileEntries = kept.filter { $0.kind == .file }
        let filePaths = fileEntries.map(\.filePath)

        var rebuilt = codeSymbols
        rebuilt.append(contentsOf: fileEntries)
        for dir in RepoScanner.directories(for: filePaths) {
            let name = (dir as NSString).lastPathComponent
            rebuilt.append(Symbol(name: name, kind: .directory, filePath: dir, line: 0))
        }

        // Dedup on the same string key as `buildIndex` — `Symbol` hashes its fresh-per-init `id`,
        // so a `Set<Symbol>` would never collapse same-name/path/line duplicates.
        var seen = Set<String>()
        let deduped = rebuilt.filter { sym in
            seen.insert("\(sym.name)|\(sym.filePath)|\(sym.line)").inserted
        }

        IndexCache.save(deduped, for: root, base: cacheBase)
        return deduped
    }
}
