import Foundation
import CryptoKit

// MARK: - Pinned model

/// The default model + how to fetch and verify it. Pinned so the turnkey first-run download is
/// integrity-checked: a Hugging Face LFS file's `oid` **is** its sha256, so a mismatch means a
/// corrupt or tampered download. Q4_K_M of Qwen2.5-Coder-3B (~2 GB) — fast on Apple Silicon, small
/// enough to download once and forget.
enum ModelCatalog {
    nonisolated static let fileName = LLMPreferences.defaultModelFileName
    nonisolated static let sourceURL = URL(string:
        "https://huggingface.co/Qwen/Qwen2.5-Coder-3B-Instruct-GGUF/resolve/main/qwen2.5-coder-3b-instruct-q4_k_m.gguf")!
    nonisolated static let sha256 = "724fb256bec1ff062b2f65e4569e871ad2e95ab2a3989723d1769c54294730b7"
    nonisolated static let sizeBytes: Int64 = 2_104_932_800
}

// MARK: - Downloader

/// Downloads a file to a destination and verifies its sha256. A protocol so `ModelProvisioner` can be
/// unit-tested with a fake — the real ~2 GB network pull isn't something a test suite should do.
protocol ModelDownloading: Sendable {
    func download(from source: URL,
                  to destination: URL,
                  expectedSHA256: String?,
                  progress: @escaping @Sendable (Double) -> Void) async throws
}

struct ModelDownloader: ModelDownloading {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    nonisolated func download(from source: URL,
                              to destination: URL,
                              expectedSHA256: String?,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = DownloadProgressDelegate(onProgress: progress)
        let (tempURL, response) = try await session.download(from: source, delegate: delegate)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMError.modelUnavailable("model download failed (HTTP \(http.statusCode))")
        }
        if let expected = expectedSHA256 {
            let actual = try Self.sha256(ofFileAt: tempURL)
            guard actual == expected.lowercased() else {
                throw LLMError.modelUnavailable("the downloaded model failed its integrity check")
            }
        }
        // Publish atomically: verify into the temp file, then move into place, so a crash mid-download
        // never leaves a truncated file that later looks "present".
        let dir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    /// Streaming sha256 of a file (1 MB chunks) so a ~2 GB model isn't read into memory at once. Pure.
    nonisolated static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Task-scoped delegate that forwards download progress for the async `download(from:delegate:)`.
/// Called by URLSession off the main actor, so it's `nonisolated` + `@unchecked Sendable`.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    // Required by URLSessionDownloadDelegate; the async API hands us the file via its return value, so
    // there's nothing to do here.
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {}
}
