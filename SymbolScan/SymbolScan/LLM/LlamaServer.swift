import Foundation

// MARK: - Locating the runtime + weights

/// Resolves where the `llama-server` binary and the GGUF model live. Pure path logic (Bundle +
/// FileManager, no process), split out so it's inspectable and the server actor stays about
/// lifecycle. `binaryURL()`/`modelURL()` return nil when the asset is absent, which the actor turns
/// into a clear user-facing `LLMError`.
///
/// NOTE (T28 packaging): this build does not yet ship the binary or weights. The intended delivery is
/// to bundle the small `llama-server` executable as an app resource (located here via `Bundle.main`,
/// following the Tree-sitter `.bundle` resource precedent) and download the multi-GB `.gguf` on first
/// run into `defaultModelDirectory()`, with a Preferences path override for a pre-placed model. Until
/// then both lookups return nil and the picker shows "runtime isn't bundled / no model file".
enum LlamaServerLocator {

    /// The bundled server binary, or nil if this build shipped without it.
    nonisolated static func binaryURL() -> URL? {
        Bundle.main.url(forResource: "llama-server", withExtension: nil)
    }

    /// `~/Library/Application Support/SymbolScan/models/` — where a downloaded model is kept.
    nonisolated static func defaultModelDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SymbolScan/models", isDirectory: true)
    }

    /// The resolved model file: the Preferences override if it exists, else the default file under
    /// the model directory, else nil.
    nonisolated static func modelURL() -> URL? {
        if let override = LLMPreferences.modelPathOverride, !override.isEmpty {
            let u = URL(fileURLWithPath: override)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        let u = defaultModelDirectory().appendingPathComponent(LLMPreferences.defaultModelFileName)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
}

// MARK: - Server process lifecycle

/// Owns a long-lived `llama-server` child process. An `actor` because it guards mutable process
/// state and its `ensureRunning()` is idempotent under concurrent explains. Reuses the deadlock-safe
/// `Process` + `Pipe` handling proven in `RepoScanner` (drain the server's output so a chatty log
/// never blocks it on a full pipe) — the difference is that this process is long-lived, not
/// run-to-completion, so we health-poll `/health` instead of `waitUntilExit`.
actor LlamaServer {
    private var process: Process?
    private var baseURL: URL?
    private let host = "127.0.0.1"

    /// Ensure a healthy server is running and return its base URL. Idempotent: if one is already up,
    /// its URL is returned immediately. Throws a user-facing `LLMError` when the binary/model is
    /// missing or the server never becomes ready.
    func ensureRunning() async throws -> URL {
        if let baseURL, let process, process.isRunning { return baseURL }
        // A dead handle from a previous crash — clear it before respawning.
        baseURL = nil
        process = nil

        guard let binary = LlamaServerLocator.binaryURL() else {
            throw LLMError.modelUnavailable("the model runtime isn't bundled with this build yet")
        }
        guard let model = LlamaServerLocator.modelURL() else {
            throw LLMError.modelUnavailable("no model file found — set a model path in Preferences or download one")
        }

        let port = LLMPreferences.serverPort
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = [
            "--model", model.path,
            "--host", host,
            "--port", String(port),
            "--ctx-size", "4096",
        ]
        // Discard the server's stdout/stderr, but keep draining it: an unread pipe fills its ~64KB
        // buffer and blocks the writer — the same trap `RepoScanner` documents. `nullDevice` sinks it
        // without a reader thread.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            throw LLMError.serverFailedToStart(error.localizedDescription)
        }
        process = proc

        let url = URL(string: "http://\(host):\(port)")!
        try await waitUntilHealthy(url, process: proc)
        baseURL = url
        return url
    }

    /// Terminate the server (called on app quit). Safe to call when nothing is running.
    func shutdown() {
        process?.terminate()
        process = nil
        baseURL = nil
    }

    /// Poll `GET /health` until it returns 200, the process dies, or we time out.
    private func waitUntilHealthy(_ base: URL, process: Process, timeout: TimeInterval = 30) async throws {
        let healthURL = base.appendingPathComponent("health")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning {
                throw LLMError.serverFailedToStart("the server exited on launch (check the model file and runtime)")
            }
            try? await Task.sleep(nanoseconds: 300_000_000)   // 0.3s between probes
            var req = URLRequest(url: healthURL)
            req.timeoutInterval = 2
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                return
            }
        }
        process.terminate()
        throw LLMError.serverFailedToStart("timed out waiting for it to become ready")
    }
}

// MARK: - The v1 client

/// The concrete `LLMClient` for v1: it makes sure the managed `LlamaServer` is up, then streams the
/// completion through `OpenAIChatStream`. `Sendable` — its state is an actor plus immutable config —
/// so the `@MainActor` view model can hold it and iterate its stream. `nonisolated explain(...)`
/// returns a cold stream; the server-start + request run on a detached task.
final class LlamaServerClient: LLMClient {
    private let server: LlamaServer
    private let model: String
    private let session: URLSession

    init(server: LlamaServer = LlamaServer(),
         model: String = LLMPreferences.modelName,
         session: URLSession = .shared) {
        self.server = server
        self.model = model
        self.session = session
    }

    nonisolated func explain(_ prompt: LLMPrompt) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached { [server, model, session] in
                do {
                    let base = try await server.ensureRunning()
                    for try await token in OpenAIChatStream.stream(baseURL: base, model: model, prompt: prompt, session: session) {
                        try Task.checkCancellation()
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Stop the underlying server. Fire-and-forget from `applicationWillTerminate`.
    nonisolated func shutdown() {
        Task { [server] in await server.shutdown() }
    }
}
