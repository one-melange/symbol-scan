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
}
