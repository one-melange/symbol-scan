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
