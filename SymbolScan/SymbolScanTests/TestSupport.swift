import Foundation

/// Shared fixtures for suites that need a throwaway directory or a real git repo on disk.
///
/// Extracted from `RepoScannerTests` once a third suite (`IndexerTests`) needed them. Kept as free
/// functions rather than a type so call sites read the same as when they were private methods.
/// Every caller owns cleanup — the convention across the suites is
/// `defer { try? FileManager.default.removeItem(at: base) }` immediately after creation.
enum TestSupport {

    /// A fresh, empty directory under the system temp dir. Not a git repo — call `runGit(["init", "-q"], …)`
    /// on it to exercise the `git ls-files` path rather than the `FileManager` fallback.
    static func makeTempDir(prefix: String = "ss-test") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Run git synchronously in `dir`, discarding both streams. `RepoScanner` only ever needs
    /// `init -q`: it enumerates with `git ls-files --cached --others --exclude-standard`, so
    /// untracked files are surfaced without a commit or any `user.name`/`user.email` config.
    static func runGit(_ args: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
    }

    /// Write `contents` to `dir/relativePath`, creating intermediate directories as needed.
    static func write(_ contents: String, to relativePath: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
