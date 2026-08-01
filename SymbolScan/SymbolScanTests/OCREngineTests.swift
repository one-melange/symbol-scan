import Testing
@testable import SymbolScan

/// `OCREngine.extractSymbolQuery` is the one pure function in `Capture/` (the rest is Vision/
/// ScreenCaptureKit-bound). `Capture/` is otherwise dead code pending T9, but this parser is pure
/// and worth pinning (T14).
@Suite struct OCREngineTests {

    @Test func extractsPartialAfterMarker() {
        #expect(OCREngine.extractSymbolQuery(from: ["type @AuthM"], prefix: "@") == "AuthM")
        #expect(OCREngine.extractSymbolQuery(from: ["#src/util"], prefix: "#") == "src/util")
    }

    @Test func mostRecentMatchingLineWins() {
        // Lines are scanned newest-first (reversed), so the last line's query is returned.
        let lines = ["@first", "some text", "@second"]
        #expect(OCREngine.extractSymbolQuery(from: lines, prefix: "@") == "second")
    }

    @Test func allowedCharSetStopsAtDelimiter() {
        // Consumes letters/numbers/_ . - / then stops (the space and paren end the token).
        #expect(OCREngine.extractSymbolQuery(from: ["call @foo.bar_baz-2/x (arg)"], prefix: "@") == "foo.bar_baz-2/x")
    }

    @Test func noMarkerReturnsNil() {
        #expect(OCREngine.extractSymbolQuery(from: ["no marker here"], prefix: "@") == nil)
    }

    @Test func markerWithNothingAfterReturnsNil() {
        // Marker at end of line with no query chars → skipped, nothing found.
        #expect(OCREngine.extractSymbolQuery(from: ["trailing @"], prefix: "@") == nil)
    }
}
