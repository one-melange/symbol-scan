import Testing
import Foundation
@testable import SymbolScan

@Suite struct RepoScannerTests {

    @Test func relativePathStripsRootPrefix() {
        let scanner = RepoScanner(root: URL(fileURLWithPath: "/tmp/repo"))
        #expect(scanner.relativePath(for: URL(fileURLWithPath: "/tmp/repo/src/a.swift")) == "src/a.swift")
        // A path outside the root is returned unchanged.
        #expect(scanner.relativePath(for: URL(fileURLWithPath: "/other/b.swift")) == "/other/b.swift")
    }

    @Test func findRepoRootWalksUpToDotGit() throws {
        let base = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let nested = base.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        #expect(RepoScanner.findRepoRoot(from: nested) == nil)

        try FileManager.default.createDirectory(at: base.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        let found = RepoScanner.findRepoRoot(from: nested)
        #expect(found?.standardizedFileURL.path == base.standardizedFileURL.path)
    }

    @Test func isGitRepoReflectsDotGit() throws {
        let base = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(RepoScanner(root: base).isGitRepo == false)
        try FileManager.default.createDirectory(at: base.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        #expect(RepoScanner(root: base).isGitRepo == true)
    }

    @Test func enumerateSourceFilesFiltersAndExcludes() async throws {
        let base = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let nodeModules = base.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)

        try "func a() {}".write(to: base.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "def b(): pass".write(to: base.appendingPathComponent("b.py"), atomically: true, encoding: .utf8)
        try "# notes".write(to: base.appendingPathComponent("readme.md"), atomically: true, encoding: .utf8)
        try "junk".write(to: nodeModules.appendingPathComponent("dep.swift"), atomically: true, encoding: .utf8)

        // No .git in this temp dir → exercises the FileManager fallback path.
        let names = Set(try await RepoScanner(root: base).enumerateSourceFiles().map(\.lastPathComponent))
        #expect(names.contains("a.swift"))
        #expect(names.contains("b.py"))
        #expect(!names.contains("readme.md"))   // unknown language
        #expect(!names.contains("dep.swift"))   // excluded directory
    }

    /// Enumeration filters through `Language.detect`, so the dialects added in T20/T8 have to
    /// survive it — a grammar wired up in `TreeSitterParser` is useless if the file never reaches
    /// the parser. Also pins the minified-name screen at the enumeration layer, where it saves the
    /// file read entirely.
    @Test func enumerateSourceFilesIncludesNewDialectsAndSkipsMinified() async throws {
        let base = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let sources = [
            "App.tsx": "export const App = () => <div />;",
            "util.ts": "export function u() {}",
            "script.js": "export function s() {}",
            "widget.jsx": "export const W = () => <p />;",
            "cfg.cjs": "module.exports = {};",
            "vendor.min.js": "function a(){}",
            "app.bundle.js": "function b(){}",
        ]
        for (name, body) in sources {
            try body.write(to: base.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        // No .git in this temp dir → exercises the FileManager fallback path.
        let names = Set(try await RepoScanner(root: base).enumerateSourceFiles().map(\.lastPathComponent))
        #expect(names.contains("App.tsx"))
        #expect(names.contains("util.ts"))
        #expect(names.contains("script.js"))
        #expect(names.contains("widget.jsx"))
        #expect(names.contains("cfg.cjs"))
        #expect(!names.contains("vendor.min.js"))
        #expect(!names.contains("app.bundle.js"))
    }

    @Test func enumerateAllFilesKeepsNonSourceButHonorsExclusions() async throws {
        let base = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let nodeModules = base.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        let src = base.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)

        try "func a() {}".write(to: src.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "# notes".write(to: base.appendingPathComponent("readme.md"), atomically: true, encoding: .utf8)
        try "junk".write(to: nodeModules.appendingPathComponent("dep.swift"), atomically: true, encoding: .utf8)

        // No .git in this temp dir → exercises the FileManager fallback path.
        let paths = Set(try await RepoScanner(root: base).enumerateAllFiles())
        #expect(paths.contains("src/a.swift"))
        #expect(paths.contains("readme.md"))         // non-source file kept (unlike enumerateSourceFiles)
        #expect(!paths.contains("node_modules/dep.swift"))  // excluded directory still pruned
    }

    /// Regression for the freeze bug: `gitLsFilesRaw` used to `waitUntilExit()` before draining
    /// stdout, so a repo whose `git ls-files` output exceeded the ~64KB pipe buffer deadlocked
    /// forever. This builds a real git repo whose output is well over 64KB and asserts it returns.
    /// If the deadlock regresses, this test hangs and fails the run.
    @Test func enumerateAllFilesDoesNotDeadlockOnLargeGitOutput() async throws {
        let base = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        try TestSupport.runGit(["init", "-q"], in: base)   // real repo → exercises the git ls-files (Process/Pipe) path

        // ~2000 files × ~50-char paths ≈ 100KB of `git ls-files` output, comfortably past the pipe
        // buffer. Untracked files are surfaced via --others (no commit needed).
        let dir = base.appendingPathComponent("pkg")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let count = 2000
        for i in 0..<count {
            let name = String(format: "some_reasonably_long_source_file_name_%05d.txt", i)
            try Data().write(to: dir.appendingPathComponent(name))
        }

        let paths = try await RepoScanner(root: base).enumerateAllFiles()
        #expect(paths.count == count)
        #expect(paths.allSatisfy { $0.hasPrefix("pkg/") })
    }

    @Test func directoriesDerivesAllAncestorPrefixes() {
        let dirs = RepoScanner.directories(for: [
            "a/b/c.txt",
            "a/d.txt",
            "top.txt",          // top-level file → contributes no directory
            "x/y/z/deep.swift",
        ])
        #expect(dirs == ["a", "a/b", "x", "x/y", "x/y/z"])
    }
}
