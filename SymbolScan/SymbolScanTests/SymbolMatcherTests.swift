import Testing
@testable import SymbolScan

/// Covers the strict-substring matching/ranking that the recent picker bugs lived in.
@Suite struct SymbolMatcherTests {

    private func sym(_ name: String) -> Symbol {
        Symbol(name: name, kind: .function, filePath: "F.swift", line: 1)
    }

    @Test func emptyQueryReturnsLeadingPrefix() {
        let syms = (0..<15).map { sym("name\($0)") }
        let r = SymbolMatcher.search("", in: syms)
        #expect(r.count == 10)
        #expect(r.first?.name == "name0")
    }

    @Test func capsResultsAtLimit() {
        let syms = (0..<25).map { sym("setValue\($0)") }
        #expect(SymbolMatcher.search("set", in: syms).count == 10)
        #expect(SymbolMatcher.search("set", in: syms, limit: 3).count == 3)
    }

    @Test func includesContiguousSubstringMatches() {
        let syms = [sym("setValue"), sym("reset"), sym("parseTypeScript"), sym("unrelated")]
        let names = SymbolMatcher.search("set", in: syms).map(\.name)
        #expect(names.contains("setValue"))
        #expect(names.contains("reset"))
        // "set" is a valid contiguous match spanning parSE+Type — kept by design.
        #expect(names.contains("parseTypeScript"))
        #expect(!names.contains("unrelated"))
    }

    @Test func excludesScatteredSubsequence() {
        // "stv" only appears in "setValue" as a scattered subsequence, never contiguous.
        // This guards against re-introducing the old fuzzy fallback.
        #expect(SymbolMatcher.search("stv", in: [sym("setValue")]).isEmpty)
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(SymbolMatcher.search("SET", in: [sym("setValue")]).map(\.name) == ["setValue"])
    }

    @Test func ranksExactThenPrefixThenOffsetSubstring() {
        let syms = [sym("doReset"), sym("set"), sym("setValue")]
        let names = SymbolMatcher.search("set", in: syms).map(\.name)
        #expect(names == ["set", "setValue", "doReset"])
    }

    @Test func scoreTiersAreOrdered() {
        let exact  = SymbolMatcher.score(query: "set", candidate: "set")
        let prefix = SymbolMatcher.score(query: "set", candidate: "setvalue")
        let mid    = SymbolMatcher.score(query: "set", candidate: "doreset")
        let none   = SymbolMatcher.score(query: "xyz", candidate: "setvalue")
        #expect(exact == 1000)
        #expect(prefix == 800)
        #expect(mid > 0 && mid < prefix)
        #expect(none == 0)
    }
}
