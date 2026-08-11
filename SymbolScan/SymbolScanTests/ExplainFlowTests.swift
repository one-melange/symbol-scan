import Testing
import Foundation
@testable import SymbolScan

/// A scripted `LLMClient` — yields the given tokens, then either finishes or fails. No server, no
/// HTTP; the protocol seam is exactly what makes the view-model flow testable in isolation.
struct FakeLLMClient: LLMClient {
    let tokens: [String]
    let failure: LLMError?

    init(tokens: [String], failure: LLMError? = nil) {
        self.tokens = tokens
        self.failure = failure
    }

    nonisolated func explain(_ prompt: LLMPrompt) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let tokens = self.tokens
            let failure = self.failure
            Task {
                for t in tokens { continuation.yield(t) }
                if let failure { continuation.finish(throwing: failure) }
                else { continuation.finish() }
            }
        }
    }
}

/// Drives `SymbolPickerViewModel.explain()` through its state machine with the fake client.
@MainActor @Suite struct ExplainFlowTests {

    private func makeVM(_ client: any LLMClient) -> SymbolPickerViewModel {
        let index = SymbolIndex()
        index.loadForTesting([
            Symbol(name: "foo", kind: .function, filePath: "a.swift", line: 1),
            Symbol(name: "bar", kind: .function, filePath: "b.swift", line: 2),
        ])
        return SymbolPickerViewModel(index: index, llmClient: client)
    }

    @Test func streamsTokensThenDone() async {
        let vm = makeVM(FakeLLMClient(tokens: ["Hel", "lo"]))
        vm.explain()
        await vm.explainTask?.value
        #expect(vm.explanation == .done("Hello"))
    }

    @Test func emptyOutputBecomesFailure() async {
        let vm = makeVM(FakeLLMClient(tokens: []))
        vm.explain()
        await vm.explainTask?.value
        if case .failed = vm.explanation {} else {
            Issue.record("expected .failed for empty output, got \(vm.explanation)")
        }
    }

    @Test func errorSurfacesUserFacingMessage() async {
        let vm = makeVM(FakeLLMClient(tokens: ["partial"],
                                      failure: .modelUnavailable("no model file found")))
        vm.explain()
        await vm.explainTask?.value
        #expect(vm.explanation == .failed("no model file found"))
    }

    @Test func changingSelectionResetsExplanation() async {
        let vm = makeVM(FakeLLMClient(tokens: ["hi"]))
        vm.explain()
        await vm.explainTask?.value
        #expect(vm.explanation != .idle)
        vm.moveSelection(1)                 // different symbol → explanation clears
        #expect(vm.explanation == .idle)
    }

    @Test func explainWithoutClientIsNoOp() {
        let index = SymbolIndex()
        index.loadForTesting([Symbol(name: "foo", kind: .function, filePath: "a.swift", line: 1)])
        let vm = SymbolPickerViewModel(index: index)   // no client
        vm.explain()
        #expect(vm.explanation == .idle)
        #expect(vm.explainTask == nil)
    }
}
