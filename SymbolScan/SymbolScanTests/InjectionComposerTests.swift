import Testing
@testable import SymbolScan

/// Covers the trigger-prefix logic behind the `@@` fix, driven by the matcher's pass-through bit:
/// `Symbol.injectionText` is the reference body, and the marker is added only when the bound
/// keystroke didn't already type it — nothing when it did (a rebound `@`/`#`), the marker otherwise
/// (the default ⌘⇧O, which types nothing).
@Suite struct InjectionComposerTests {

    @Test func markerAlreadyTypedAddsNoPrefix() {
        // The trigger key was passed through to the target app; adding another would double it.
        #expect(InjectionComposer.prefix(markerAlreadyTyped: true) == "")
    }

    @Test func markerNotTypedSuppliesMarker() {
        // ⌘⇧O types nothing, so the overlay supplies the marker.
        #expect(InjectionComposer.prefix(markerAlreadyTyped: false) == "@")
    }

    @Test func composeAppliesPrefixByPassThrough() {
        let body = "Index/SymbolIndex.swift:105 search"
        #expect(InjectionComposer.compose(markerAlreadyTyped: true, body: body) == body)
        #expect(InjectionComposer.compose(markerAlreadyTyped: false, body: body) == "@" + body)
    }

    /// The exact `@@` regression: a passed-through `@` trigger + a code symbol's body must not double
    /// the `@`.
    @Test func passedThroughWithCodeSymbolDoesNotDoubleMarker() {
        let sym = Symbol(name: "search", kind: .method, filePath: "Index/SymbolIndex.swift", line: 105)
        let injected = InjectionComposer.compose(markerAlreadyTyped: true, body: sym.injectionText)
        #expect(injected == "Index/SymbolIndex.swift:105 search")
        #expect(!injected.hasPrefix("@@"))
    }

    /// File/dir entries carry no marker of their own, so the default (suppressed) trigger yields a
    /// single leading `@`.
    @Test func defaultTriggerWithFileEntryGetsSingleMarker() {
        let file = Symbol(name: "SymbolIndex.swift", kind: .file, filePath: "src/Index/SymbolIndex.swift", line: 0)
        #expect(InjectionComposer.compose(markerAlreadyTyped: false, body: file.injectionText) == "@SymbolIndex.swift src/Index")
    }
}
