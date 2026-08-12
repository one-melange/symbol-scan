import Testing
import Foundation
@testable import SymbolScan

// MARK: - Fakes

/// Reports progress, then succeeds — never touches the network or the filesystem.
struct SucceedingDownloader: ModelDownloading {
    nonisolated func download(from source: URL, to destination: URL, expectedSHA256: String?,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0.5); progress(1.0)
    }
}

/// Always fails.
struct FailingDownloader: ModelDownloading {
    nonisolated func download(from source: URL, to destination: URL, expectedSHA256: String?,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        throw LLMError.modelUnavailable("boom")
    }
}

/// Reports a progress value, then blocks until cancelled — for observing the downloading state.
/// Counts how many times it was entered so idempotency can be asserted.
final class BlockingDownloader: ModelDownloading, @unchecked Sendable {
    let started = LaunchCounter()   // reused from LlamaServerTests
    let reported: Double
    init(reporting: Double = 0.42) { self.reported = reporting }

    nonisolated func download(from source: URL, to destination: URL, expectedSHA256: String?,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        await started.bump()
        progress(reported)
        try await Task.sleep(nanoseconds: 10_000_000_000)
    }
}

// MARK: - Provisioner

@MainActor @Suite struct ModelProvisionerTests {
    private let anyURL = URL(string: "https://example.invalid/model.gguf")!

    private func nonexistentDestination() throws -> URL {
        try TestSupport.makeTempDir().appendingPathComponent("model.gguf")   // dir exists, file doesn't
    }

    @Test func existingFileIsImmediatelyReadyWithoutDownloading() throws {
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("model.gguf")
        try Data("present".utf8).write(to: dest)

        let p = ModelProvisioner(source: anyURL, destination: dest, expectedSHA256: nil,
                                 downloader: FailingDownloader())   // must NOT be called
        p.start()
        #expect(p.state == .ready)
    }

    @Test func successfulDownloadReachesReady() async throws {
        let dest = try nonexistentDestination()
        let p = ModelProvisioner(source: anyURL, destination: dest, expectedSHA256: nil,
                                 downloader: SucceedingDownloader())
        try await p.awaitReady()
        #expect(p.state == .ready)
    }

    @Test func failedDownloadSurfacesError() async throws {
        let dest = try nonexistentDestination()
        let p = ModelProvisioner(source: anyURL, destination: dest, expectedSHA256: nil,
                                 downloader: FailingDownloader())
        await #expect(throws: LLMError.self) { try await p.awaitReady() }
        if case .failed = p.state {} else { Issue.record("expected .failed, got \(p.state)") }
    }

    @Test func startIsIdempotentWhileDownloading() async throws {
        let dest = try nonexistentDestination()
        let dl = BlockingDownloader()
        let p = ModelProvisioner(source: anyURL, destination: dest, expectedSHA256: nil, downloader: dl)
        p.start(); p.start(); p.start()
        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(await dl.started.count == 1)   // coalesced — one download, not three
    }

    @Test func reportsDownloadingProgress() async throws {
        let dest = try nonexistentDestination()
        let p = ModelProvisioner(source: anyURL, destination: dest, expectedSHA256: nil,
                                 downloader: BlockingDownloader(reporting: 0.42))
        p.start()
        for _ in 0..<200 where p.state != .downloading(0.42) { await Task.yield() }
        #expect(p.state == .downloading(0.42))
    }
}

// MARK: - Downloader helpers

@Suite struct ModelDownloaderTests {
    @Test func streamingSHA256MatchesKnownVector() throws {
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("abc.bin")
        try Data("abc".utf8).write(to: f)
        // Well-known: sha256("abc")
        #expect(try ModelDownloader.sha256(ofFileAt: f)
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func pinnedCatalogLooksSane() {
        #expect(ModelCatalog.sha256.count == 64)
        #expect(ModelCatalog.sizeBytes > 1_000_000_000)
        #expect(ModelCatalog.fileName.hasSuffix(".gguf"))
        #expect(ModelCatalog.sourceURL.host?.contains("huggingface.co") == true)
    }
}

// MARK: - Menu-bar copy

@MainActor @Suite struct ModelStatusCopyTests {
    @Test func quietWhenReadyOrUnknown() {
        #expect(ModelStatusCopy.line(for: .ready) == nil)
        #expect(ModelStatusCopy.line(for: .unknown) == nil)
    }
    @Test func showsRoundedPercentWhileDownloading() {
        #expect(ModelStatusCopy.line(for: .downloading(0.4249)) == "Downloading local model… 42%")
    }
    @Test func showsFailure() {
        #expect(ModelStatusCopy.line(for: .failed("x")) == "Local model download failed")
    }
}
