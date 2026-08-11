import Testing
@testable import SymbolScan

/// `PromptBuilder` is pure (no IO, no main actor), so it's exercised directly like `SymbolMatcher`.
/// v1 is doc-only: these lock in that the prompt is assembled from the fields already on `Symbol`.
@Suite struct PromptBuilderTests {

    @Test func includesSystemInstructionAndCoreContext() {
        let sym = Symbol(name: "activateUser", kind: .function, filePath: "src/user.swift", line: 42)
        let prompt = PromptBuilder.build(for: sym)

        #expect(prompt.system == PromptBuilder.system)
        #expect(prompt.user.contains("File: src/user.swift:42"))
        #expect(prompt.user.contains("Name: activateUser"))
        #expect(prompt.user.contains("Kind: function"))
        // The instruction steers away from code generation.
        #expect(prompt.user.contains("Do not generate code."))
    }

    @Test func includesSignatureWhenPresent() {
        let sym = Symbol(name: "Close", kind: .method, filePath: "server.go", line: 10,
                         signature: "(*Server) Close")
        let prompt = PromptBuilder.build(for: sym)
        #expect(prompt.user.contains("Signature: (*Server) Close"))
        #expect(prompt.user.contains("Kind: method"))
    }

    @Test func includesDocWhenPresent() {
        let sym = Symbol(name: "parse", kind: .function, filePath: "p.swift", line: 3,
                         doc: "Parses the input and returns tokens.")
        let prompt = PromptBuilder.build(for: sym)
        #expect(prompt.user.contains("Documentation comment:"))
        #expect(prompt.user.contains("Parses the input and returns tokens."))
    }

    @Test func omitsDocAndSignatureSectionsWhenAbsent() {
        let sym = Symbol(name: "x", kind: .variable, filePath: "a.rs", line: 1)
        let prompt = PromptBuilder.build(for: sym)
        #expect(!prompt.user.contains("Signature:"))
        #expect(!prompt.user.contains("Documentation comment:"))
        // Still has enough to reason from name + kind.
        #expect(prompt.user.contains("Name: x"))
        #expect(prompt.user.contains("variable"))
    }

    @Test func kindLabelsAreHumanReadable() {
        #expect(PromptBuilder.label(for: .trait) == "trait/protocol")
        #expect(PromptBuilder.label(for: .type) == "type alias")
        #expect(PromptBuilder.label(for: .directory) == "directory")
    }
}
