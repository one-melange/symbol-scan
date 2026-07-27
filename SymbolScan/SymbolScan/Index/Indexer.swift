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
}
