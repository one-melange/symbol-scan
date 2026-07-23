import Foundation

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
            print("📂 enumerateSourceFiles: git ls-files → \(files.count) source files")
            return files
        }
        let files = fileManagerWalk()
        print("📂 enumerateSourceFiles: FileManager fallback → \(files.count) source files")
        return files
    }

    /// Directory names we never want to descend into — build output, dependency
    /// checkouts, VCS metadata. Protects the FileManager fallback (gitLsFiles already
    /// honors .gitignore, so these are excluded there automatically).
    private static let excludedDirs: Set<String> = [
        "build", ".build", "DerivedData", "SourcePackages",
        "node_modules", "Pods", ".git"
    ]

    private func gitLsFiles() async throws -> [URL] {
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
        process.standardError = Pipe() // suppress stderr

        print("🔍 Running git ls-files in: \(root.path)")
        print("🔍 git path: \(process.executableURL?.path ?? "nil")")
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output
            .split(separator: "\n")
            .map { root.appendingPathComponent(String($0)) }
            .filter { Language.detect(from: $0) != nil }
    }

    private func fileManagerWalk() -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            // Skip whole excluded subtrees (build output, dependency checkouts, etc.)
            if url.pathComponents.contains(where: { RepoScanner.excludedDirs.contains($0) }) {
                enumerator.skipDescendants()
                continue
            }
            if Language.detect(from: url) != nil {
                results.append(url)
            }
        }
        return results
    }

    // MARK: - Repo root detection

    /// Given any URL, walk up to find the git repo root.
    static func findRepoRoot(from url: URL) -> URL? {
        var current = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        let fm = FileManager.default

        while current.path != "/" {
            if fm.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    /// Returns relative path from repo root.
    func relativePath(for url: URL) -> String {
        url.path.hasPrefix(root.path)
            ? String(url.path.dropFirst(root.path.count + 1))
            : url.path
    }
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
