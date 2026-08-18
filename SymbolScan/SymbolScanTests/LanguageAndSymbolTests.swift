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
    /// grammar can't parse JSX, so it needs its own dialect.
    @Test func detectsDialectsThatShareALanguage() {
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.tsx")) == .tsx)
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.mts")) == .typescript)
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.cts")) == .typescript)
        // JSX *is* native to the JavaScript grammar, so .js and .jsx share one dialect.
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.js"))  == .javascript)
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.jsx")) == .javascript)
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.mjs")) == .javascript)
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.cjs")) == .javascript)
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/a.JSX")) == .javascript)
    }

    /// Committed minified/bundled JS is a single line yielding thousands of junk symbols, and
    /// `git ls-files` doesn't honour `RepoScanner.excludedDirs`. A size cap is still TODO.
    @Test func skipsMinifiedAndBundledJavaScript() {
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/vendor/jquery.min.js")) == nil)
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/dist/app.bundle.js")) == nil)
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/src/app.js")) == .javascript)
        #expect(Language.detect(from: URL(fileURLWithPath: "/x/src/mine.js")) == .javascript)
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

    // MARK: - injectionText

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

    // MARK: - docTooltip (T27)

    @Test func docTooltipIsNilWhenNoDoc() {
        let sym = Symbol(name: "f", kind: .function, filePath: "a.swift", line: 1)
        #expect(sym.docTooltip == nil)
    }

    @Test func docTooltipIsFirstNonEmptyLineTrimmed() {
        let multiline = Symbol(name: "f", kind: .function, filePath: "a.swift", line: 1,
                               doc: "Fetches the widget.\n\nUsed by the picker.")
        #expect(multiline.docTooltip == "Fetches the widget.")

        // Leading blank lines are skipped; surrounding whitespace is trimmed.
        let padded = Symbol(name: "g", kind: .function, filePath: "a.swift", line: 1,
                            doc: "\n   \n   Second line has the summary.   ")
        #expect(padded.docTooltip == "Second line has the summary.")
    }

    @Test func docTooltipIsNilForWhitespaceOnlyDoc() {
        let blank = Symbol(name: "h", kind: .function, filePath: "a.swift", line: 1,
                           doc: "   \n\t\n  ")
        #expect(blank.docTooltip == nil)
    }
}
