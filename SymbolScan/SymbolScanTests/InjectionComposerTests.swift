import Testing
@testable import SymbolScan

/// Covers the trigger-prefix logic behind the `@@` fix, now driven by the matcher's pass-through
/// bit (T6): `Symbol.injectionText` is the reference body, and the leading marker is added only when
/// the bound keystroke didn't already type it — nothing when it did (default `@`/`#`), the action's
/// marker when it didn't (⌘⇧O, or any action rebound to a non-typing combo).
@Suite struct InjectionComposerTests {

    @Test func markerAlreadyTypedAddsNoPrefix() {
        // The trigger key was passed through to the target app; adding another would double it.
        #expect(InjectionComposer.prefix(action: .claudeAt, markerAlreadyTyped: true) == "")
        #expect(InjectionComposer.prefix(action: .codexHash, markerAlreadyTyped: true) == "")
    }

    @Test func markerNotTypedSuppliesActionMarker() {
        // ⌘⇧O (openSymbol) types nothing, so the overlay supplies the marker; nil defaults to "@".
        #expect(InjectionComposer.prefix(action: .openSymbol, markerAlreadyTyped: false) == "@")
        #expect(InjectionComposer.prefix(action: nil, markerAlreadyTyped: false) == "@")
    }

    /// The new-behavior case: an action rebound to a combo that types nothing must still inject its
    /// marker (no double `@`, and no stray marker left on cancel since nothing was typed).
    @Test func reboundClaudeActionSuppliesAt() {
        #expect(InjectionComposer.prefix(action: .claudeAt, markerAlreadyTyped: false) == "@")
        #expect(InjectionComposer.prefix(action: .codexHash, markerAlreadyTyped: false) == "#")
    }

    @Test func composeAppliesPrefixByPassThrough() {
        let body = "Index/SymbolIndex.swift:105 search"
        #expect(InjectionComposer.compose(action: .claudeAt, markerAlreadyTyped: true, body: body) == body)
        #expect(InjectionComposer.compose(action: .codexHash, markerAlreadyTyped: true, body: body) == body)
        #expect(InjectionComposer.compose(action: .openSymbol, markerAlreadyTyped: false, body: body) == "@" + body)
    }

    /// The exact `@@` regression: a passed-through `@` trigger + a code symbol's body must not double
    /// the `@`.
    @Test func passedThroughAtWithCodeSymbolDoesNotDoubleAt() {
        let sym = Symbol(name: "search", kind: .method, filePath: "Index/SymbolIndex.swift", line: 105)
        let injected = InjectionComposer.compose(action: .claudeAt, markerAlreadyTyped: true, body: sym.injectionText)
        #expect(injected == "Index/SymbolIndex.swift:105 search")
        #expect(!injected.hasPrefix("@@"))
    }

    /// File/dir entries carry no marker of their own, so `⌘⇧O` yields a single leading `@`.
    @Test func openSymbolWithFileEntryGetsSingleAt() {
        let file = Symbol(name: "SymbolIndex.swift", kind: .file, filePath: "src/Index/SymbolIndex.swift", line: 0)
        #expect(InjectionComposer.compose(action: .openSymbol, markerAlreadyTyped: false, body: file.injectionText) == "@SymbolIndex.swift src/Index")
    }
}
