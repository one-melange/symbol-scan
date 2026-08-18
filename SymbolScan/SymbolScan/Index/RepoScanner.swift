import Foundation
import CoreServices
import os

class RepoScanner {

    let root: URL

    init(root: URL) {
        self.root = root
    }

    // MARK: - Git detection

    var isGitRepo: Bool {
        let gitDir = root.appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: gitDir.path)
    }

    // MARK: - File enumeration

    /// Returns all tracked + untracked (non-ignored) source files using git ls-files.
    /// Falls back to FileManager walk if git isn't available.
    func enumerateSourceFiles() async throws -> [URL] {
        if isGitRepo, let files = try? await gitLsFiles() {
            Log.scanner.debug("enumerateSourceFiles: git ls-files → \(files.count) source files")
            return files
        }
        let files = fileManagerWalk()
        Log.scanner.debug("enumerateSourceFiles: FileManager fallback → \(files.count) source files")
        return files
    }

    /// Every tracked + untracked (non-ignored) file — any type, not just parseable source —
    /// as repo-root-relative paths. Used to build the file/directory index entries.
    /// Same enumeration as `enumerateSourceFiles`, minus the language filter.
    func enumerateAllFiles() async throws -> [String] {
        if isGitRepo, let paths = try? await gitLsFilesRaw() {
            Log.scanner.debug("enumerateAllFiles: git ls-files → \(paths.count) files")
            return paths
        }
        let paths = fileManagerWalkRaw()
        Log.scanner.debug("enumerateAllFiles: FileManager fallback → \(paths.count) files")
        return paths
    }

    /// All ancestor directory paths (repo-root-relative) implied by `filePaths`. Pure so it is
    /// unit-testable and honors whatever gitignore already pruned from `filePaths`.
    /// E.g. `["a/b/c.txt", "a/d.txt"]` → `["a", "a/b"]`.
    static func directories(for filePaths: [String]) -> [String] {
        var dirs = Set<String>()
        for path in filePaths {
            var comps = path.split(separator: "/").map(String.init)
            guard comps.count > 1 else { continue }   // top-level file → no parent directory
            comps.removeLast()                         // drop the filename
            var prefix: [String] = []
            for c in comps {
                prefix.append(c)
                dirs.insert(prefix.joined(separator: "/"))
            }
        }
        return dirs.sorted()
    }

    /// Directory names we never want to descend into — build output, dependency
    /// checkouts, VCS metadata. Applied on **both** enumeration paths via `isExcluded`: the
    /// FileManager fallback prunes them, and the git path filters them out too. The git path
    /// needs this because `git ls-files` only honors `.gitignore` — a repo that *commits*
    /// `node_modules/`/`dist/` would otherwise get them indexed.
    static let excludedDirs: Set<String> = [
        "build", ".build", "DerivedData", "SourcePackages",
        "node_modules", "Pods", ".git",
        "target", "vendor", "__pycache__", ".next", "dist"
    ]

    /// True if any path *component* of `relPath` is an excluded directory. Exact component match,
    /// so a file literally named `vendor.min.js` (component `vendor.min.js`) is not excluded — only
    /// a real `vendor/` directory is. Pure, so it's unit-testable and shared by the git path, the
    /// FileManager walk, and `RepoWatcher`'s event filter.
    static func isExcluded(_ relPath: String) -> Bool {
        relPath.split(separator: "/").contains { excludedDirs.contains(String($0)) }
    }

    /// Raw `git ls-files` output as repo-root-relative paths, unfiltered by language.
    private func gitLsFilesRaw() async throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard"
        ]
        process.currentDirectoryURL = root

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice // discard stderr (an unread pipe can also deadlock)

        // Repo path is user-identifying — keep it `.private` so it's redacted in captured logs.
        Log.scanner.debug("Running git ls-files in: \(self.root.path, privacy: .private)")
        try process.run()

        // Drain stdout to EOF *before* waiting. git's output on a large repo (tens of thousands of
        // files → megabytes) far exceeds the ~64KB OS pipe buffer; if we `waitUntilExit()` first,
        // git blocks writing to a full pipe while we block waiting for it to exit — a deadlock that
        // hung indexing forever on big repos. Reading to EOF drains the pipe as git writes.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        // Screen out committed build-output/dependency dirs. `--exclude-standard` only applies
        // `.gitignore`; a repo that commits `node_modules/`/`dist/` still lists them here.
        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { !RepoScanner.isExcluded($0) }
    }

    /// The subset of `relPaths` that git considers ignored (`.gitignore`, `.git/info/exclude`,
    /// `core.excludesfile`). Used by the incremental reindex so a single saved file's membership
    /// matches exactly what a full `git ls-files --exclude-standard` scan would include — FSEvents
    /// itself is ignorant of `.gitignore`. One `git check-ignore` subprocess per call (per debounced
    /// batch), fed via stdin. Returns `[]` on a non-git repo or any git error (fail-open: better to
    /// index a would-be-ignored file than to drop a real one).
    func ignored(_ relPaths: [String]) async -> Set<String> {
        guard isGitRepo, !relPaths.isEmpty else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // `-z`: NUL-delimited I/O both ways, so paths with newlines/spaces round-trip intact.
        // `--stdin`: read the candidate paths from stdin rather than argv (unbounded batch size).
        process.arguments = ["check-ignore", "-z", "--stdin"]
        process.currentDirectoryURL = root

        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        // Feed candidates NUL-delimited, then close stdin so git reaches EOF and exits.
        let inputData = Data((relPaths.joined(separator: "\0") + "\0").utf8)
        inPipe.fileHandleForWriting.write(inputData)
        try? inPipe.fileHandleForWriting.close()

        // Drain stdout to EOF *before* waiting — same pipe-buffer deadlock guard as `gitLsFilesRaw`.
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // Exit 0 = some paths ignored, 1 = none ignored (both fine); >1 = real error → fail-open.
        guard process.terminationStatus <= 1,
              let output = String(data: data, encoding: .utf8) else { return [] }

        return Set(output.split(separator: "\0").map(String.init))
    }

    private func gitLsFiles() async throws -> [URL] {
        try await gitLsFilesRaw()
            .map { root.appendingPathComponent($0) }
            .filter { Language.detect(from: $0) != nil }
    }

    /// Raw FileManager walk as repo-root-relative paths of regular files, unfiltered by language.
    private func fileManagerWalkRaw() -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var results: [String] = []
        for case let url as URL in enumerator {
            // Skip whole excluded subtrees (build output, dependency checkouts, etc.)
            if url.pathComponents.contains(where: { RepoScanner.excludedDirs.contains($0) }) {
                enumerator.skipDescendants()
                continue
            }
            // Don't follow symlinks: a symlinked directory would let enumeration escape the repo
            // (or loop), and a symlinked file just aliases a target we either already index or that
            // lives outside the tree. `skipDescendants` covers the directory case.
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            // Regular files only — directories are derived separately via `directories(for:)`.
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile
            if isRegular == true {
                results.append(relativePath(for: url))
            }
        }
        return results
    }

    private func fileManagerWalk() -> [URL] {
        fileManagerWalkRaw()
            .map { root.appendingPathComponent($0) }
            .filter { Language.detect(from: $0) != nil }
    }

    // MARK: - Repo root detection

    /// Given any existing file or directory URL, walk up to find the nearest git repo root.
    /// Filesystem metadata — not `URL.hasDirectoryPath` — decides whether the input itself is a
    /// directory: AX document URLs and `URL(fileURLWithPath:)` often omit a trailing slash even when
    /// they name a directory. A worktree's `.git` is a file rather than a directory; `fileExists`
    /// intentionally accepts either so the exact checkout being edited remains the active root.
    static func findRepoRoot(from url: URL) -> URL? {
        let fm = FileManager.default
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else { return nil }
        var current = isDirectory.boolValue ? resolved : resolved.deletingLastPathComponent()

        while current.path != "/" {
            if fm.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    /// Returns relative path from repo root. Symlinks are resolved on both sides so the
    /// `/var` → `/private/var` (and `/tmp` → `/private/tmp`) aliasing macOS applies to
    /// `FileManager.enumerator` URLs doesn't defeat the prefix match and leak absolute paths.
    func relativePath(for url: URL) -> String {
        let rootPath = root.resolvingSymlinksInPath().path
        let urlPath = url.resolvingSymlinksInPath().path
        return urlPath.hasPrefix(rootPath + "/")
            ? String(urlPath.dropFirst(rootPath.count + 1))
            : urlPath
    }
}

// MARK: - Repo file watcher

/// Watches the active repo's tree with a single FSEvents stream and reports changed files so the
/// index can be refreshed incrementally as an editor (or an AI coding agent) writes files — no
/// manual Reindex needed. FSEvents rather than a `DispatchSource` vnode source because the latter
/// needs one open descriptor per path and can't see *newly-created* files, which is exactly the
/// case we care about (a brand-new, not-yet-tracked file the agent just wrote).
///
/// Lives here (rather than its own file) so it builds without a project-file edit — the app target
/// lists sources explicitly, same rationale as `RepoPreference`/`SymbolMatcher`/`IndexCache`.
final class RepoWatcher {

    /// What the watcher observed. `.files` carries specific changed paths for a targeted incremental
    /// update; `.rescan` means FSEvents dropped/coalesced events (or the root moved) and a full
    /// reindex is the only trustworthy response.
    enum Change {
        case files([URL])
        case rescan
    }

    private let root: URL
    private let onChange: (Change) -> Void
    private let queue = DispatchQueue(label: "com.symbolscan.repowatcher")
    private var stream: FSEventStreamRef?

    /// `onChange` is always delivered on the **main** queue.
    init(root: URL, onChange: @escaping (Change) -> Void) {
        self.root = root
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        // FileEvents → per-file paths + flags (not just parent dirs). NoDefer → fire `latency` after
        // the *first* event so a steady stream of saves still gets delivered. WatchRoot → learn if
        // the repo dir itself is moved/deleted. UseCFTypes → receive `eventPaths` as a CFArray.
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagUseCFTypes
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            repoWatcherCallback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,   // latency (seconds): coalesces bursts of saves into one callback
            flags
        ) else { return }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)   // modern scheduling; no run loop needed
        FSEventStreamStart(created)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Called from `repoWatcherCallback` on `queue`. Classifies the batch and forwards to `onChange`.
    fileprivate func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        // Any of these means the targeted path list is untrustworthy → ask for a full rescan.
        let rescanMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs |
            kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagUserDropped |
            kFSEventStreamEventFlagRootChanged |
            kFSEventStreamEventFlagMount |
            kFSEventStreamEventFlagUnmount
        )
        if flags.contains(where: { $0 & rescanMask != 0 }) {
            DispatchQueue.main.async { [onChange] in onChange(.rescan) }
            return
        }

        // Cheap Stage-A gate: drop excluded dirs / `.git` churn without a subprocess. The
        // gitignore-accurate gate (and existence/symlink checks) run later in `Indexer.reindexFiles`.
        let rootPath = root.resolvingSymlinksInPath().path
        var changed: [URL] = []
        for path in paths {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard resolved.hasPrefix(rootPath + "/") else { continue }
            let rel = String(resolved.dropFirst(rootPath.count + 1))
            if RepoScanner.isExcluded(rel) { continue }
            changed.append(URL(fileURLWithPath: path))
        }
        guard !changed.isEmpty else { return }
        DispatchQueue.main.async { [onChange] in onChange(.files(changed)) }
    }
}

/// Top-level C callback: an `FSEventStreamCallback` captures no context, so `self` is threaded
/// through `FSEventStreamContext.info`. `eventPaths` is a CFArray of CFString (UseCFTypes).
private func repoWatcherCallback(
    stream: ConstFSEventStreamRef,
    info: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watcher = Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue()
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    let flags = (0..<numEvents).map { eventFlags[$0] }
    watcher.handle(paths: paths, flags: flags)
}

// MARK: - Repo preference persistence

/// Persists which repo is active and a short list of recently-used repos, as plain paths in
/// `UserDefaults`. Lives here (rather than its own file) so it builds without a project-file edit
/// — same rationale as `SymbolMatcher` in SymbolIndex.swift.
///
/// The app is unsandboxed (`ENABLE_APP_SANDBOX = NO`), so a bare path round-trips fine. If the app
/// is ever sandboxed this must switch to a security-scoped bookmark, or restored paths will fail to
/// open. The decision logic (empty/whitespace/missing/not-a-directory) is kept in the pure
/// `decodePath` (existence injected) so it unit-tests without touching disk.
enum RepoPreference {
    static let activeKey = "SymbolScan.activeRepoPath"
    static let recentsKey = "SymbolScan.recentRepoPaths"
    static let recentsLimit = 8

    /// Pure: turn a stored path into a usable directory URL, or nil if it's blank or no longer a
    /// directory. `isDirectory` is injected so tests need no filesystem.
    static func decodePath(_ stored: String?, isDirectory: (String) -> Bool) -> URL? {
        guard let stored else { return nil }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isDirectory(trimmed) else { return nil }
        return URL(fileURLWithPath: trimmed)
    }

    private static func dirExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    static func loadActive(from d: UserDefaults = .standard) -> URL? {
        decodePath(d.string(forKey: activeKey), isDirectory: dirExists)
    }

    static func loadRecents(from d: UserDefaults = .standard) -> [URL] {
        let paths = d.stringArray(forKey: recentsKey) ?? []
        return paths.compactMap { decodePath($0, isDirectory: dirExists) }
    }

    /// Make `url` the active repo and push it onto the front of the recents list (de-duplicated,
    /// most-recent-first, capped at `recentsLimit`).
    static func setActive(_ url: URL, in d: UserDefaults = .standard) {
        let path = url.path
        d.set(path, forKey: activeKey)

        var paths = d.stringArray(forKey: recentsKey) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > recentsLimit { paths = Array(paths.prefix(recentsLimit)) }
        d.set(paths, forKey: recentsKey)
    }

    /// Drop a repo (e.g. one that was deleted/moved) from both the active slot and recents.
    static func clear(_ url: URL, from d: UserDefaults = .standard) {
        let path = url.path
        if d.string(forKey: activeKey) == path { d.removeObject(forKey: activeKey) }
        var paths = d.stringArray(forKey: recentsKey) ?? []
        paths.removeAll { $0 == path }
        d.set(paths, forKey: recentsKey)
    }
}
