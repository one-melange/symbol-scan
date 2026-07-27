import Testing
import Foundation
@testable import SymbolScan

@Suite struct LanguageAndSymbolTests {

    @Test func detectsKnownExtensions() {
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.py"))    == .python)
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.ts"))    == .typescript)
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.rs"))    == .rust)
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.go"))    == .go)
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.swift")) == .swift)
    }

    /// `Language` is the *grammar* key, not the language name: `.tsx` is TypeScript, but the TS
    /// grammar can't parse JSX, so it needs its own dialect (T20).
    @Test func detectsDialectsThatShareALanguage() {
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.tsx")) == .tsx)
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.mts")) == .typescript)
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.cts")) == .typescript)
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
        // Body only — no leading `@`. The prefix comes from the trigger the user typed (`@`/`#`
        // pass through to the app) or is supplied by the overlay for ⌘⇧O; baking it in here would
        // double the marker (`@@…`).
        let sym = Symbol(name: "search", kind: .method, filePath: "Index/SymbolIndex.swift", line: 105)
        #expect(sym.injectionText == "Index/SymbolIndex.swift:105 search")
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
