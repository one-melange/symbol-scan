import Testing
import Foundation
@testable import SymbolScan

@Suite struct RepoScannerTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ss-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func relativePathStripsRootPrefix() {
        let scanner = RepoScanner(root: URL(fileURLWithPath: "/tmp/repo"))
        #expect(scanner.relativePath(for: URL(fileURLWithPath: "/tmp/repo/src/a.swift")) == "src/a.swift")
        // A path outside the root is returned unchanged.
        #expect(scanner.relativePath(for: URL(fileURLWithPath: "/other/b.swift")) == "/other/b.swift")
    }

    @Test func findRepoRootWalksUpToDotGit() throws {
        let base = try makeTempDir()
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
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(RepoScanner(root: base).isGitRepo == false)
        try FileManager.default.createDirectory(at: base.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        #expect(RepoScanner(root: base).isGitRepo == true)
    }

    @Test func enumerateSourceFilesFiltersAndExcludes() async throws {
        let base = try makeTempDir()
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
}
