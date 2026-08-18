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
        vm.moveSelection(1)
        #expect(vm.isDocumentationPopoverPresented)
        vm.explain()
        #expect(!vm.isDocumentationPopoverPresented)
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

/// A client that yields one token then blocks until cancelled — lets the tests observe an in-flight
/// explanation and assert that the lifecycle hooks actually stop it (dropping a `Task` handle does
/// not cancel it; only `resetExplanation()` / selection changes do).
struct BlockingLLMClient: LLMClient {
    let firstToken: String

    nonisolated func explain(_ prompt: LLMPrompt) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let token = firstToken
            let task = Task {
                continuation.yield(token)
                // Park until cancelled; `finish()` either way so consumers unblock.
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Covers cancellation of in-flight generation on dismissal / selection change — the paths the
/// immediate fake client can't reach.
@MainActor @Suite struct ExplainCancellationTests {

    private func makeVM(_ client: any LLMClient) -> SymbolPickerViewModel {
        let index = SymbolIndex()
        index.loadForTesting([
            Symbol(name: "foo", kind: .function, filePath: "a.swift", line: 1),
            Symbol(name: "bar", kind: .function, filePath: "b.swift", line: 2),
        ])
        return SymbolPickerViewModel(index: index, llmClient: client)
    }

    /// Spin the runloop until the first streamed token lands (bounded, so a bug fails fast).
    private func awaitFirstToken(_ vm: SymbolPickerViewModel) async {
        for _ in 0..<1000 where vm.explanation.displayText == nil { await Task.yield() }
    }

    @Test func resetExplanationCancelsInFlightGeneration() async {
        let vm = makeVM(BlockingLLMClient(firstToken: "partial"))
        vm.explain()
        await awaitFirstToken(vm)
        #expect(vm.explanation.displayText == "partial")

        let task = vm.explainTask
        vm.resetExplanation()
        #expect(vm.explanation == .idle)
        #expect(vm.explainTask == nil)
        // The generation task ends promptly (cancelled) rather than after the 10s block.
        await task?.value
    }

    @Test func changingSelectionMidStreamCancelsAndClears() async {
        let vm = makeVM(BlockingLLMClient(firstToken: "partial"))
        vm.explain()
        await awaitFirstToken(vm)
        let task = vm.explainTask

        vm.select(1)                       // hover/arrow onto a different symbol
        #expect(vm.explanation == .idle)
        await task?.value                  // old generation stopped, not left running
    }

    @Test func selectingSameIndexKeepsExplanation() async {
        let vm = makeVM(FakeLLMClient(tokens: ["done"]))
        vm.explain()
        await vm.explainTask?.value
        #expect(vm.explanation == .done("done"))
        vm.select(vm.selectedIndex)        // no-op → explanation preserved
        #expect(vm.explanation == .done("done"))
    }
}

/// The explain flow gated on first-run model provisioning.
@MainActor @Suite struct ExplainProvisioningTests {
    private let anyURL = URL(string: "https://example.invalid/model.gguf")!

    private func makeVM(client: any LLMClient, provisioner: ModelProvisioner) -> SymbolPickerViewModel {
        let index = SymbolIndex()
        index.loadForTesting([Symbol(name: "foo", kind: .function, filePath: "a.swift", line: 1)])
        return SymbolPickerViewModel(index: index, llmClient: client, provisioner: provisioner)
    }

    @Test func readyModelStreamsNormally() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("model.gguf")
        try Data("present".utf8).write(to: dest)   // model already on disk → provisioner is ready

        let provisioner = ModelProvisioner(source: anyURL, destination: dest, expectedSHA256: nil,
                                           downloader: FailingDownloader())
        let vm = makeVM(client: FakeLLMClient(tokens: ["ok"]), provisioner: provisioner)
        vm.explain()
        await vm.explainTask?.value
        #expect(vm.explanation == .done("ok"))
    }

    @Test func showsPreparingWhileModelDownloads() async throws {
        let dest = try TestSupport.makeTempDir().appendingPathComponent("model.gguf")   // not present
        let provisioner = ModelProvisioner(source: anyURL, destination: dest, expectedSHA256: nil,
                                           downloader: BlockingDownloader(reporting: 0.5))
        let vm = makeVM(client: FakeLLMClient(tokens: ["never reached yet"]), provisioner: provisioner)
        vm.explain()

        var sawPreparing = false
        for _ in 0..<400 {
            if case .preparing = vm.explanation { sawPreparing = true; break }
            await Task.yield()
        }
        #expect(sawPreparing)
        vm.resetExplanation()               // stop the polling/generation task
        await vm.explainTask?.value
    }
}
