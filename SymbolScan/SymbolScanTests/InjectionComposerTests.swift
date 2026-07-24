import Testing
@testable import SymbolScan

/// Covers the trigger-prefix logic behind the `@@` fix: `Symbol.injectionText` is the reference
/// body, and the leading marker comes from the trigger — nothing for `@`/`#` (the user already
/// typed it), a supplied `@` for `⌘⇧O` (which types nothing).
@Suite struct InjectionComposerTests {

    @Test func atAndHashTriggersAddNoPrefix() {
        // The trigger key was passed through to the target app; adding another would double it.
        #expect(InjectionComposer.prefix(for: .at) == "")
        #expect(InjectionComposer.prefix(for: .hash) == "")
    }

    @Test func cmdShiftOAndNilSupplyLeadingAt() {
        // ⌘⇧O types nothing, so the overlay supplies the marker (nil defaults to the same).
        #expect(InjectionComposer.prefix(for: .cmdShiftO) == "@")
        #expect(InjectionComposer.prefix(for: nil) == "@")
    }

    @Test func composeAppliesPrefixByTrigger() {
        let body = "Index/SymbolIndex.swift:105 search"
        #expect(InjectionComposer.compose(trigger: .at, body: body) == "Index/SymbolIndex.swift:105 search")
        #expect(InjectionComposer.compose(trigger: .hash, body: body) == "Index/SymbolIndex.swift:105 search")
        #expect(InjectionComposer.compose(trigger: .cmdShiftO, body: body) == "@Index/SymbolIndex.swift:105 search")
    }

    /// The exact `@@` regression: `.at` trigger + a code symbol's body must not double the `@`.
    @Test func atTriggerWithCodeSymbolDoesNotDoubleAt() {
        let sym = Symbol(name: "search", kind: .method, filePath: "Index/SymbolIndex.swift", line: 105)
        let injected = InjectionComposer.compose(trigger: .at, body: sym.injectionText)
        #expect(injected == "Index/SymbolIndex.swift:105 search")
        #expect(!injected.hasPrefix("@@"))
    }

    /// File/dir entries carry no marker of their own, so `⌘⇧O` yields a single leading `@`.
    @Test func cmdShiftOWithFileEntryGetsSingleAt() {
        let file = Symbol(name: "SymbolIndex.swift", kind: .file, filePath: "src/Index/SymbolIndex.swift", line: 0)
        #expect(InjectionComposer.compose(trigger: .cmdShiftO, body: file.injectionText) == "@SymbolIndex.swift src/Index")
    }
}
