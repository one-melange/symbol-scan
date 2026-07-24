import Testing
import Foundation
@testable import SymbolScan

@Suite struct LanguageAndSymbolTests {

    @Test func detectsKnownExtensions() {
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.py"))    == .python)
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.ts"))    == .typescript)
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.tsx"))   == .typescript)
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.rs"))    == .rust)
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.go"))    == .go)
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.swift")) == .swift)
    }

    @Test func detectIsCaseInsensitiveAndNilForUnknown() {
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.SWIFT")) == .swift)
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.md")) == nil)
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a")) == nil)
    }

    @Test func displayPathShowsLastTwoComponents() {
        let deep = Symbol(name: "f", kind: .function, filePath: "deep/nested/dir/file.swift", line: 3)
        #expect(deep.displayPath == "dir/file.swift")
        let short = Symbol(name: "f", kind: .function, filePath: "file.swift", line: 1)
        #expect(short.displayPath == "file.swift")
    }

    // MARK: - injectionText (T17 / T18)

    @Test func injectionTextForCodeSymbolIsPathLineName() {
        let sym = Symbol(name: "search", kind: .method, filePath: "Index/SymbolIndex.swift", line: 105)
        #expect(sym.injectionText == "@Index/SymbolIndex.swift:105 search")
    }

    @Test func injectionTextForFileIsNameThenParentDir() {
        let file = Symbol(name: "SymbolIndex.swift", kind: .file, filePath: "src/Index/SymbolIndex.swift", line: 0)
        #expect(file.injectionText == "SymbolIndex.swift src/Index")
    }

    @Test func injectionTextForDirectoryIsNameThenParentDir() {
        let dir = Symbol(name: "Index", kind: .directory, filePath: "src/Index", line: 0)
        #expect(dir.injectionText == "Index src")
    }

    @Test func injectionTextForRootLevelFileOrDirIsBareName() {
        let file = Symbol(name: "README.md", kind: .file, filePath: "README.md", line: 0)
        #expect(file.injectionText == "README.md")
        let dir = Symbol(name: "src", kind: .directory, filePath: "src", line: 0)
        #expect(dir.injectionText == "src")
    }
}
