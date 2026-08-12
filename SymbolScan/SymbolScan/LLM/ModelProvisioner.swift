import Foundation
import Combine

/// Owns the one-time acquisition of the local model. Created at launch and asked to `start()` so the
/// ~2 GB GGUF downloads **eagerly, in the background** — the turnkey bar: it's usually already on disk
/// by the time the user first presses ⌘E, and if not, the picker shows live "Setting up…" progress
/// rather than a config screen. `@MainActor ObservableObject` so the menu bar and picker can observe
/// `state`; the actual download runs off-main inside the injected `ModelDownloading`.
@MainActor
final class ModelProvisioner: ObservableObject {
    enum State: Equatable {
        case unknown                 // not yet checked/started
        case downloading(Double)     // fraction 0...1
        case ready                   // model present on disk
        case failed(String)          // user-facing message
    }

    @Published private(set) var state: State = .unknown

    private let source: URL
    private let destination: URL
    private let expectedSHA256: String?
    private let downloader: any ModelDownloading
    private var task: Task<Void, Never>?

    init(source: URL = ModelCatalog.sourceURL,
         destination: URL = LlamaServerLocator.defaultModelDirectory().appendingPathComponent(ModelCatalog.fileName),
         expectedSHA256: String? = ModelCatalog.sha256,
         downloader: any ModelDownloading = ModelDownloader()) {
        self.source = source
        self.destination = destination
        self.expectedSHA256 = expectedSHA256
        self.downloader = downloader
    }

    /// Idempotently ensure the model is present: already-downloaded → `.ready`; otherwise start one
    /// background download. Safe to call repeatedly (launch, and again on the first ⌘E) — a download
    /// already in flight is left alone; a prior failure is retried.
    func start() {
        switch state {
        case .downloading, .ready:
            return
        case .unknown, .failed:
            break
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            state = .ready
            return
        }
        state = .downloading(0)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.downloader.download(from: self.source,
                                                   to: self.destination,
                                                   expectedSHA256: self.expectedSHA256) { fraction in
                    Task { @MainActor [weak self] in
                        // Ignore late callbacks once we've left the downloading state.
                        if case .downloading = self?.state { self?.state = .downloading(fraction) }
                    }
                }
                self.state = .ready
            } catch is CancellationError {
                // Leave state as-is; a later start() retries.
            } catch {
                self.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Suspend until the model is ready, kicking off / awaiting the download as needed; throws on
    /// failure. Used by the explain flow so ⌘E "just works" even mid-download.
    func awaitReady() async throws {
        start()
        await task?.value
        switch state {
        case .ready:
            return
        case .failed(let message):
            throw LLMError.modelUnavailable(message)
        default:
            throw LLMError.modelUnavailable("the local model isn't ready yet")
        }
    }
}

// MARK: - Menu-bar copy

/// Pure derivation of the ambient menu-bar line for model provisioning, split out so it's testable
/// without an `NSStatusBar` (mirrors `StatusMenuModel`). Returns nil when there's nothing to say
/// (ready / unknown) so the menu bar stays quiet once the model is in place.
enum ModelStatusCopy {
    nonisolated static func line(for state: ModelProvisioner.State) -> String? {
        switch state {
        case .unknown, .ready:        return nil
        case .downloading(let f):     return "Downloading local model… \(Int((f * 100).rounded()))%"
        case .failed:                 return "Local model download failed"
        }
    }
}
