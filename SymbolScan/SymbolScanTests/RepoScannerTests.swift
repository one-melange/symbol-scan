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

    /// Enumeration filters through `Language.detect`, so the `.tsx` and `.js`/`.jsx` dialects have
    /// to survive it — a grammar wired up in `TreeSitterParser` is useless if the file never reaches
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

    // MARK: - Exclusion gate (T7)

    /// `isExcluded` matches whole path *components*, never substrings — so a real `vendor/` dir is
    /// excluded but a file named `vendor.min.js` is not (the latter is the minified-name screen's job).
    @Test func isExcludedMatchesDirectoryComponentsOnly() {
        #expect(RepoScanner.isExcluded("node_modules/react/index.js"))
        #expect(RepoScanner.isExcluded("target/debug/foo.rs"))
        #expect(RepoScanner.isExcluded("crate/vendor/lib.go"))
        #expect(RepoScanner.isExcluded("pkg/__pycache__/m.pyc"))
        #expect(RepoScanner.isExcluded(".next/static/x.js"))
        #expect(RepoScanner.isExcluded("dist/app.js"))

        #expect(!RepoScanner.isExcluded("src/App.swift"))
        #expect(!RepoScanner.isExcluded("vendor.min.js"))   // a file, not a `vendor/` dir
        #expect(!RepoScanner.isExcluded("src/dist.swift"))  // component is `dist.swift`, not `dist`
    }

    /// Core T7 regression: the git path used to honour only `.gitignore`, so a repo that *commits*
    /// its build output (`target/`, `dist/`, `vendor/`, `__pycache__/`, `.next/`) got it all indexed.
    /// Runs against a real git repo so the `git ls-files` path — not the FileManager fallback — is
    /// what applies the exclusion.
    @Test func gitPathExcludesCommittedBuildDirs() async throws {
        let base = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        try TestSupport.runGit(["init", "-q"], in: base)   // real repo → git ls-files path

        try TestSupport.write("func a() {}", to: "src/a.swift", in: base)
        try TestSupport.write("junk", to: "target/debug/dep.swift", in: base)
        try TestSupport.write("junk", to: "dist/bundle.swift", in: base)
        try TestSupport.write("junk", to: "vendor/lib.go", in: base)
        try TestSupport.write("junk", to: "__pycache__/m.py", in: base)
        try TestSupport.write("junk", to: ".next/server/page.js", in: base)

        let scanner = RepoScanner(root: base)
        let all = Set(try await scanner.enumerateAllFiles())
        #expect(all.contains("src/a.swift"))
        #expect(!all.contains("target/debug/dep.swift"))
        #expect(!all.contains("dist/bundle.swift"))
        #expect(!all.contains("vendor/lib.go"))
        #expect(!all.contains("__pycache__/m.py"))
        #expect(!all.contains(".next/server/page.js"))

        // Same exclusion on the source-file (parse) enumeration.
        let sources = Set(try await scanner.enumerateSourceFiles().map { scanner.relativePath(for: $0) })
        #expect(sources.contains("src/a.swift"))
        #expect(!sources.contains("vendor/lib.go"))
    }

    /// `git check-ignore` batching used by the incremental reindex: only gitignored paths come back,
    /// and exit status 1 ("nothing ignored") is treated as success, not error.
    @Test func ignoredReturnsOnlyGitignoredPaths() async throws {
        let base = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        try TestSupport.runGit(["init", "-q"], in: base)
        try TestSupport.write("build/\nsecret.txt\n", to: ".gitignore", in: base)

        let scanner = RepoScanner(root: base)
        let ignored = await scanner.ignored(["src/a.swift", "secret.txt", "build/out.o"])
        #expect(ignored == ["secret.txt", "build/out.o"])

        // Nothing ignored → empty set, not a failure.
        #expect(await scanner.ignored(["src/a.swift"]).isEmpty)
        // A non-git directory fails open (empty), never crashes.
        #expect(await RepoScanner(root: URL(fileURLWithPath: "/tmp/not-a-repo-xyz")).ignored(["x"]).isEmpty)
    }

    /// Symlinked directories must not be followed — otherwise enumeration escapes the repo (or loops).
    @Test func fileManagerWalkSkipsSymlinkedDirs() async throws {
        let base = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        // A real directory *outside* the repo with a source file in it…
        let outside = try TestSupport.makeTempDir(prefix: "ss-outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        try "func x() {}".write(to: outside.appendingPathComponent("ext.swift"), atomically: true, encoding: .utf8)

        try "func a() {}".write(to: base.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        // …symlinked into the repo tree.
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("link"),
                                                   withDestinationURL: outside)

        // No .git → FileManager fallback path.
        let paths = Set(try await RepoScanner(root: base).enumerateAllFiles())
        #expect(paths.contains("a.swift"))
        #expect(!paths.contains { $0.hasSuffix("ext.swift") })   // symlinked dir not followed
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
