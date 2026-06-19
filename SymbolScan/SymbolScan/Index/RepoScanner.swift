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
            return files
        }
        return fileManagerWalk()
    }

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

        return enumerator
            .compactMap { $0 as? URL }
            .filter { Language.detect(from: $0) != nil }
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
